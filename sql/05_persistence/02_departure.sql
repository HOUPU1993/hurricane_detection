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
