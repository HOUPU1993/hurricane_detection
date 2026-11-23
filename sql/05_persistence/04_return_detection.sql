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
