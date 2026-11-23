/*
===============================================================================
HURRICANE IAN EVACUATION DETECTION — PARAMETERS (main_v6)
===============================================================================
Edit this file when changing the main specification or running sensitivity tests.
Run this file first in the same Snowflake session before running the SQL scripts
(sql/00_residents_detection does not read it; see that folder's README).
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
-- Baseline: each user's normal mobility (reference for unfamiliarity).
SET BASELINE_START = 20220902;
SET BASELINE_END   = 20220922;

-- Departure phases. A departure is assigned to the phase in which its
-- unfamiliar streak STARTS; the streak itself may cross phase boundaries.
--   Phase 1 (pre-landfall):   PHASE1_START .. PHASE2_START - 1   (9/23-9/27)
--   Phase 2 (landfall):       PHASE2_START .. PHASE3_START - 1   (9/28-9/30)
--   Phase 3 (post-landfall):  PHASE3_START .. DEPARTURE_END      (10/1-10/7)
-- PHASE2_START is Ian's landfall day; phase-1 departures must still be away
-- on this day (see 05_persistence/02_departure.sql).
SET PHASE1_START  = 20220923;
SET PHASE2_START  = 20220928;
SET PHASE3_START  = 20221001;
SET DEPARTURE_END = 20221007;

-- End of observation: last day used for streaks, return detection and
-- destination search.
SET OBS_END = 20221023;

-- -----------------------------------------------------------------------------
-- Eligible user-day definition
-- -----------------------------------------------------------------------------
SET MIN_COVERED_STOP_MINUTES     = 120;
SET MIN_OBSERVATION_SPAN_MINUTES = 240;
SET MAX_OVERLAPPING_ROWS         = 0;

-- -----------------------------------------------------------------------------
-- Analysis cohort
-- -----------------------------------------------------------------------------
SET MIN_BASELINE_ELIGIBLE_DAYS         = 14;  -- within BASELINE_START..BASELINE_END
SET MIN_DEPARTURE_WINDOW_ELIGIBLE_DAYS = 3;   -- within PHASE1_START..DEPARTURE_END

-- -----------------------------------------------------------------------------
-- Spatial unfamiliarity
-- -----------------------------------------------------------------------------
SET K_NEIGHBORS = 3;

-- Rule (04_unfamiliarity/03_unfamiliar_days.sql):
-- day kNN score > maximum baseline leave-one-out kNN score

-- -----------------------------------------------------------------------------
-- Departure and return
-- -----------------------------------------------------------------------------
-- Minimum confirmed unfamiliar days in a departure streak (all phases).
SET MIN_CONSECUTIVE_UNFAMILIAR_DAYS = 2;

-- Minimum confirmed familiar days in a return streak.
SET MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN = 2;

-- Up to this many consecutive missing/ineligible days are bridged inside a
-- streak. A confirmed opposite-state day always breaks a streak.
SET MAX_GAP_DAYS_TO_BRIDGE = 2;

-- -----------------------------------------------------------------------------
-- Destination CBG
-- -----------------------------------------------------------------------------
-- Night window (wraps past midnight). Destination = the block group with the
-- most night-window stop minutes between departure and return.
SET NIGHT_START_HOUR = 21;
SET NIGHT_END_HOUR   = 7;


-- ===== sql/00_residents_detection/residents_detection.sql =====
-- residents_detection
-- Builds DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_FULL: one row per device whose
-- Cuebiq DEVICE_RECURRING_AREA home falls in a mandatory-evacuation-zone CBG
-- (HURRICANE_IAN_MANDATORY_CBG_CROSS) on at least one baseline day, with
-- daily home CBGs (21 columns), summary metrics, and five IS_RESID_* flags.
-- Consumed by ../01_preprocessing/00_build_resident.sql (IS_RESID_1_5 = 1).
--
-- Does NOT read PARAMETERS.sql: the baseline window (20220902..20220922) and
-- its length (21 days) are hard-coded below and must be kept in sync with
-- BASELINE_START / BASELINE_END by hand.
--
-- QC queries (optional, commented out):
--   (a) devices reported by more than one provider during baseline;
--   (b) device-days with more than one distinct HOME block group.

-- SELECT CUEBIQ_ID, COUNT(DISTINCT PROVIDER_ID) AS N_PROVIDERS
-- FROM CUEBIQ_DATA.PAAS_CDA_PE_V3.DEVICE_RECURRING_AREA
-- WHERE COUNTRY_CODE = 'US'
--   AND SNAPSHOT_EVENT_DATE BETWEEN 20220902 AND 20220922
-- GROUP BY CUEBIQ_ID
-- HAVING COUNT(DISTINCT PROVIDER_ID) > 1;

-- SELECT CUEBIQ_ID, SNAPSHOT_EVENT_DATE, COUNT(DISTINCT BLOCK_GROUP_ID) AS N_DISTINCT_CBG
-- FROM CUEBIQ_DATA.PAAS_CDA_PE_V3.DEVICE_RECURRING_AREA
-- WHERE COUNTRY_CODE = 'US'
--   AND TAG_TYPE_CODE = 'HOME'
--   AND SNAPSHOT_EVENT_DATE BETWEEN 20220902 AND 20220922
-- GROUP BY CUEBIQ_ID, SNAPSHOT_EVENT_DATE
-- HAVING COUNT(DISTINCT BLOCK_GROUP_ID) > 1;

-- STEP 0: CBG lookup -- convert 12-digit GEO10 (state 2, county 3, tract 6,
-- block group 1) into Cuebiq's BLOCK_GROUP_ID format 'US.FL.ccc.tttttt.b'.
CREATE OR REPLACE TABLE DEDICATED.HOUPU.CBG_CUEBIQ_LOOKUP AS
SELECT
    GEO20,
    GEO10,
    'US.FL.' || SUBSTR(GEO10, 3, 3) || '.' || SUBSTR(GEO10, 6, 6) || '.' || SUBSTR(GEO10, 12, 1)
        AS CUEBIQ_BLOCK_GROUP_ID
FROM DEDICATED.HOUPU.HURRICANE_IAN_MANDATORY_CBG_CROSS;

-- STEP 1: daily home detail. Keep HOME tags in target CBGs with
-- CONFIDENCE_LEVEL > 0.5; if a device has several on the same day, keep the
-- one with the highest CONFIDENCE_LEVEL (ties -> lowest GEO10).
-- Note: the join to target CBGs happens BEFORE the daily ranking, so a
-- lower-confidence target-CBG home still counts on a day when the device's
-- top-confidence home is outside the target area.
CREATE OR REPLACE TABLE DEDICATED.HOUPU.IAN_RECURRING_HOME_DAILY AS
WITH joined AS (
    SELECT
        d.CUEBIQ_ID,
        l.GEO10,
        TO_DATE(TO_VARCHAR(d.SNAPSHOT_EVENT_DATE), 'YYYYMMDD') AS SNAPSHOT_DATE,
        d.CONFIDENCE_LEVEL,
        d.PROVIDER_ID
    FROM CUEBIQ_DATA.PAAS_CDA_PE_V3.DEVICE_RECURRING_AREA d
    JOIN DEDICATED.HOUPU.CBG_CUEBIQ_LOOKUP l
        ON d.BLOCK_GROUP_ID = l.CUEBIQ_BLOCK_GROUP_ID
    WHERE d.TAG_TYPE_CODE = 'HOME'
      AND d.COUNTRY_CODE = 'US'
      AND d.SNAPSHOT_EVENT_DATE BETWEEN 20220902 AND 20220922
      AND d.CONFIDENCE_LEVEL > 0.5   -- confidence floor
),
ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY CUEBIQ_ID, SNAPSHOT_DATE
            ORDER BY CONFIDENCE_LEVEL DESC, GEO10 ASC
        ) AS rn
    FROM joined
)
SELECT CUEBIQ_ID, GEO10, SNAPSHOT_DATE
FROM ranked
WHERE rn = 1;

-- STEP 2: per-device summary + five IS_RESID tiers (intermediate table, dropped below).
-- DAYS_IN_TARGET_CBGS = days with a home in ANY target CBG; HOME_GEO10 = the
-- CBG with the most days; IS_RESID_a_b = DAYS_IN_TARGET_CBGS >= CEIL(21 * a/b),
-- i.e. 1_5 >= 5, 1_4 >= 6, 1_3 >= 7, 1_2 >= 11, 2_3 >= 14 days.
CREATE OR REPLACE TABLE DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_SUMMARY AS
WITH total_days AS (
    SELECT CUEBIQ_ID, COUNT(DISTINCT SNAPSHOT_DATE) AS DAYS_IN_TARGET_CBGS
    FROM DEDICATED.HOUPU.IAN_RECURRING_HOME_DAILY
    GROUP BY CUEBIQ_ID
),
device_geo10_days AS (
    SELECT CUEBIQ_ID, GEO10, COUNT(DISTINCT SNAPSHOT_DATE) AS DAYS_AT_THIS_CBG
    FROM DEDICATED.HOUPU.IAN_RECURRING_HOME_DAILY
    GROUP BY CUEBIQ_ID, GEO10
),
home_ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY CUEBIQ_ID
            ORDER BY DAYS_AT_THIS_CBG DESC, GEO10 ASC
        ) AS rn
    FROM device_geo10_days
),
home AS (
    SELECT CUEBIQ_ID, GEO10 AS HOME_GEO10, DAYS_AT_THIS_CBG AS DAYS_AT_HOME_CBG
    FROM home_ranked WHERE rn = 1
)
SELECT
    t.CUEBIQ_ID,
    h.HOME_GEO10,
    t.DAYS_IN_TARGET_CBGS,
    h.DAYS_AT_HOME_CBG,
    ROUND(h.DAYS_AT_HOME_CBG / t.DAYS_IN_TARGET_CBGS, 2) AS HOME_CONSISTENCY,
    CASE WHEN t.DAYS_IN_TARGET_CBGS >= CEIL(21 * 1.0/5) THEN 1 ELSE 0 END AS IS_RESID_1_5,
    CASE WHEN t.DAYS_IN_TARGET_CBGS >= CEIL(21 * 1.0/4) THEN 1 ELSE 0 END AS IS_RESID_1_4,
    CASE WHEN t.DAYS_IN_TARGET_CBGS >= CEIL(21 * 1.0/3) THEN 1 ELSE 0 END AS IS_RESID_1_3,
    CASE WHEN t.DAYS_IN_TARGET_CBGS >= CEIL(21 * 1.0/2) THEN 1 ELSE 0 END AS IS_RESID_1_2,
    CASE WHEN t.DAYS_IN_TARGET_CBGS >= CEIL(21 * 2.0/3) THEN 1 ELSE 0 END AS IS_RESID_2_3
FROM total_days t
JOIN home h ON t.CUEBIQ_ID = h.CUEBIQ_ID;

-- STEP 3: pivot daily home GEO10 into 21 date columns + attach STEP 2 summary -- final table
CREATE OR REPLACE TABLE DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_FULL AS
WITH pivoted AS (
    SELECT *
    FROM DEDICATED.HOUPU.IAN_RECURRING_HOME_DAILY
    PIVOT (MAX(GEO10) FOR SNAPSHOT_DATE IN (
        '2022-09-02','2022-09-03','2022-09-04','2022-09-05','2022-09-06',
        '2022-09-07','2022-09-08','2022-09-09','2022-09-10','2022-09-11',
        '2022-09-12','2022-09-13','2022-09-14','2022-09-15','2022-09-16',
        '2022-09-17','2022-09-18','2022-09-19','2022-09-20','2022-09-21',
        '2022-09-22'
    )) AS p (
        CUEBIQ_ID,
        "2022-09-02","2022-09-03","2022-09-04","2022-09-05","2022-09-06",
        "2022-09-07","2022-09-08","2022-09-09","2022-09-10","2022-09-11",
        "2022-09-12","2022-09-13","2022-09-14","2022-09-15","2022-09-16",
        "2022-09-17","2022-09-18","2022-09-19","2022-09-20","2022-09-21",
        "2022-09-22"
    )
)
SELECT
    p.*,
    s.HOME_GEO10,
    s.DAYS_IN_TARGET_CBGS,
    s.DAYS_AT_HOME_CBG,
    s.HOME_CONSISTENCY,
    s.IS_RESID_1_5,
    s.IS_RESID_1_4,
    s.IS_RESID_1_3,
    s.IS_RESID_1_2,
    s.IS_RESID_2_3
FROM pivoted p
JOIN DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_SUMMARY s
    ON p.CUEBIQ_ID = s.CUEBIQ_ID;

-- CLEANUP: keep only FL_RECURRING_RESIDENTS_FULL; drop intermediate tables
DROP TABLE IF EXISTS DEDICATED.HOUPU.IAN_RECURRING_HOME_DAILY;
DROP TABLE IF EXISTS DEDICATED.HOUPU.CBG_CUEBIQ_LOOKUP;
DROP TABLE IF EXISTS DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_SUMMARY;



-- ===== sql/01_preprocessing/00_build_resident.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Builds DEDICATED.HOUPU.FL_RESIDENT, the target-resident population that
-- every downstream file in this pipeline (01_extract_stops.sql via INNER
-- JOIN, 02_cohort/01_analysis_cohort.sql via FROM) depends on. This table
-- was previously assumed to already exist; it is actually derived from
-- Houpu's residency-qualification table DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_FULL
-- (built by sql/00_residents_detection/residents_detection.sql),
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

WHERE s.event_date BETWEEN $BASELINE_START AND $OBS_END
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
        d.event_date BETWEEN $PHASE1_START AND $DEPARTURE_END
        AND d.eligible_day = 1
    ) AS n_departure_window_eligible_days,

    COUNT_IF(
        d.event_date > $DEPARTURE_END
        AND d.event_date <= $OBS_END
        AND d.eligible_day = 1
    ) AS n_post_window_eligible_days,

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
  AND n_departure_window_eligible_days >= $MIN_DEPARTURE_WINDOW_ELIGIBLE_DAYS;


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
-- Scores every day from PHASE1_START through OBS_END (9/23-10/23) against the
-- user's baseline daily centers. Covering the whole post-baseline range lets
-- 05_persistence build departure streaks (which may run past DEPARTURE_END)
-- and detect returns up to OBS_END. The table name FL_EVAC_KNN is kept for
-- continuity; 03_unfamiliar_days.sql joins to it by name.

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
    WHERE event_date BETWEEN $PHASE1_START AND $OBS_END
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


-- ===== sql/05_persistence/01_daily_states.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- One row per cohort user per calendar day from PHASE1_START through OBS_END.
-- Used by both departure (02) and return (03) detection.
--
--   day_state 1 = unfamiliar  (FL_EVAC_KNN_RARITY row, unfamiliar_day = 1)
--   day_state 2 = familiar    (FL_EVAC_KNN_RARITY row, unfamiliar_day = 0)
--   day_state 3 = missing     (no row: day not eligible / not scored)
--
--   phase 1 = PHASE1_START .. PHASE2_START - 1   (pre-landfall)
--   phase 2 = PHASE2_START .. PHASE3_START - 1   (landfall)
--   phase 3 = PHASE3_START .. DEPARTURE_END      (post-landfall)
--   phase 4 = after DEPARTURE_END                (return-only days)

-- GENERATOR(ROWCOUNT => ...) requires a constant, so precompute the day count.
SET N_STATE_DAYS = (
    SELECT DATEDIFF(
        DAY,
        TO_DATE(TO_VARCHAR($PHASE1_START), 'YYYYMMDD'),
        TO_DATE(TO_VARCHAR($OBS_END), 'YYYYMMDD')
    ) + 1
);

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_DAILY_STATE
AS

WITH cohort_users AS (

    SELECT DISTINCT cuebiq_id
    FROM DEDICATED.HOUPU.FL_ALLDAY_COHORT
),

calendar AS (

    SELECT
        DATEADD(
            DAY, SEQ4(),
            TO_DATE(TO_VARCHAR($PHASE1_START), 'YYYYMMDD')
        ) AS event_dt

    FROM TABLE(GENERATOR(ROWCOUNT => $N_STATE_DAYS))
)

SELECT
    u.cuebiq_id,
    c.event_dt,

    CASE
        WHEN r.unfamiliar_day = 1 THEN 1
        WHEN r.unfamiliar_day = 0 THEN 2
        ELSE 3
    END AS day_state,

    CASE
        WHEN c.event_dt < TO_DATE(TO_VARCHAR($PHASE2_START), 'YYYYMMDD') THEN 1
        WHEN c.event_dt < TO_DATE(TO_VARCHAR($PHASE3_START), 'YYYYMMDD') THEN 2
        WHEN c.event_dt <= TO_DATE(TO_VARCHAR($DEPARTURE_END), 'YYYYMMDD') THEN 3
        ELSE 4
    END AS phase

FROM cohort_users AS u

CROSS JOIN calendar AS c

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_KNN_RARITY AS r
    ON u.cuebiq_id = r.cuebiq_id
   AND c.event_dt = TO_DATE(TO_VARCHAR(r.event_date), 'YYYYMMDD');


-- ===== sql/05_persistence/02_departure.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Departure detection. One row per evacuee (cohort users with no qualifying
-- streak are not in this table).
--
-- 1. Build unfamiliar streaks over the full FL_DAILY_STATE range
--    (PHASE1_START..OBS_END), so a streak can cross phase boundaries.
--    A familiar day always breaks a streak; up to MAX_GAP_DAYS_TO_BRIDGE
--    consecutive missing days are bridged.
-- 2. A streak qualifies when:
--      - it STARTS between PHASE1_START and DEPARTURE_END;
--      - it has >= MIN_CONSECUTIVE_UNFAMILIAR_DAYS confirmed unfamiliar days;
--      - phase 1 only: the person is still away on PHASE2_START (landfall),
--        i.e. the streak ends within MAX_GAP_DAYS_TO_BRIDGE days of landfall
--        (or later) and no familiar day falls between its end and landfall.
-- 3. The earliest qualifying streak is the departure; its start date is
--    departure_date and the phase of that date is departure_phase.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_DEPARTURE
AS

WITH states AS (

    SELECT
        *,
        MAX(CASE WHEN day_state = 2 THEN event_dt END) OVER (
            PARTITION BY cuebiq_id
            ORDER BY event_dt
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS last_familiar_dt,

        MIN(CASE WHEN day_state = 2 THEN event_dt END) OVER (
            PARTITION BY cuebiq_id
            ORDER BY event_dt
            ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING
        ) AS next_familiar_dt

    FROM DEDICATED.HOUPU.FL_DAILY_STATE
),

unfamiliar_only AS (

    SELECT
        *,
        LAG(event_dt) OVER (
            PARTITION BY cuebiq_id ORDER BY event_dt
        ) AS prev_unfamiliar_dt

    FROM states
    WHERE day_state = 1
),

flagged AS (

    SELECT
        *,
        CASE
            WHEN prev_unfamiliar_dt IS NULL THEN 1
            WHEN last_familiar_dt > prev_unfamiliar_dt THEN 1
            WHEN DATEDIFF(DAY, prev_unfamiliar_dt, event_dt) - 1
                 > $MAX_GAP_DAYS_TO_BRIDGE THEN 1
            ELSE 0
        END AS new_streak_flag

    FROM unfamiliar_only
),

grouped AS (

    SELECT
        *,
        SUM(new_streak_flag) OVER (
            PARTITION BY cuebiq_id
            ORDER BY event_dt
            ROWS UNBOUNDED PRECEDING
        ) AS streak_group

    FROM flagged
),

streaks AS (

    SELECT
        cuebiq_id,
        streak_group,
        MIN(event_dt) AS streak_start,
        MAX(event_dt) AS streak_end,
        COUNT(*) AS streak_length,
        DATEDIFF(DAY, MIN(event_dt), MAX(event_dt)) + 1 AS streak_calendar_span_days,

        -- No familiar day can fall inside a streak, so every row shares the
        -- same next familiar day after the streak.
        MAX(next_familiar_dt) AS next_familiar_dt

    FROM grouped
    GROUP BY cuebiq_id, streak_group
),

bounds AS (

    SELECT
        TO_DATE(TO_VARCHAR($PHASE1_START), 'YYYYMMDD')  AS phase1_dt,
        TO_DATE(TO_VARCHAR($PHASE2_START), 'YYYYMMDD')  AS phase2_dt,
        TO_DATE(TO_VARCHAR($PHASE3_START), 'YYYYMMDD')  AS phase3_dt,
        TO_DATE(TO_VARCHAR($DEPARTURE_END), 'YYYYMMDD') AS departure_end_dt
),

classified AS (

    SELECT
        s.*,

        CASE
            WHEN s.streak_start < b.phase2_dt THEN 1
            WHEN s.streak_start < b.phase3_dt THEN 2
            ELSE 3
        END AS departure_phase,

        CASE
            WHEN DATEDIFF(DAY, s.streak_end, b.phase2_dt) <= $MAX_GAP_DAYS_TO_BRIDGE
             AND (s.next_familiar_dt IS NULL OR s.next_familiar_dt > b.phase2_dt)
            THEN 1
            ELSE 0
        END AS away_at_landfall

    FROM streaks AS s
    CROSS JOIN bounds AS b
    WHERE s.streak_start BETWEEN b.phase1_dt AND b.departure_end_dt
      AND s.streak_length >= $MIN_CONSECUTIVE_UNFAMILIAR_DAYS
),

qualifying AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id ORDER BY streak_start
        ) AS departure_rank

    FROM classified
    WHERE departure_phase <> 1
       OR away_at_landfall = 1
)

SELECT
    cuebiq_id,
    streak_start              AS departure_date,
    departure_phase,
    streak_end                AS departure_streak_end_date,
    streak_length             AS departure_streak_length,
    streak_calendar_span_days AS departure_streak_calendar_span_days

FROM qualifying
WHERE departure_rank = 1;


-- ===== sql/05_persistence/03_return.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Return detection, same rule for all departure phases. Mirrors the
-- departure streak logic with states swapped: familiar days build a streak,
-- an unfamiliar day always breaks it, and up to MAX_GAP_DAYS_TO_BRIDGE
-- consecutive missing days are bridged.
--
-- return_date = start of the first familiar streak that begins after
-- departure_streak_end_date and has >= MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN
-- confirmed familiar days, searched through OBS_END. Evacuees with no such
-- streak have no row (not returned by OBS_END).

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_RETURN
AS

WITH states AS (

    SELECT
        s.*,
        d.departure_date,
        d.departure_streak_end_date,
        MAX(CASE WHEN s.day_state = 1 THEN s.event_dt END) OVER (
            PARTITION BY s.cuebiq_id
            ORDER BY s.event_dt
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS last_unfamiliar_dt

    FROM DEDICATED.HOUPU.FL_DAILY_STATE AS s

    INNER JOIN DEDICATED.HOUPU.FL_EVAC_DEPARTURE AS d
        ON s.cuebiq_id = d.cuebiq_id
),

familiar_only AS (

    SELECT
        *,
        LAG(event_dt) OVER (
            PARTITION BY cuebiq_id ORDER BY event_dt
        ) AS prev_familiar_dt

    FROM states
    WHERE day_state = 2
),

flagged AS (

    SELECT
        *,
        CASE
            WHEN prev_familiar_dt IS NULL THEN 1
            WHEN last_unfamiliar_dt > prev_familiar_dt THEN 1
            WHEN DATEDIFF(DAY, prev_familiar_dt, event_dt) - 1
                 > $MAX_GAP_DAYS_TO_BRIDGE THEN 1
            ELSE 0
        END AS new_streak_flag

    FROM familiar_only
),

grouped AS (

    SELECT
        *,
        SUM(new_streak_flag) OVER (
            PARTITION BY cuebiq_id
            ORDER BY event_dt
            ROWS UNBOUNDED PRECEDING
        ) AS streak_group

    FROM flagged
),

streaks AS (

    SELECT
        cuebiq_id,
        streak_group,
        MAX(departure_date) AS departure_date,
        MAX(departure_streak_end_date) AS departure_streak_end_date,
        MIN(event_dt) AS streak_start,
        MAX(event_dt) AS streak_end,
        COUNT(*) AS streak_length

    FROM grouped
    GROUP BY cuebiq_id, streak_group
),

qualifying AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id ORDER BY streak_start
        ) AS return_rank

    FROM streaks
    WHERE streak_start > departure_streak_end_date
      AND streak_length >= $MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN
)

SELECT
    cuebiq_id,
    streak_start  AS return_date,
    streak_end    AS return_streak_confirmed_through_date,
    streak_length AS return_streak_length,
    DATEDIFF(DAY, departure_date, streak_start) AS days_away

FROM qualifying
WHERE return_rank = 1;


-- ===== sql/05_persistence/04_destination_cbg.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Destination CBG for each evacuee: the block group with the most
-- night-window stop minutes during the away period.
--
-- Away period (by night): departure_date .. return_date - 1, or .. OBS_END
-- when no return was detected. Night d covers NIGHT_START_HOUR on day d to
-- NIGHT_END_HOUR on day d + 1.
--
-- Reads FL_ALLDAY_STOPS_UNIONED (overlap-resolved stops), so overlapping
-- records are not double-counted. Each stop interval (which lies within one
-- event_date) is clipped to the night window in minutes:
--   morning part [00:00, NIGHT_END_HOUR)   -> night of event_date - 1
--   evening part [NIGHT_START_HOUR, 24:00) -> night of event_date
--
-- Cuebiq block_group_id ('US.<ST>.<county3>.<tract6>.<bg1>') is converted to
-- a 12-digit GEO10 via a state-abbreviation -> FIPS lookup; IDs that do not
-- match that format get destination_cbg = NULL (raw ID is kept).

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_DESTINATION_CBG
AS

WITH windows AS (

    SELECT
        d.cuebiq_id,
        d.departure_date AS first_night,
        COALESCE(
            DATEADD(DAY, -1, r.return_date),
            TO_DATE(TO_VARCHAR($OBS_END), 'YYYYMMDD')
        ) AS last_night

    FROM DEDICATED.HOUPU.FL_EVAC_DEPARTURE AS d

    LEFT JOIN DEDICATED.HOUPU.FL_EVAC_RETURN AS r
        ON d.cuebiq_id = r.cuebiq_id
),

stops AS (

    SELECT
        s.cuebiq_id,
        w.first_night,
        w.last_night,
        s.block_group_id,
        TO_DATE(TO_VARCHAR(s.event_date), 'YYYYMMDD') AS event_dt,
        HOUR(s.segment_start) * 60
            + MINUTE(s.segment_start)
            + SECOND(s.segment_start) / 60.0 AS start_min,
        HOUR(s.segment_start) * 60
            + MINUTE(s.segment_start)
            + SECOND(s.segment_start) / 60.0
            + s.dwell_time_minutes_in_event_date AS end_min

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED AS s

    INNER JOIN windows AS w
        ON s.cuebiq_id = w.cuebiq_id
       AND TO_DATE(TO_VARCHAR(s.event_date), 'YYYYMMDD')
           BETWEEN w.first_night AND DATEADD(DAY, 1, w.last_night)

    WHERE s.block_group_id IS NOT NULL
),

night_parts AS (

    SELECT
        cuebiq_id, first_night, last_night, block_group_id,
        DATEADD(DAY, -1, event_dt) AS night_date,
        GREATEST(0, LEAST(end_min, $NIGHT_END_HOUR * 60) - start_min) AS night_minutes
    FROM stops

    UNION ALL

    SELECT
        cuebiq_id, first_night, last_night, block_group_id,
        event_dt AS night_date,
        GREATEST(0, LEAST(end_min, 1440) - GREATEST(start_min, $NIGHT_START_HOUR * 60)) AS night_minutes
    FROM stops
),

away_nights AS (

    SELECT *
    FROM night_parts
    WHERE night_minutes > 0
      AND night_date BETWEEN first_night AND last_night
),

by_cbg AS (

    SELECT
        cuebiq_id,
        block_group_id,
        SUM(night_minutes) AS cbg_night_minutes,
        COUNT(DISTINCT night_date) AS n_nights_at_cbg

    FROM away_nights
    GROUP BY cuebiq_id, block_group_id
),

ranked AS (

    SELECT
        *,
        SUM(cbg_night_minutes) OVER (PARTITION BY cuebiq_id) AS total_night_minutes,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id
            ORDER BY cbg_night_minutes DESC, block_group_id ASC
        ) AS cbg_rank

    FROM by_cbg
),

fips_lookup (state_abbr, state_fips) AS (

    SELECT * FROM VALUES
        ('AL','01'),('AK','02'),('AZ','04'),('AR','05'),('CA','06'),('CO','08'),
        ('CT','09'),('DE','10'),('DC','11'),('FL','12'),('GA','13'),('HI','15'),
        ('ID','16'),('IL','17'),('IN','18'),('IA','19'),('KS','20'),('KY','21'),
        ('LA','22'),('ME','23'),('MD','24'),('MA','25'),('MI','26'),('MN','27'),
        ('MS','28'),('MO','29'),('MT','30'),('NE','31'),('NV','32'),('NH','33'),
        ('NJ','34'),('NM','35'),('NY','36'),('NC','37'),('ND','38'),('OH','39'),
        ('OK','40'),('OR','41'),('PA','42'),('RI','44'),('SC','45'),('SD','46'),
        ('TN','47'),('TX','48'),('UT','49'),('VT','50'),('VA','51'),('WA','53'),
        ('WV','54'),('WI','55'),('WY','56'),('PR','72')
)

SELECT
    r.cuebiq_id,
    r.block_group_id AS destination_block_group_id,

    CASE
        WHEN f.state_fips IS NOT NULL
         AND LENGTH(SPLIT_PART(r.block_group_id, '.', 3)) = 3
         AND LENGTH(SPLIT_PART(r.block_group_id, '.', 4)) = 6
         AND LENGTH(SPLIT_PART(r.block_group_id, '.', 5)) = 1
        THEN f.state_fips
             || SPLIT_PART(r.block_group_id, '.', 3)
             || SPLIT_PART(r.block_group_id, '.', 4)
             || SPLIT_PART(r.block_group_id, '.', 5)
    END AS destination_cbg,

    r.cbg_night_minutes AS destination_night_minutes,
    r.n_nights_at_cbg   AS destination_n_nights,
    ROUND(r.cbg_night_minutes / NULLIF(r.total_night_minutes, 0), 3)
        AS destination_night_share

FROM ranked AS r

LEFT JOIN fips_lookup AS f
    ON SPLIT_PART(r.block_group_id, '.', 2) = f.state_abbr

WHERE r.cbg_rank = 1;


-- ===== sql/05_persistence/05_individual_table.sql =====
-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Final individual-level table: one row per FL_RESIDENT device.
--
--   in_cohort        1 if the device passed the cohort data requirements
--   evacuee          NULL if not in cohort; 1 if a departure was detected; else 0
--   departure_phase  1 (pre-landfall), 2 (landfall), 3 (post-landfall)
--   returned_by_end  NULL for non-evacuees; 1 if a return was detected by OBS_END
--   days_away        return_date - departure_date (NULL if not returned)
--   home_cbg         HOME_GEO10 from 00_residents_detection (Cuebiq recurring home)
--   destination_cbg  12-digit GEO10 of the destination block group
--
-- Aggregation to CBG and any distance calculation are done outside Snowflake.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_INDIVIDUAL
AS

SELECT
    r.cuebiq_id,
    r.home_geo10 AS home_cbg,

    IFF(c.cuebiq_id IS NOT NULL, 1, 0) AS in_cohort,

    CASE
        WHEN c.cuebiq_id IS NULL THEN NULL
        WHEN d.cuebiq_id IS NOT NULL THEN 1
        ELSE 0
    END AS evacuee,

    d.departure_phase,
    d.departure_date,
    d.departure_streak_end_date,
    d.departure_streak_length,

    t.return_date,
    CASE
        WHEN d.cuebiq_id IS NULL THEN NULL
        WHEN t.return_date IS NOT NULL THEN 1
        ELSE 0
    END AS returned_by_end,
    t.days_away,

    x.destination_cbg,
    x.destination_block_group_id,
    x.destination_n_nights,
    x.destination_night_share

FROM DEDICATED.HOUPU.FL_RESIDENT AS r

LEFT JOIN DEDICATED.HOUPU.FL_ALLDAY_COHORT AS c
    ON r.cuebiq_id = c.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_DEPARTURE AS d
    ON r.cuebiq_id = d.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_RETURN AS t
    ON r.cuebiq_id = t.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_DESTINATION_CBG AS x
    ON r.cuebiq_id = x.cuebiq_id;
