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
