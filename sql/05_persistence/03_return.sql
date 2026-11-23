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
