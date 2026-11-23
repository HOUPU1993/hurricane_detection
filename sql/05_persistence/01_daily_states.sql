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
