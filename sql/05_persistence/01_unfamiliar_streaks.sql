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
