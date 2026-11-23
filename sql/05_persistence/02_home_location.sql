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
