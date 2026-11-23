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
        d.event_date BETWEEN $EVAC_START AND $EVAC_END
        AND d.eligible_day = 1
    ) AS n_evacuation_eligible_days,

    COUNT_IF(
        d.event_date BETWEEN $RETURN_START AND $RETURN_END
        AND d.eligible_day = 1
    ) AS n_return_eligible_days,

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
  AND n_evacuation_eligible_days >= $MIN_EVAC_ELIGIBLE_DAYS;
