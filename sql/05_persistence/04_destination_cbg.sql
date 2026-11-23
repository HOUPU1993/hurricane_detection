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
