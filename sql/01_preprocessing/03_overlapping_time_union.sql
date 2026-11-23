-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Resolves overlapping FL_ALLDAY_STOPS_DEDUP records into a single
-- non-overlapping timeline per (cuebiq_id, event_date), in two stages.
-- Neither stage silently deletes an observation's time -- overlap is
-- either merged (Stage 1) or trimmed down to the disputed portion only
-- (Stage 2), never dropped wholesale.
--
-- STAGE 1 -- same-location union
--   Stop fragments that fall in the same 8-character geohash cell
--   (~19m x 38m, one character coarser than the raw 9-char GEOHASH_ID, to
--   tolerate normal GPS jitter around a single real stop) are treated as
--   repeated/partial reports of the SAME real-world stop. Their time
--   intervals are merged with a standard interval-union ("island")
--   algorithm -- the same technique already used in 04_user_day_quality.sql,
--   just partitioned additionally by location. Any number of overlapping
--   fragments at the same location is handled, not just pairs. The
--   resulting interval's duration is the union length (MAX(end)-MIN(start)),
--   never the sum of the fragments -- so it can never overestimate dwell
--   time. Descriptive attributes (lat/lng, provider, etc.) that can't be
--   meaningfully "unioned" are taken from the single fragment with the best
--   AVG_ACCURACY_METERS in that group.
--
-- STAGE 2 -- cross-location conflict resolution ("trim the loser, keep the
-- winner whole")
--   After Stage 1, if two DIFFERENT-location merged intervals still
--   overlap in time, that is a genuine location conflict: the data
--   disagrees about where the person was. This is resolved with a sweep-
--   line / boundary-decomposition approach so it generalizes to any number
--   of simultaneously competing locations (not just two):
--     1. Every Stage-1 interval's start and end becomes a candidate
--        boundary point for that user-day.
--     2. The day is sliced at every such point into micro-intervals. By
--        construction, the set of "active" (covering) locations cannot
--        change partway through any micro-interval.
--     3. Within each micro-interval, only the active location with the
--        best AVG_ACCURACY_METERS survives; competitors lose only that
--        micro-interval's time, not their entire record. A location with
--        no competitor at a given moment simply keeps that moment
--        untouched.
--     4. Consecutive micro-intervals awarded to the same original location
--        are re-merged into one output row, so a location that never
--        actually lost time to a competitor is not needlessly fragmented.
--   Ties (equal or both-NULL accuracy) are broken by geohash8 ascending,
--   purely so the result is deterministic rather than arbitrary.
--
-- Output: DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED -- same grain as
-- FL_ALLDAY_STOPS_DEDUP (one row per resolved, now non-overlapping stop
-- interval per user-day), with DWELL_TIME_MINUTES_IN_EVENT_DATE recomputed
-- from the resolved interval length.
--
-- NOTE: this is meaningfully more complex SQL than the rest of the
-- pipeline (Stage 2's boundary join is a range join, not an equality
-- join). Recommended sanity checks before trusting this downstream:
--   (a) per (cuebiq_id, event_date), SUM(dwell_time_minutes_in_event_date)
--       over the output should never exceed 1440 minutes;
--   (b) spot-check a handful of user-days that had conflict_day = 1 under
--       the OLD pipeline and confirm the trimmed output looks sensible.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED
AS

WITH keyed AS (

    SELECT
        *,
        LEFT(geohash_id, 8) AS geohash8

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS_DEDUP
),

-- =============================================================================
-- STAGE 1: union overlapping/duplicate fragments within the same geohash8 cell
-- =============================================================================

ordered_by_location AS (

    SELECT
        *,
        MAX(segment_end) OVER (
            PARTITION BY cuebiq_id, event_date, geohash8
            ORDER BY segment_start, segment_end
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prev_max_end

    FROM keyed
),

flagged_by_location AS (

    SELECT
        *,
        CASE
            WHEN prev_max_end IS NULL OR segment_start > prev_max_end
            THEN 1
            ELSE 0
        END AS new_interval_flag

    FROM ordered_by_location
),

grouped_by_location AS (

    SELECT
        *,
        SUM(new_interval_flag) OVER (
            PARTITION BY cuebiq_id, event_date, geohash8
            ORDER BY segment_start, segment_end
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS location_merge_id

    FROM flagged_by_location
),

location_union_bounds AS (

    SELECT
        cuebiq_id,
        event_date,
        geohash8,
        location_merge_id,
        MIN(segment_start) AS union_start,
        MAX(segment_end)   AS union_end

    FROM grouped_by_location
    GROUP BY cuebiq_id, event_date, geohash8, location_merge_id
),

-- One representative raw fragment per merged location-interval (best
-- accuracy) carries forward the descriptive attributes that can't be
-- unioned. Only the time boundaries come from location_union_bounds above.
location_representative AS (

    SELECT
        g.cuebiq_id,
        g.event_date,
        g.geohash8,
        g.location_merge_id,
        g.lat,
        g.lng,
        g.home_geo10,
        g.days_in_target_cbgs,
        g.days_at_home_cbg,
        g.home_consistency,
        g.block_group_id,
        g.avg_accuracy_meters,
        g.provider_id,
        g.classification_type,
        g.transformation_type,
        g.is_uplevelled,
        ROW_NUMBER() OVER (
            PARTITION BY g.cuebiq_id, g.event_date, g.geohash8, g.location_merge_id
            ORDER BY g.avg_accuracy_meters ASC NULLS LAST
        ) AS rep_rank

    FROM grouped_by_location AS g
),

location_merged AS (

    SELECT
        b.cuebiq_id,
        b.event_date,
        b.geohash8,
        b.union_start AS segment_start,
        b.union_end   AS segment_end,
        r.lat,
        r.lng,
        r.home_geo10,
        r.days_in_target_cbgs,
        r.days_at_home_cbg,
        r.home_consistency,
        r.block_group_id,
        r.avg_accuracy_meters,
        r.provider_id,
        r.classification_type,
        r.transformation_type,
        r.is_uplevelled

    FROM location_union_bounds AS b

    INNER JOIN location_representative AS r
        ON  b.cuebiq_id         = r.cuebiq_id
        AND b.event_date        = r.event_date
        AND b.geohash8          = r.geohash8
        AND b.location_merge_id = r.location_merge_id
        AND r.rep_rank = 1
),

-- Stable per-row identity, used to track each Stage-1 interval through
-- Stage 2's boundary decomposition below.
location_merged_id AS (

    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY cuebiq_id, event_date, geohash8, segment_start) AS loc_id

    FROM location_merged
),

-- =============================================================================
-- STAGE 2: resolve remaining cross-location time overlaps by accuracy
-- =============================================================================

boundary_points AS (

    SELECT cuebiq_id, event_date, segment_start AS ts FROM location_merged_id
    UNION
    SELECT cuebiq_id, event_date, segment_end   AS ts FROM location_merged_id
),

boundary_ordered AS (

    SELECT
        cuebiq_id,
        event_date,
        ts,
        LEAD(ts) OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY ts
        ) AS next_ts

    FROM boundary_points
),

micro_intervals AS (

    SELECT
        cuebiq_id,
        event_date,
        ts      AS slice_start,
        next_ts AS slice_end,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY ts
        ) AS slice_id

    FROM boundary_ordered
    WHERE next_ts IS NOT NULL
      AND next_ts > ts
),

-- A location is "active" during a micro-interval only when the
-- micro-interval falls entirely inside it -- guaranteed all-or-nothing
-- because every interval's own boundaries were used to cut the slices.
micro_active AS (

    SELECT
        m.cuebiq_id,
        m.event_date,
        m.slice_id,
        m.slice_start,
        m.slice_end,
        l.loc_id,
        l.geohash8,
        l.lat,
        l.lng,
        l.home_geo10,
        l.days_in_target_cbgs,
        l.days_at_home_cbg,
        l.home_consistency,
        l.block_group_id,
        l.avg_accuracy_meters,
        l.provider_id,
        l.classification_type,
        l.transformation_type,
        l.is_uplevelled

    FROM micro_intervals AS m

    INNER JOIN location_merged_id AS l
        ON  l.cuebiq_id     = m.cuebiq_id
        AND l.event_date    = m.event_date
        AND l.segment_start <= m.slice_start
        AND l.segment_end   >= m.slice_end
),

-- Best accuracy wins each micro-interval; ties broken by geohash8 so the
-- result is deterministic.
micro_winner AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id, event_date, slice_id
            ORDER BY avg_accuracy_meters ASC NULLS LAST, geohash8 ASC
        ) AS winner_rank

    FROM micro_active
),

micro_resolved AS (

    SELECT *
    FROM micro_winner
    WHERE winner_rank = 1
),

-- Re-merge consecutive micro-intervals awarded to the same original
-- location, so a location with no real competitor isn't fragmented.
resolved_ordered AS (

    SELECT
        *,
        LAG(loc_id) OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY slice_start
        ) AS prev_loc_id,
        LAG(slice_end) OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY slice_start
        ) AS prev_slice_end

    FROM micro_resolved
),

resolved_flagged AS (

    SELECT
        *,
        CASE
            WHEN prev_loc_id IS NULL
              OR prev_loc_id <> loc_id
              OR slice_start <> prev_slice_end
            THEN 1
            ELSE 0
        END AS new_output_flag

    FROM resolved_ordered
),

resolved_grouped AS (

    SELECT
        *,
        SUM(new_output_flag) OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY slice_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS output_group_id

    FROM resolved_flagged
)

SELECT
    cuebiq_id,
    event_date,
    geohash8,
    home_geo10,
    days_in_target_cbgs,
    days_at_home_cbg,
    home_consistency,
    lat,
    lng,
    block_group_id,
    avg_accuracy_meters,
    provider_id,
    classification_type,
    transformation_type,
    is_uplevelled,
    MIN(slice_start) AS segment_start,
    MAX(slice_end)   AS segment_end,
    DATEDIFF(SECOND, MIN(slice_start), MAX(slice_end)) / 60.0
        AS dwell_time_minutes_in_event_date

FROM resolved_grouped
GROUP BY
    cuebiq_id, event_date, output_group_id, loc_id, geohash8, home_geo10,
    days_in_target_cbgs, days_at_home_cbg, home_consistency, lat, lng,
    block_group_id, avg_accuracy_meters, provider_id, classification_type,
    transformation_type, is_uplevelled;
