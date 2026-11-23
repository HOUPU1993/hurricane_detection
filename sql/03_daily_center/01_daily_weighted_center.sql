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
