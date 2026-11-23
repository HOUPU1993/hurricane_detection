/*
===============================================================================
HURRICANE IAN EVACUATION DETECTION — PARAMETERS
===============================================================================
Edit this file when changing the main specification or running sensitivity tests.
Run this file first in the same Snowflake session before running the SQL scripts.
===============================================================================
*/

-- -----------------------------------------------------------------------------
-- Source filters
-- -----------------------------------------------------------------------------
SET PROVIDER_1 = 'SIERRA';
SET PROVIDER_2 = 'LIMA';

-- 0 = keep UPLEVELLED stops; 1 = exclude them
SET EXCLUDE_UPLEVELLED = 0;

-- -----------------------------------------------------------------------------
-- Analysis windows
-- -----------------------------------------------------------------------------
SET BASELINE_START = 20220902;
SET BASELINE_END   = 20220922;

SET EVAC_START = 20220923;
SET EVAC_END   = 20220930;

SET RETURN_START = 20221001;
SET RETURN_END   = 20221023;

-- -----------------------------------------------------------------------------
-- Eligible user-day definition
-- -----------------------------------------------------------------------------
SET MIN_COVERED_STOP_MINUTES    = 120;
SET MIN_OBSERVATION_SPAN_MINUTES = 240;
SET MAX_OVERLAPPING_ROWS        = 0;

-- -----------------------------------------------------------------------------
-- Analysis cohort
-- -----------------------------------------------------------------------------
SET MIN_BASELINE_ELIGIBLE_DAYS = 14;
SET MIN_EVAC_ELIGIBLE_DAYS     = 3;

-- -----------------------------------------------------------------------------
-- Spatial unfamiliarity
-- -----------------------------------------------------------------------------
SET K_NEIGHBORS = 3;

-- Main rule (implemented in 04_unfamiliarity/03_unfamiliar_days.sql):
-- event-day kNN score > maximum baseline leave-one-out kNN score

-- -----------------------------------------------------------------------------
-- Persistence
-- -----------------------------------------------------------------------------
-- A candidate evacuee must have a run of consecutive unfamiliar days that
-- persists at least through PERSISTENCE_CHECK_END, not necessarily all the way
-- to EVAC_END (see 05_persistence/03_candidates.sql).
--
-- Set to 2 (was 3): Ian made landfall 9/28. A departure confirmed on two
-- consecutive days (e.g. 9/27-9/28, both weekdays, ruling out an ordinary
-- weekend trip) combined with no confirmed return before PERSISTENCE_CHECK_END
-- (9/29, one day after landfall) is treated as sufficient evidence of a real,
-- storm-related departure. See PARAMETER_LOG.md for the reasoning.
SET MIN_CONSECUTIVE_UNFAMILIAR_DAYS = 2;

-- When building that run (05_persistence/01_unfamiliar_streaks.sql), a day with
-- no eligible_day data (missing/insufficient coverage, NOT a confirmed "at home"
-- day) is skipped rather than treated as a break, as long as no more than this
-- many consecutive days are missing. A confirmed familiar day (eligible_day=1
-- AND unfamiliar_day=0) always breaks the run, regardless of this setting.
SET MAX_GAP_DAYS_TO_BRIDGE = 2;

-- The date used by 05_persistence/01_unfamiliar_streaks.sql to decide whether a
-- streak "reaches" far enough to count as unresolved (reaches_window_end): a
-- streak within MAX_GAP_DAYS_TO_BRIDGE of this date, with no confirmed return
-- home on or before it, counts -- even if the person is confirmed back home
-- later in the evac window (EVAC_END). Previously this check used EVAC_END
-- (9/30) itself, which incorrectly excluded people who evacuated through
-- landfall (9/28) and returned home as soon as it was safe (9/29-9/30) -- a
-- return could not have been caused by a storm that had already passed. Set to
-- one day after landfall to give a minimal buffer.
SET PERSISTENCE_CHECK_END = 20220929;

-- Symmetric threshold for return detection (05_persistence/04_return_detection.sql):
-- how many consecutive confirmed-familiar days (same gap-bridging rule, mirrored)
-- are required before a candidate is considered to have returned home.
-- Lowered to 2 alongside MIN_CONSECUTIVE_UNFAMILIAR_DAYS for symmetry.
SET MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN = 2;

-- -----------------------------------------------------------------------------
-- Home and destination location (evacuation distance)
-- -----------------------------------------------------------------------------
-- Nighttime window used to identify where someone sleeps (wraps past
-- midnight: hour >= NIGHT_START_HOUR OR hour < NIGHT_END_HOUR).
SET NIGHT_START_HOUR = 21;
SET NIGHT_END_HOUR   = 7;

-- Two nightly weighted-centers within this radius are treated as "the same
-- place". Used both to find each person's home (majority nightly cluster
-- across the baseline period, 05_persistence/02_home_location.sql) and their
-- evacuation destination (most recent qualifying nightly cluster during their
-- confirmed away period, 05_persistence/05_destination_location.sql). Not
-- fitted from data yet -- treat as a starting point pending a QC check of
-- night-to-night distances for people with no reason to have traveled.
SET HOME_LOCATION_RADIUS_KM = 3;

-- Minimum nights at the same place (within HOME_LOCATION_RADIUS_KM) required
-- to count as a real destination rather than a one-night transit stop
-- (a highway hotel, for example).
SET MIN_CONSECUTIVE_NIGHTS_AT_DESTINATION = 2;

-- -----------------------------------------------------------------------------
-- Candidate home-location gate (Florida bounding box)
-- -----------------------------------------------------------------------------
-- FL_RESIDENT (00_build_resident.sql) selects devices by Cuebiq's
-- DEVICE_RECURRING_AREA (IS_RESID_1_5), while FL_HOME_LOCATION
-- (02_home_location.sql) is this pipeline's own home estimate from baseline
-- nighttime stops. The two can disagree: a device can pass the residency
-- filter while its nighttime home is outside Florida. Without a check
-- downstream, such a device whose daytime mobility looked "unfamiliar"
-- during the evac window (e.g. a Boston resident on a pre-booked Hawaii
-- trip that overlapped Ian's landfall) gets flagged as a candidate evacuee
-- purely on unfamiliarity, with no connection to Florida at all. 03_candidates.sql requires a candidate's home to fall within this
-- rough bounding box. This is a rectangle, not the true state boundary --
-- it includes a sliver of Georgia/Alabama and clips part of the panhandle --
-- accepted as a reasonable first pass since it only affected ~0.9% of the
-- main_v4 candidate set (150 of 15,953: 148 with home outside the box, 2
-- with no home record at all). Revisit with a real Florida boundary
-- geometry (ST_WITHIN) if that ever becomes available in this project.
SET FL_HOME_LAT_MIN = 24;
SET FL_HOME_LAT_MAX = 31;
SET FL_HOME_LNG_MIN = -88;
SET FL_HOME_LNG_MAX = -79;


-- ===== sql/01_preprocessing/00_build_resident.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Builds DEDICATED.HOUPU.FL_RESIDENT, the target-resident population that
-- every downstream file in this pipeline (01_extract_stops.sql via INNER
-- JOIN, 02_cohort/01_analysis_cohort.sql via FROM) depends on. This table
-- was previously assumed to already exist; it is actually derived from
-- Houpu's residency-qualification table DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_FULL,
-- which computes several candidate "is this cuebiq_id a recurring Florida
-- resident" rules side by side (IS_RESID_1_2, IS_RESID_1_3, IS_RESID_1_4,
-- IS_RESID_1_5, IS_RESID_2_3). This pipeline uses the IS_RESID_1_5 = 1
-- definition: home detected (via Cuebiq's DEVICE_RECURRING_AREA) in a
-- target CBG -- i.e. a CBG in DEDICATED.HOUPU.HURRICANE_IAN_MANDATORY_CBG_CROSS,
-- under Ian's mandatory evacuation order -- on at least 5 of the 21
-- baseline days. The other IS_RESID_* flags are not used here.
--
-- Only the columns actually consumed downstream are carried through
-- (cuebiq_id, home_geo10, days_in_target_cbgs, days_at_home_cbg,
-- home_consistency); FL_RECURRING_RESIDENTS_FULL's per-day home_geo10
-- columns (one per baseline calendar date) are not needed here and are
-- dropped.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_RESIDENT
AS

SELECT
    cuebiq_id,
    home_geo10,
    days_in_target_cbgs,
    days_at_home_cbg,
    home_consistency

FROM DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_FULL
WHERE is_resid_1_5 = 1;


-- ===== sql/01_preprocessing/01_extract_stops.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_STOPS
AS

SELECT
    s.cuebiq_id,

    /* Resident information */
    r.home_geo10,
    r.days_in_target_cbgs,
    r.days_at_home_cbg,
    r.home_consistency,

    /* Stop information */
    s.event_date,
    s.lat,
    s.lng,
    s.geohash_id,
    s.block_group_id,

    /* Daily dwell-time weight */
    s.dwell_time_minutes_in_event_date,

    /* Original stop duration for QC */
    s.dwell_time_minutes,

    /* Time information */
    s.stop_zoned_datetime,
    s.stop_zoned_datetime_in_event_date,
    s.timezone_offset_seconds,

    /* Quality / provenance */
    s.avg_accuracy_meters,
    s.classification_type,
    s.transformation_type,
    s.provider_id,

    CASE
        WHEN s.transformation_type = 'UPLEVELLED' THEN 1
        ELSE 0
    END AS is_uplevelled

FROM CUEBIQ_DATA.PAAS_CDA_PE_V3.STOP_BY_EVENT_DATE_UPLEVELLED AS s

INNER JOIN DEDICATED.HOUPU.FL_RESIDENT AS r
    ON s.cuebiq_id = r.cuebiq_id

WHERE s.event_date BETWEEN $BASELINE_START AND $RETURN_END
  AND s.provider_id IN ($PROVIDER_1, $PROVIDER_2)
  AND (
        $EXCLUDE_UPLEVELLED = 0
        OR s.transformation_type <> 'UPLEVELLED'
      )
  AND s.dwell_time_minutes_in_event_date > 0
  AND s.lat IS NOT NULL
  AND s.lng IS NOT NULL;


-- ===== sql/01_preprocessing/02_deduplicate_stops.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_STOPS_DEDUP
AS

WITH parsed AS (

    SELECT
        t.*,
        TRY_TO_TIMESTAMP_TZ(stop_zoned_datetime_in_event_date) AS segment_start

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS AS t
),

intervalized AS (

    SELECT
        *,
        DATEADD(
            SECOND,
            ROUND(dwell_time_minutes_in_event_date * 60)::INTEGER,
            segment_start
        ) AS segment_end

    FROM parsed
    WHERE segment_start IS NOT NULL
),

deduped AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY
                cuebiq_id,
                event_date,
                lat,
                lng,
                segment_start,
                segment_end
            ORDER BY avg_accuracy_meters ASC NULLS LAST
        ) AS duplicate_rank

    FROM intervalized
)

SELECT * EXCLUDE (duplicate_rank)
FROM deduped
WHERE duplicate_rank = 1;


-- ===== sql/01_preprocessing/03_overlapping_time_union.sql =====
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


-- ===== sql/01_preprocessing/04_user_day_quality.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Reads DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED (the output of
-- 03_overlapping_time_union.sql), not the raw FL_ALLDAY_STOPS_DEDUP.
-- By the time records reach this file, same-location duplicates have
-- already been unioned and cross-location conflicts have already been
-- trimmed down to their disputed portion only (see 03's header for the
-- full algorithm). So N_OVERLAPPING_ROWS / CONFLICT_DAY below should
-- rarely fire in practice now -- this check has shifted from being the
-- primary defense against overlapping data to a safety-net assertion:
-- if it DOES fire on real data, that is a signal that 03's resolution
-- logic missed an edge case and should be revisited, not evidence that
-- this check is unnecessary.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_USER_DAY
AS

WITH ordered_stops AS (

    SELECT
        t.*,
        MAX(segment_end) OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY segment_start, segment_end
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS latest_previous_end

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED AS t
),

conflict_days AS (

    SELECT
        cuebiq_id,
        event_date,
        COUNT_IF(
            latest_previous_end IS NOT NULL
            AND segment_start < latest_previous_end
        ) AS n_overlapping_rows

    FROM ordered_stops
    GROUP BY cuebiq_id, event_date
),

island_starts AS (

    SELECT
        *,
        CASE
            WHEN latest_previous_end IS NULL
              OR segment_start > latest_previous_end
            THEN 1
            ELSE 0
        END AS new_island

    FROM ordered_stops
),

island_ids AS (

    SELECT
        *,
        SUM(new_island) OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY segment_start, segment_end
            ROWS UNBOUNDED PRECEDING
        ) AS island_id

    FROM island_starts
),

coverage_islands AS (

    SELECT
        cuebiq_id,
        event_date,
        island_id,
        MIN(segment_start) AS island_start,
        MAX(segment_end) AS island_end

    FROM island_ids
    GROUP BY cuebiq_id, event_date, island_id
),

coverage_summary AS (

    SELECT
        cuebiq_id,
        event_date,
        SUM(DATEDIFF(SECOND, island_start, island_end)) / 60.0
            AS unique_covered_stop_minutes

    FROM coverage_islands
    GROUP BY cuebiq_id, event_date
),

daily_summary AS (

    SELECT
        cuebiq_id,
        home_geo10,
        event_date,
        COUNT(*) AS n_stop_rows,
        SUM(dwell_time_minutes_in_event_date) AS raw_total_stop_minutes,
        MIN(segment_start) AS first_stop,
        MAX(segment_end) AS last_stop,
        DATEDIFF(
            MINUTE,
            MIN(segment_start),
            MAX(segment_end)
        ) AS observation_span_minutes

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED
    GROUP BY cuebiq_id, home_geo10, event_date
)

SELECT
    d.*,
    c.unique_covered_stop_minutes,
    COALESCE(f.n_overlapping_rows, 0) AS n_overlapping_rows,

    CASE
        WHEN COALESCE(f.n_overlapping_rows, 0) > $MAX_OVERLAPPING_ROWS
        THEN 1
        ELSE 0
    END AS conflict_day,

    CASE
        WHEN c.unique_covered_stop_minutes >= $MIN_COVERED_STOP_MINUTES
         AND d.observation_span_minutes >= $MIN_OBSERVATION_SPAN_MINUTES
        THEN 1
        ELSE 0
    END AS observation_eligible,

    CASE
        WHEN c.unique_covered_stop_minutes >= $MIN_COVERED_STOP_MINUTES
         AND d.observation_span_minutes >= $MIN_OBSERVATION_SPAN_MINUTES
         AND COALESCE(f.n_overlapping_rows, 0) <= $MAX_OVERLAPPING_ROWS
        THEN 1
        ELSE 0
    END AS eligible_day

FROM daily_summary AS d

LEFT JOIN coverage_summary AS c
    ON d.cuebiq_id = c.cuebiq_id
   AND d.event_date = c.event_date

LEFT JOIN conflict_days AS f
    ON d.cuebiq_id = f.cuebiq_id
   AND d.event_date = f.event_date;


-- ===== sql/02_cohort/01_analysis_cohort.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.

/* Count eligible days for every resident. */
CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_COHORT_COUNTS
AS

SELECT
    r.cuebiq_id,
    r.home_geo10,
    r.days_in_target_cbgs,
    r.days_at_home_cbg,
    r.home_consistency,

    COUNT_IF(
        d.event_date BETWEEN $BASELINE_START AND $BASELINE_END
        AND d.eligible_day = 1
    ) AS n_baseline_eligible_days,

    COUNT_IF(
        d.event_date BETWEEN $EVAC_START AND $EVAC_END
        AND d.eligible_day = 1
    ) AS n_evacuation_eligible_days,

    COUNT_IF(
        d.event_date BETWEEN $RETURN_START AND $RETURN_END
        AND d.eligible_day = 1
    ) AS n_return_eligible_days,

    COUNT_IF(d.conflict_day = 1) AS n_conflict_days

FROM DEDICATED.HOUPU.FL_RESIDENT AS r

LEFT JOIN DEDICATED.HOUPU.FL_ALLDAY_USER_DAY AS d
    ON r.cuebiq_id = d.cuebiq_id

GROUP BY
    r.cuebiq_id,
    r.home_geo10,
    r.days_in_target_cbgs,
    r.days_at_home_cbg,
    r.home_consistency;


/* Final analysis cohort used by all downstream detection steps. */
CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_COHORT
AS

SELECT *
FROM DEDICATED.HOUPU.FL_ALLDAY_COHORT_COUNTS
WHERE n_baseline_eligible_days >= $MIN_BASELINE_ELIGIBLE_DAYS
  AND n_evacuation_eligible_days >= $MIN_EVAC_ELIGIBLE_DAYS;


-- ===== sql/03_daily_center/01_daily_weighted_center.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Reads DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED (produced by
-- 01_preprocessing/03_overlapping_time_union.sql), not the raw
-- FL_ALLDAY_STOPS_DEDUP. DWELL_TIME_MINUTES_IN_EVENT_DATE on that table
-- is already de-conflicted (same-location duplicates unioned,
-- cross-location overlaps trimmed), so the weighted average below no
-- longer double-counts overlapping stop time.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_DAILY_CENTER
AS

WITH eligible_stops AS (

    SELECT
        s.cuebiq_id,
        s.event_date,
        s.lat,
        s.lng,
        s.dwell_time_minutes_in_event_date,
        c.home_geo10

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED AS s

    INNER JOIN DEDICATED.HOUPU.FL_ALLDAY_USER_DAY AS d
        ON s.cuebiq_id = d.cuebiq_id
       AND s.event_date = d.event_date

    INNER JOIN DEDICATED.HOUPU.FL_ALLDAY_COHORT AS c
        ON s.cuebiq_id = c.cuebiq_id

    WHERE d.eligible_day = 1
),

unit_vectors AS (

    SELECT
        *,
        COS(RADIANS(lat)) * COS(RADIANS(lng)) AS sphere_x,
        COS(RADIANS(lat)) * SIN(RADIANS(lng)) AS sphere_y,
        SIN(RADIANS(lat)) AS sphere_z

    FROM eligible_stops
),

daily_weighted AS (

    SELECT
        cuebiq_id,
        home_geo10,
        event_date,

        SUM(dwell_time_minutes_in_event_date * sphere_x)
            / SUM(dwell_time_minutes_in_event_date) AS mean_x,

        SUM(dwell_time_minutes_in_event_date * sphere_y)
            / SUM(dwell_time_minutes_in_event_date) AS mean_y,

        SUM(dwell_time_minutes_in_event_date * sphere_z)
            / SUM(dwell_time_minutes_in_event_date) AS mean_z,

        SUM(dwell_time_minutes_in_event_date) AS total_weight_minutes,
        COUNT(*) AS n_stop_rows

    FROM unit_vectors
    GROUP BY cuebiq_id, home_geo10, event_date
),

daily_centers AS (

    SELECT
        *,
        DEGREES(
            ATAN2(
                mean_z,
                SQRT(mean_x * mean_x + mean_y * mean_y)
            )
        ) AS center_lat,

        DEGREES(ATAN2(mean_y, mean_x)) AS center_lng

    FROM daily_weighted
)

SELECT
    *,
    ST_MAKEPOINT(center_lng, center_lat) AS center_geog

FROM daily_centers;


-- ===== sql/04_unfamiliarity/01_evac_knn.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Table name is kept as FL_EVAC_KNN for backward compatibility (03_unfamiliar_days.sql
-- joins to it by name), but as of this version it covers every day
-- from EVAC_START through RETURN_END, not just the evacuation window. EVAC_END and
-- RETURN_START are back-to-back (2022-09-30 -> 2022-10-01), so this is one
-- contiguous range. The extra RETURN-window rows let 03_unfamiliar_days.sql produce
-- an unfamiliar_day flag for every day after departure too, which
-- 05_persistence/04_return_detection.sql uses to detect when a candidate returned
-- home (the same personal baseline is used as the comparison set throughout, since
-- "baseline" below is unchanged).

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_KNN
AS

WITH baseline AS (

    SELECT
        cuebiq_id,
        event_date,
        center_geog

    FROM DEDICATED.HOUPU.FL_ALLDAY_DAILY_CENTER
    WHERE event_date BETWEEN $BASELINE_START AND $BASELINE_END
),

target_days AS (

    SELECT
        cuebiq_id,
        event_date,
        center_lat,
        center_lng,
        center_geog

    FROM DEDICATED.HOUPU.FL_ALLDAY_DAILY_CENTER
    WHERE event_date BETWEEN $EVAC_START AND $RETURN_END
),

pairwise AS (

    SELECT
        e.cuebiq_id,
        e.event_date,
        e.center_lat,
        e.center_lng,
        b.event_date AS baseline_date,
        ST_DISTANCE(e.center_geog, b.center_geog) / 1000.0
            AS spatial_distance_km

    FROM target_days AS e

    INNER JOIN baseline AS b
        ON e.cuebiq_id = b.cuebiq_id
),

ranked AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY spatial_distance_km, baseline_date
        ) AS neighbor_rank

    FROM pairwise
)

SELECT
    cuebiq_id,
    event_date,
    MAX(center_lat) AS center_lat,
    MAX(center_lng) AS center_lng,
    AVG(spatial_distance_km) AS evac_knn_score_km,
    MIN(spatial_distance_km) AS nearest_baseline_day_km,
    MAX(spatial_distance_km) AS kth_nearest_baseline_day_km

FROM ranked
WHERE neighbor_rank <= $K_NEIGHBORS
GROUP BY cuebiq_id, event_date
HAVING COUNT(*) = $K_NEIGHBORS;


-- ===== sql/04_unfamiliarity/02_baseline_loo_knn.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_BASELINE_LOO_KNN
AS

WITH baseline AS (

    SELECT
        cuebiq_id,
        event_date,
        center_lat,
        center_lng,
        center_geog

    FROM DEDICATED.HOUPU.FL_ALLDAY_DAILY_CENTER
    WHERE event_date BETWEEN $BASELINE_START AND $BASELINE_END
),

pairwise AS (

    SELECT
        a.cuebiq_id,
        a.event_date,
        a.center_lat,
        a.center_lng,
        b.event_date AS comparison_baseline_date,
        ST_DISTANCE(a.center_geog, b.center_geog) / 1000.0
            AS spatial_distance_km

    FROM baseline AS a

    INNER JOIN baseline AS b
        ON a.cuebiq_id = b.cuebiq_id
       AND a.event_date <> b.event_date
),

ranked AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY spatial_distance_km, comparison_baseline_date
        ) AS neighbor_rank

    FROM pairwise
)

SELECT
    cuebiq_id,
    event_date,
    MAX(center_lat) AS center_lat,
    MAX(center_lng) AS center_lng,
    AVG(spatial_distance_km) AS loo_knn_score_km,
    MIN(spatial_distance_km) AS nearest_baseline_day_km,
    MAX(spatial_distance_km) AS kth_nearest_baseline_day_km

FROM ranked
WHERE neighbor_rank <= $K_NEIGHBORS
GROUP BY cuebiq_id, event_date
HAVING COUNT(*) = $K_NEIGHBORS;


-- ===== sql/04_unfamiliarity/03_unfamiliar_days.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_KNN_RARITY
AS

WITH comparisons AS (

    SELECT
        e.cuebiq_id,
        e.event_date,
        e.center_lat,
        e.center_lng,
        e.evac_knn_score_km,
        b.loo_knn_score_km

    FROM DEDICATED.HOUPU.FL_EVAC_KNN AS e

    INNER JOIN DEDICATED.HOUPU.FL_BASELINE_LOO_KNN AS b
        ON e.cuebiq_id = b.cuebiq_id
),

rank_summary AS (

    SELECT
        cuebiq_id,
        event_date,
        MAX(center_lat) AS center_lat,
        MAX(center_lng) AS center_lng,
        MAX(evac_knn_score_km) AS evac_knn_score_km,

        COUNT(*) AS n_baseline_scores,
        MIN(loo_knn_score_km) AS baseline_score_min,
        MEDIAN(loo_knn_score_km) AS baseline_score_median,
        MAX(loo_knn_score_km) AS baseline_score_max,

        COUNT_IF(loo_knn_score_km >= evac_knn_score_km)
            AS n_baseline_scores_ge

    FROM comparisons
    GROUP BY cuebiq_id, event_date
)

SELECT
    *,

    n_baseline_scores_ge::DOUBLE
        / NULLIF(n_baseline_scores, 0) AS empirical_tail_fraction,

    evac_knn_score_km
        / NULLIF(baseline_score_median, 0)
        AS score_to_baseline_median_ratio,

    CASE
        WHEN evac_knn_score_km > baseline_score_max THEN 1
        ELSE 0
    END AS unfamiliar_day

FROM rank_summary;


-- ===== sql/05_persistence/01_unfamiliar_streaks.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Finds, per user, consecutive-day runs of unfamiliar_day = 1 within the
-- evacuation window (EVAC_START..EVAC_END). Rewritten to distinguish three
-- daily states instead of only looking at rows where unfamiliar_day = 1:
--
--   state 1 (unfamiliar)  -- FL_EVAC_KNN_RARITY row with unfamiliar_day = 1
--   state 2 (familiar)    -- FL_EVAC_KNN_RARITY row with unfamiliar_day = 0
--                            (this day was actually observed and the person
--                            looked "normal" -- real evidence of being home)
--   state 3 (missing)     -- no FL_EVAC_KNN_RARITY row at all (not enough
--                            data to judge eligible_day that day -- we simply
--                            don't know what happened)
--
-- A state-2 day always breaks a run, no matter how short the gap is -- it is
-- confirmed evidence the person was back home. A state-3 (missing) day does
-- NOT break a run by itself, as long as no more than $MAX_GAP_DAYS_TO_BRIDGE
-- consecutive days are missing; longer blackouts are treated as a break too,
-- because we have no real evidence the person was still away. This means the
-- previous version's approach (grouping only the rows where unfamiliar_day=1,
-- using ROW_NUMBER()-based date adjacency) is replaced with a full per-day
-- calendar spine so missing days can be told apart from confirmed-familiar
-- days.
--
-- Output also flags whether each run's last unfamiliar day reaches at least
-- to $PERSISTENCE_CHECK_END (one day after Ian's 9/28 landfall) within the
-- same gap tolerance (reaches_window_end) -- 03_candidates.sql uses this to
-- decide the "true" departure: only a run that is still ongoing (or unbroken
-- by missing data) as of that date counts. This is deliberately NOT EVAC_END
-- itself: a person who evacuated through landfall and returned home once it
-- was safe (e.g. 9/29-9/30) cannot have been driven back by a storm that had
-- already passed, so requiring them to still be away on 9/30 would wrongly
-- exclude a real evacuation. A person who returned before landfall (e.g. left
-- 9/24, home by 9/27) is still correctly excluded either way.

-- GENERATOR(ROWCOUNT => ...) requires a literal constant, not a computed
-- expression -- precompute the calendar day count into a session variable
-- here so it can be passed in below.
SET N_EVAC_CALENDAR_DAYS = (
    SELECT DATEDIFF(
        DAY,
        TO_DATE(TO_VARCHAR($EVAC_START), 'YYYYMMDD'),
        TO_DATE(TO_VARCHAR($EVAC_END), 'YYYYMMDD')
    ) + 1
);

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_FLAG_STREAKS
AS

WITH cohort_users AS (

    SELECT DISTINCT cuebiq_id
    FROM DEDICATED.HOUPU.FL_ALLDAY_COHORT
),

calendar AS (

    SELECT
        DATEADD(
            DAY, SEQ4(),
            TO_DATE(TO_VARCHAR($EVAC_START), 'YYYYMMDD')
        ) AS event_dt

    FROM TABLE(GENERATOR(ROWCOUNT => $N_EVAC_CALENDAR_DAYS))
),

spine AS (

    SELECT
        u.cuebiq_id,
        c.event_dt

    FROM cohort_users AS u
    CROSS JOIN calendar AS c
),

daily_status AS (

    SELECT
        s.cuebiq_id,
        s.event_dt,
        r.evac_knn_score_km,
        r.baseline_score_max,
        r.score_to_baseline_median_ratio,
        r.center_lat,
        r.center_lng,

        CASE
            WHEN r.unfamiliar_day = 1 THEN 1  -- confirmed unfamiliar
            WHEN r.unfamiliar_day = 0 THEN 2  -- confirmed familiar (real break)
            ELSE 3                            -- missing / not eligible
        END AS day_state

    FROM spine AS s

    LEFT JOIN DEDICATED.HOUPU.FL_EVAC_KNN_RARITY AS r
        ON s.cuebiq_id = r.cuebiq_id
       AND s.event_dt = TO_DATE(TO_VARCHAR(r.event_date), 'YYYYMMDD')
),

with_last_familiar AS (

    SELECT
        *,
        MAX(CASE WHEN day_state = 2 THEN event_dt END) OVER (
            PARTITION BY cuebiq_id
            ORDER BY event_dt
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS last_confirmed_familiar_dt

    FROM daily_status
),

unfamiliar_only AS (

    SELECT
        *,
        LAG(event_dt) OVER (
            PARTITION BY cuebiq_id ORDER BY event_dt
        ) AS prev_unfamiliar_dt

    FROM with_last_familiar
    WHERE day_state = 1
),

flagged_with_breaks AS (

    SELECT
        *,
        CASE
            WHEN prev_unfamiliar_dt IS NULL THEN 1

            -- a confirmed-familiar day occurred strictly between the previous
            -- unfamiliar day and this one -> always a real break
            WHEN last_confirmed_familiar_dt IS NOT NULL
                 AND last_confirmed_familiar_dt > prev_unfamiliar_dt THEN 1

            -- otherwise, only break if the missing-day gap exceeds tolerance
            WHEN DATEDIFF(DAY, prev_unfamiliar_dt, event_dt) - 1
                 > $MAX_GAP_DAYS_TO_BRIDGE THEN 1

            ELSE 0
        END AS new_streak_flag

    FROM unfamiliar_only
),

streak_grouped AS (

    SELECT
        *,
        SUM(new_streak_flag) OVER (
            PARTITION BY cuebiq_id
            ORDER BY event_dt
            ROWS UNBOUNDED PRECEDING
        ) AS streak_group

    FROM flagged_with_breaks
),

streak_summary AS (

    SELECT
        cuebiq_id,
        streak_group,
        MIN(event_dt) AS streak_start,
        MAX(event_dt) AS streak_end,

        -- number of CONFIRMED unfamiliar days in this run (does not count
        -- bridged missing days) -- this is what the >= MIN_CONSECUTIVE_
        -- UNFAMILIAR_DAYS check in 03_candidates.sql is measured against
        COUNT(*) AS streak_length,

        -- calendar span of the run including any bridged missing days;
        -- kept separate from streak_length so the two notions of "length"
        -- (confirmed evidence vs. calendar days covered) are never conflated
        DATEDIFF(DAY, MIN(event_dt), MAX(event_dt)) + 1
            AS streak_calendar_span_days,

        MIN(evac_knn_score_km) AS min_knn_score_km,
        MEDIAN(evac_knn_score_km) AS median_knn_score_km,
        MAX(evac_knn_score_km) AS max_knn_score_km,

        MIN(baseline_score_max) AS baseline_score_max_km,
        MEDIAN(score_to_baseline_median_ratio)
            AS median_score_to_baseline_ratio

    FROM streak_grouped
    GROUP BY cuebiq_id, streak_group
),

window_bound AS (

    SELECT TO_DATE(TO_VARCHAR($PERSISTENCE_CHECK_END), 'YYYYMMDD') AS persistence_check_dt
),

-- confirmed-familiar days anywhere in the evac window, used below to check
-- whether a run's apparent "reach to PERSISTENCE_CHECK_END" is actually
-- interrupted by a real (not just missing-data) return home
confirmed_familiar_days AS (

    SELECT cuebiq_id, event_dt
    FROM daily_status
    WHERE day_state = 2
)

SELECT
    s.*,

    CASE
        WHEN DATEDIFF(DAY, s.streak_end, w.persistence_check_dt) <= $MAX_GAP_DAYS_TO_BRIDGE
             AND NOT EXISTS (
                 SELECT 1
                 FROM confirmed_familiar_days AS f
                 WHERE f.cuebiq_id = s.cuebiq_id
                   AND f.event_dt > s.streak_end
                   AND f.event_dt <= w.persistence_check_dt
             )
        THEN 1
        ELSE 0
    END AS reaches_window_end

FROM streak_summary AS s
CROSS JOIN window_bound AS w;


-- ===== sql/05_persistence/02_home_location.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Determines each resident's "home" location as the nighttime
-- (NIGHT_START_HOUR..NIGHT_END_HOUR, wrapping past midnight) weighted center
-- of the MAJORITY cluster of baseline nights -- not a naive average of every
-- baseline night. Averaging every night would let a handful of out-of-town
-- nights during the 21-day baseline window (a weekend trip, a visit to
-- family in another county) pull the home point toward wherever the person
-- happened to travel, even though most nights were genuinely spent at home.
--
-- Algorithm:
--   1. Compute one nightly weighted center per (cuebiq_id, night), using the
--      same spherical weighted-average machinery as 03_daily_center, but
--      restricted to stops that fall in the nighttime window and to baseline
--      dates only.
--   2. Self-join nights (per user) and flag pairs within
--      $HOME_LOCATION_RADIUS_KM of each other as "the same place".
--   3. For each night, count how many OTHER nights are the same place -- a
--      proxy for how often that location recurs.
--   4. The night with the most same-place neighbors anchors the home
--      cluster (ties broken by earliest night, for reproducibility).
--   5. Home nights = the anchor night plus every other night within radius
--      of it.
--   6. Re-run the weighted average over the raw stop-level records from just
--      those home nights (not over the already-averaged nightly points) --
--      this keeps the dwell-time weighting faithful to the original
--      03_daily_center formula, just restricted to a cleaner input set.
--
-- A user with sparse or no nighttime coverage during baseline (n_home_nights
-- small, or absent from this table entirely) has a correspondingly
-- unreliable or missing home estimate -- worth a QC check once run on real
-- data.
--
-- Scope: reads FL_ALLDAY_STOPS_UNIONED directly, without a join to
-- FL_ALLDAY_COHORT, so a home is computed for every FL_RESIDENT device with
-- baseline nighttime stops, not only cohort members or candidates.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_HOME_LOCATION
AS

WITH night_stops AS (

    SELECT
        s.cuebiq_id,
        CASE
            WHEN HOUR(s.segment_start) >= $NIGHT_START_HOUR
                THEN TO_DATE(s.segment_start)
            WHEN HOUR(s.segment_start) < $NIGHT_END_HOUR
                THEN DATEADD(DAY, -1, TO_DATE(s.segment_start))
            ELSE NULL
        END AS night_date,
        s.lat,
        s.lng,
        s.dwell_time_minutes_in_event_date

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED AS s
    WHERE s.event_date BETWEEN $BASELINE_START AND $BASELINE_END
),

night_stops_filtered AS (

    SELECT *
    FROM night_stops
    WHERE night_date IS NOT NULL
),

nightly_unit_vectors AS (

    SELECT
        *,
        COS(RADIANS(lat)) * COS(RADIANS(lng)) AS sphere_x,
        COS(RADIANS(lat)) * SIN(RADIANS(lng)) AS sphere_y,
        SIN(RADIANS(lat)) AS sphere_z

    FROM night_stops_filtered
),

nightly_center AS (

    SELECT
        cuebiq_id,
        night_date,

        SUM(dwell_time_minutes_in_event_date * sphere_x)
            / SUM(dwell_time_minutes_in_event_date) AS mean_x,
        SUM(dwell_time_minutes_in_event_date * sphere_y)
            / SUM(dwell_time_minutes_in_event_date) AS mean_y,
        SUM(dwell_time_minutes_in_event_date * sphere_z)
            / SUM(dwell_time_minutes_in_event_date) AS mean_z

    FROM nightly_unit_vectors
    GROUP BY cuebiq_id, night_date
),

nightly_center_geog AS (

    SELECT
        cuebiq_id,
        night_date,
        DEGREES(ATAN2(mean_z, SQRT(mean_x * mean_x + mean_y * mean_y)))
            AS night_lat,
        DEGREES(ATAN2(mean_y, mean_x)) AS night_lng
    FROM nightly_center
),

nightly_center_final AS (

    SELECT
        *,
        ST_MAKEPOINT(night_lng, night_lat) AS night_geog
    FROM nightly_center_geog
),

night_pairs AS (

    SELECT
        a.cuebiq_id,
        a.night_date AS night_date_a,
        b.night_date AS night_date_b,
        ST_DISTANCE(a.night_geog, b.night_geog) / 1000.0 AS distance_km

    FROM nightly_center_final AS a

    INNER JOIN nightly_center_final AS b
        ON a.cuebiq_id = b.cuebiq_id
       AND a.night_date <> b.night_date
),

neighbor_counts AS (

    SELECT
        cuebiq_id,
        night_date_a AS night_date,
        COUNT_IF(distance_km <= $HOME_LOCATION_RADIUS_KM)
            AS same_place_neighbor_count

    FROM night_pairs
    GROUP BY cuebiq_id, night_date_a
),

anchor_night AS (

    SELECT
        n.cuebiq_id,
        n.night_date AS anchor_night_date,
        ROW_NUMBER() OVER (
            PARTITION BY n.cuebiq_id
            ORDER BY n.same_place_neighbor_count DESC, n.night_date ASC
        ) AS anchor_rank

    -- a night that appears in nightly_center_final but never got a row in
    -- neighbor_counts (zero matches) still needs to be a candidate anchor
    FROM (
        SELECT
            c.cuebiq_id,
            c.night_date,
            COALESCE(nc.same_place_neighbor_count, 0)
                AS same_place_neighbor_count
        FROM nightly_center_final AS c
        LEFT JOIN neighbor_counts AS nc
            ON c.cuebiq_id = nc.cuebiq_id
           AND c.night_date = nc.night_date
    ) AS n
),

home_nights AS (

    SELECT a.cuebiq_id, a.anchor_night_date AS night_date
    FROM anchor_night AS a
    WHERE a.anchor_rank = 1

    UNION

    SELECT p.cuebiq_id, p.night_date_b AS night_date
    FROM night_pairs AS p
    INNER JOIN anchor_night AS a
        ON p.cuebiq_id = a.cuebiq_id
       AND p.night_date_a = a.anchor_night_date
    WHERE a.anchor_rank = 1
      AND p.distance_km <= $HOME_LOCATION_RADIUS_KM
),

home_stops AS (

    SELECT ns.*
    FROM night_stops_filtered AS ns
    INNER JOIN home_nights AS h
        ON ns.cuebiq_id = h.cuebiq_id
       AND ns.night_date = h.night_date
),

home_unit_vectors AS (

    SELECT
        *,
        COS(RADIANS(lat)) * COS(RADIANS(lng)) AS sphere_x,
        COS(RADIANS(lat)) * SIN(RADIANS(lng)) AS sphere_y,
        SIN(RADIANS(lat)) AS sphere_z
    FROM home_stops
),

home_weighted AS (

    SELECT
        cuebiq_id,

        SUM(dwell_time_minutes_in_event_date * sphere_x)
            / SUM(dwell_time_minutes_in_event_date) AS mean_x,
        SUM(dwell_time_minutes_in_event_date * sphere_y)
            / SUM(dwell_time_minutes_in_event_date) AS mean_y,
        SUM(dwell_time_minutes_in_event_date * sphere_z)
            / SUM(dwell_time_minutes_in_event_date) AS mean_z,

        COUNT(DISTINCT night_date) AS n_home_nights

    FROM home_unit_vectors
    GROUP BY cuebiq_id
),

home_center AS (

    SELECT
        cuebiq_id,
        n_home_nights,
        DEGREES(ATAN2(mean_z, SQRT(mean_x * mean_x + mean_y * mean_y)))
            AS home_lat,
        DEGREES(ATAN2(mean_y, mean_x)) AS home_lng
    FROM home_weighted
)

SELECT
    cuebiq_id,
    n_home_nights,
    home_lat,
    home_lng,
    ST_MAKEPOINT(home_lng, home_lat) AS home_geog

FROM home_center;


-- ===== sql/05_persistence/03_candidates.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- A candidate evacuee is someone whose LAST unfamiliar streak (from
-- 01_unfamiliar_streaks.sql) reaches at least through $PERSISTENCE_CHECK_END
-- (reaches_window_end = 1, within the same $MAX_GAP_DAYS_TO_BRIDGE
-- tolerance used to build the streak) AND is at least
-- $MIN_CONSECUTIVE_UNFAMILIAR_DAYS long. This replaces the previous
-- "earliest qualifying streak" rule: a streak that ends and is followed by
-- a confirmed return home before $PERSISTENCE_CHECK_END no longer counts,
-- even if it was long enough on its own, because it wasn't necessarily
-- caused by the storm (e.g. someone who left on 9/24, came home on 9/27 and
-- stayed, before Ian made landfall on 9/28, should not be flagged). A
-- confirmed return AFTER $PERSISTENCE_CHECK_END (e.g. home by 9/30, once
-- the storm has already passed) does not disqualify the candidate -- see
-- 01_unfamiliar_streaks.sql's header for the reasoning.
--
-- Because at most one streak per user can reach $PERSISTENCE_CHECK_END, no
-- ranking is needed here -- the WHERE clause alone picks at most one row per
-- cuebiq_id (verified empirically: n_rows = n_users in FL_EVAC_CANDIDATES).
-- candidate_start_date is therefore the true departure date: the first day
-- of the run that persists, uninterrupted by a confirmed return, through
-- $PERSISTENCE_CHECK_END.
--
-- Home-location gate: also requires a confirmed home (FL_HOME_LOCATION,
-- 02_home_location.sql) within the rough Florida bounding box defined by
-- $FL_HOME_LAT_MIN/MAX and $FL_HOME_LNG_MIN/MAX (see PARAMETERS.sql).
-- FL_RESIDENT is defined from Cuebiq's DEVICE_RECURRING_AREA, while
-- FL_HOME_LOCATION is estimated independently from baseline nighttime
-- stops; the two can disagree, so without this join someone whose nighttime
-- home is nowhere near Florida but whose daytime mobility happened to look
-- unfamiliar during the evac window would still be flagged as a
-- candidate (found via spot-check: a Boston resident on a pre-booked Hawaii
-- trip that overlapped Ian's landfall). A candidate with no FL_HOME_LOCATION
-- row at all (sparse baseline nighttime coverage) is also excluded here,
-- since their home cannot be confirmed to be in Florida either.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_CANDIDATES
AS

SELECT
    s.cuebiq_id,
    s.streak_start AS candidate_start_date,
    s.streak_end AS candidate_streak_end_date,
    s.streak_length AS candidate_streak_length,
    s.streak_calendar_span_days AS candidate_streak_calendar_span_days,
    s.min_knn_score_km,
    s.median_knn_score_km,
    s.max_knn_score_km,
    s.baseline_score_max_km,
    s.median_score_to_baseline_ratio

FROM DEDICATED.HOUPU.FL_EVAC_FLAG_STREAKS AS s

INNER JOIN DEDICATED.HOUPU.FL_HOME_LOCATION AS h
    ON s.cuebiq_id = h.cuebiq_id
   AND h.home_lat BETWEEN $FL_HOME_LAT_MIN AND $FL_HOME_LAT_MAX
   AND h.home_lng BETWEEN $FL_HOME_LNG_MIN AND $FL_HOME_LNG_MAX

WHERE s.reaches_window_end = 1
  AND s.streak_length >= $MIN_CONSECUTIVE_UNFAMILIAR_DAYS;


-- ===== sql/05_persistence/04_return_detection.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Mirrors 01_unfamiliar_streaks.sql's gap-tolerant island logic, but flipped:
-- for each confirmed candidate evacuee (FL_EVAC_CANDIDATES), looks for the
-- first persistent run of CONFIRMED FAMILIAR days (unfamiliar_day = 0) within
-- the return window (RETURN_START..RETURN_END). Same three-state model as
-- 01_unfamiliar_streaks.sql, with unfamiliar/familiar swapped:
--
--   state 1 (unfamiliar) -- now the HARD BREAK: they left again, so a
--                            familiar run in progress does not count as a
--                            real return
--   state 2 (familiar)   -- now the day being accumulated into a streak
--   state 3 (missing)    -- bridged up to $MAX_GAP_DAYS_TO_BRIDGE consecutive
--                            days, same as the departure side
--
-- Requires 04_unfamiliarity/01_evac_knn.sql to have been widened to cover
-- RETURN_START..RETURN_END (see that file's header) so FL_EVAC_KNN_RARITY
-- has an unfamiliar_day judgment for return-window days too.
--
-- Unlike departure detection, a return does not need to persist to the end
-- of any window -- we want the FIRST stable homecoming, so the earliest
-- qualifying run (>= $MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN long) is used.

-- GENERATOR(ROWCOUNT => ...) requires a literal constant, so the day count
-- is precomputed into a session variable first (same fix as
-- 01_unfamiliar_streaks.sql's calendar spine).
SET N_RETURN_CALENDAR_DAYS = (
    SELECT DATEDIFF(
        DAY,
        TO_DATE(TO_VARCHAR($RETURN_START), 'YYYYMMDD'),
        TO_DATE(TO_VARCHAR($RETURN_END), 'YYYYMMDD')
    ) + 1
);

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_RETURN_DATES
AS

WITH candidates AS (

    SELECT cuebiq_id, candidate_start_date
    FROM DEDICATED.HOUPU.FL_EVAC_CANDIDATES
),

calendar AS (

    SELECT
        DATEADD(
            DAY, SEQ4(),
            TO_DATE(TO_VARCHAR($RETURN_START), 'YYYYMMDD')
        ) AS event_dt

    FROM TABLE(GENERATOR(ROWCOUNT => $N_RETURN_CALENDAR_DAYS))
),

spine AS (

    SELECT
        c.cuebiq_id,
        c.candidate_start_date,
        cal.event_dt

    FROM candidates AS c
    CROSS JOIN calendar AS cal
),

daily_status AS (

    SELECT
        s.cuebiq_id,
        s.candidate_start_date,
        s.event_dt,

        CASE
            WHEN r.unfamiliar_day = 0 THEN 2  -- confirmed familiar (return evidence)
            WHEN r.unfamiliar_day = 1 THEN 1  -- confirmed unfamiliar (left again -- hard break)
            ELSE 3                            -- missing / not eligible
        END AS day_state

    FROM spine AS s

    LEFT JOIN DEDICATED.HOUPU.FL_EVAC_KNN_RARITY AS r
        ON s.cuebiq_id = r.cuebiq_id
       AND s.event_dt = TO_DATE(TO_VARCHAR(r.event_date), 'YYYYMMDD')
),

with_last_unfamiliar AS (

    SELECT
        *,
        MAX(CASE WHEN day_state = 1 THEN event_dt END) OVER (
            PARTITION BY cuebiq_id
            ORDER BY event_dt
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS last_confirmed_unfamiliar_dt

    FROM daily_status
),

familiar_only AS (

    SELECT
        *,
        LAG(event_dt) OVER (
            PARTITION BY cuebiq_id ORDER BY event_dt
        ) AS prev_familiar_dt

    FROM with_last_unfamiliar
    WHERE day_state = 2
),

flagged_with_breaks AS (

    SELECT
        *,
        CASE
            WHEN prev_familiar_dt IS NULL THEN 1

            -- a confirmed-unfamiliar day (they left again) occurred strictly
            -- between the previous familiar day and this one -> hard break
            WHEN last_confirmed_unfamiliar_dt IS NOT NULL
                 AND last_confirmed_unfamiliar_dt > prev_familiar_dt THEN 1

            -- otherwise, only break if the missing-day gap exceeds tolerance
            WHEN DATEDIFF(DAY, prev_familiar_dt, event_dt) - 1
                 > $MAX_GAP_DAYS_TO_BRIDGE THEN 1

            ELSE 0
        END AS new_streak_flag

    FROM familiar_only
),

streak_grouped AS (

    SELECT
        *,
        SUM(new_streak_flag) OVER (
            PARTITION BY cuebiq_id
            ORDER BY event_dt
            ROWS UNBOUNDED PRECEDING
        ) AS streak_group

    FROM flagged_with_breaks
),

streak_summary AS (

    SELECT
        cuebiq_id,
        MAX(candidate_start_date) AS candidate_start_date,
        streak_group,
        MIN(event_dt) AS streak_start,
        MAX(event_dt) AS streak_end,
        COUNT(*) AS streak_length,
        DATEDIFF(DAY, MIN(event_dt), MAX(event_dt)) + 1
            AS streak_calendar_span_days

    FROM streak_grouped
    GROUP BY cuebiq_id, streak_group
),

qualifying_streaks AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id ORDER BY streak_start
        ) AS qualifying_streak_rank

    FROM streak_summary
    WHERE streak_length >= $MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN
)

SELECT
    cuebiq_id,
    candidate_start_date,
    streak_start AS return_date,
    streak_end AS return_streak_confirmed_through_date,
    streak_length AS return_streak_length,
    streak_calendar_span_days AS return_streak_calendar_span_days

FROM qualifying_streaks
WHERE qualifying_streak_rank = 1;


-- ===== sql/05_persistence/05_destination_location.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Determines each candidate evacuee's "destination" -- the place they
-- actually settled during their evacuation, as opposed to any single day's
-- noisy full-day activity center (a highway rest stop spread across a whole
-- day of driving, for example). Uses the same nighttime
-- (NIGHT_START_HOUR..NIGHT_END_HOUR) weighted-center + radius-clustering
-- machinery as 02_home_location.sql ($HOME_LOCATION_RADIUS_KM), applied to
-- the nights the candidate is confirmed to have been away: from
-- candidate_start_date through the night before their confirmed return date
-- (FL_EVAC_RETURN_DATES), or through RETURN_END if no return was detected in
-- the observed data.
--
-- Unlike home detection (which anchors on the MOST FREQUENT nightly
-- cluster), destination detection anchors on the MOST RECENT cluster that
-- reaches $MIN_CONSECUTIVE_NIGHTS_AT_DESTINATION nights -- the last place
-- they stayed for a real stretch of time, ignoring one-off transit nights
-- (a single hotel night on the way, say) that don't meet that threshold.
--
-- Note on gap tolerance: this clustering is purely distance-based -- any two
-- nights within $HOME_LOCATION_RADIUS_KM of each other are treated as the
-- same place, regardless of how many days apart they are. A missing night in
-- between two same-place nights does not break the match the way it would
-- break a date-adjacency chain (unlike 01_unfamiliar_streaks.sql /
-- 04_return_detection.sql), so $MAX_GAP_DAYS_TO_BRIDGE is NOT used here --
-- it would not mean the same thing in a radius-based match. The tradeoff:
-- if a candidate coincidentally revisited a nearby-but-unrelated location
-- twice with a long gap during their away period, this would (incorrectly)
-- merge the two visits into one cluster. Given the search window is bounded
-- to one candidate's own trip (at most a few weeks), this is judged an
-- acceptable approximation for now -- flag for QC if real data suggests
-- otherwise.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_DESTINATION
AS

WITH candidate_windows AS (

    SELECT
        c.cuebiq_id,
        c.candidate_start_date,
        COALESCE(
            DATEADD(DAY, -1, r.return_date),
            TO_DATE(TO_VARCHAR($RETURN_END), 'YYYYMMDD')
        ) AS search_end_date

    FROM DEDICATED.HOUPU.FL_EVAC_CANDIDATES AS c

    LEFT JOIN DEDICATED.HOUPU.FL_EVAC_RETURN_DATES AS r
        ON c.cuebiq_id = r.cuebiq_id
),

night_stops AS (

    SELECT
        s.cuebiq_id,
        CASE
            WHEN HOUR(s.segment_start) >= $NIGHT_START_HOUR
                THEN TO_DATE(s.segment_start)
            WHEN HOUR(s.segment_start) < $NIGHT_END_HOUR
                THEN DATEADD(DAY, -1, TO_DATE(s.segment_start))
            ELSE NULL
        END AS night_date,
        s.lat,
        s.lng,
        s.dwell_time_minutes_in_event_date

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED AS s

    INNER JOIN candidate_windows AS w
        ON s.cuebiq_id = w.cuebiq_id
       AND s.event_date BETWEEN
             TO_NUMBER(TO_VARCHAR(w.candidate_start_date, 'YYYYMMDD'))
             AND TO_NUMBER(TO_VARCHAR(w.search_end_date, 'YYYYMMDD'))
),

night_stops_filtered AS (

    SELECT *
    FROM night_stops
    WHERE night_date IS NOT NULL
),

nightly_unit_vectors AS (

    SELECT
        *,
        COS(RADIANS(lat)) * COS(RADIANS(lng)) AS sphere_x,
        COS(RADIANS(lat)) * SIN(RADIANS(lng)) AS sphere_y,
        SIN(RADIANS(lat)) AS sphere_z
    FROM night_stops_filtered
),

nightly_center AS (

    SELECT
        cuebiq_id,
        night_date,
        SUM(dwell_time_minutes_in_event_date * sphere_x)
            / SUM(dwell_time_minutes_in_event_date) AS mean_x,
        SUM(dwell_time_minutes_in_event_date * sphere_y)
            / SUM(dwell_time_minutes_in_event_date) AS mean_y,
        SUM(dwell_time_minutes_in_event_date * sphere_z)
            / SUM(dwell_time_minutes_in_event_date) AS mean_z
    FROM nightly_unit_vectors
    GROUP BY cuebiq_id, night_date
),

nightly_center_geog AS (

    SELECT
        cuebiq_id,
        night_date,
        DEGREES(ATAN2(mean_z, SQRT(mean_x * mean_x + mean_y * mean_y)))
            AS night_lat,
        DEGREES(ATAN2(mean_y, mean_x)) AS night_lng
    FROM nightly_center
),

nightly_center_final AS (

    SELECT
        *,
        ST_MAKEPOINT(night_lng, night_lat) AS night_geog
    FROM nightly_center_geog
),

night_pairs AS (

    SELECT
        a.cuebiq_id,
        a.night_date AS night_date_a,
        b.night_date AS night_date_b,
        ST_DISTANCE(a.night_geog, b.night_geog) / 1000.0 AS distance_km

    FROM nightly_center_final AS a

    INNER JOIN nightly_center_final AS b
        ON a.cuebiq_id = b.cuebiq_id
       AND a.night_date <> b.night_date
),

night_cluster_size AS (

    -- cluster_size = self (1) + however many OTHER nights are within radius
    SELECT
        c.cuebiq_id,
        c.night_date,
        1 + COALESCE(
            (
                SELECT COUNT_IF(p.distance_km <= $HOME_LOCATION_RADIUS_KM)
                FROM night_pairs AS p
                WHERE p.cuebiq_id = c.cuebiq_id
                  AND p.night_date_a = c.night_date
            ),
            0
        ) AS cluster_size

    FROM nightly_center_final AS c
),

qualifying_nights AS (

    SELECT *
    FROM night_cluster_size
    WHERE cluster_size >= $MIN_CONSECUTIVE_NIGHTS_AT_DESTINATION
),

anchor_night AS (

    SELECT
        cuebiq_id,
        night_date AS anchor_night_date,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id ORDER BY night_date DESC
        ) AS anchor_rank
    FROM qualifying_nights
),

destination_nights AS (

    SELECT a.cuebiq_id, a.anchor_night_date AS night_date
    FROM anchor_night AS a
    WHERE a.anchor_rank = 1

    UNION

    SELECT p.cuebiq_id, p.night_date_b AS night_date
    FROM night_pairs AS p
    INNER JOIN anchor_night AS a
        ON p.cuebiq_id = a.cuebiq_id
       AND p.night_date_a = a.anchor_night_date
    WHERE a.anchor_rank = 1
      AND p.distance_km <= $HOME_LOCATION_RADIUS_KM
),

destination_stops AS (

    SELECT ns.*
    FROM night_stops_filtered AS ns
    INNER JOIN destination_nights AS d
        ON ns.cuebiq_id = d.cuebiq_id
       AND ns.night_date = d.night_date
),

destination_unit_vectors AS (

    SELECT
        *,
        COS(RADIANS(lat)) * COS(RADIANS(lng)) AS sphere_x,
        COS(RADIANS(lat)) * SIN(RADIANS(lng)) AS sphere_y,
        SIN(RADIANS(lat)) AS sphere_z
    FROM destination_stops
),

destination_weighted AS (

    SELECT
        cuebiq_id,
        SUM(dwell_time_minutes_in_event_date * sphere_x)
            / SUM(dwell_time_minutes_in_event_date) AS mean_x,
        SUM(dwell_time_minutes_in_event_date * sphere_y)
            / SUM(dwell_time_minutes_in_event_date) AS mean_y,
        SUM(dwell_time_minutes_in_event_date * sphere_z)
            / SUM(dwell_time_minutes_in_event_date) AS mean_z,

        COUNT(DISTINCT night_date) AS n_destination_nights,
        MIN(night_date) AS destination_arrival_night,
        MAX(night_date) AS destination_last_confirmed_night

    FROM destination_unit_vectors
    GROUP BY cuebiq_id
),

destination_center AS (

    SELECT
        cuebiq_id,
        n_destination_nights,
        destination_arrival_night,
        destination_last_confirmed_night,
        DEGREES(ATAN2(mean_z, SQRT(mean_x * mean_x + mean_y * mean_y)))
            AS destination_lat,
        DEGREES(ATAN2(mean_y, mean_x)) AS destination_lng
    FROM destination_weighted
)

SELECT
    cuebiq_id,
    n_destination_nights,
    destination_arrival_night,
    destination_last_confirmed_night,
    destination_lat,
    destination_lng,
    ST_MAKEPOINT(destination_lng, destination_lat) AS destination_geog

FROM destination_center;


-- ===== sql/05_persistence/06_evacuation_distance.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Final summary table for the persistence stage: one row per candidate
-- evacuee, combining departure, return, home location, destination
-- location, and the single home->destination "evacuation distance" number
-- requested for this analysis. A candidate may have no confirmed return
-- in the observed data (return still pending as of RETURN_END), and
-- FL_EVAC_DESTINATION can be missing for a candidate whose away-period
-- nights never formed a qualifying same-place cluster (sparse data) --
-- those rows keep their other fields and simply have NULLs where the
-- missing piece would go. FL_HOME_LOCATION is always present here, since
-- 03_candidates.sql already inner-joins it (home-location gate); its LEFT
-- JOIN below is kept only as a harmless safeguard.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_SUMMARY
AS

SELECT
    c.cuebiq_id,

    -- departure
    c.candidate_start_date,
    c.candidate_streak_end_date,
    c.candidate_streak_length,
    c.candidate_streak_calendar_span_days,

    -- return
    r.return_date,
    r.return_streak_length,
    r.return_streak_calendar_span_days,

    -- home location
    h.n_home_nights,
    h.home_lat,
    h.home_lng,

    -- destination location
    d.n_destination_nights,
    d.destination_arrival_night,
    d.destination_last_confirmed_night,
    d.destination_lat,
    d.destination_lng,

    -- evacuation distance: single home -> destination number, NULL if
    -- either endpoint could not be determined
    CASE
        WHEN h.home_geog IS NOT NULL AND d.destination_geog IS NOT NULL
            THEN ST_DISTANCE(h.home_geog, d.destination_geog) / 1000.0
        ELSE NULL
    END AS evacuation_distance_km

FROM DEDICATED.HOUPU.FL_EVAC_CANDIDATES AS c

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_RETURN_DATES AS r
    ON c.cuebiq_id = r.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_HOME_LOCATION AS h
    ON c.cuebiq_id = h.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_DESTINATION AS d
    ON c.cuebiq_id = d.cuebiq_id;
