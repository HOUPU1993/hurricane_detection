-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Final individual-level table: one row per FL_RESIDENT device.
--
--   in_cohort        1 if the device passed the cohort data requirements
--   evacuee          NULL if not in cohort; 1 if a departure was detected; else 0
--   departure_phase  1 (pre-landfall), 2 (landfall), 3 (post-landfall)
--   returned_by_end  NULL for non-evacuees; 1 if a return was detected by OBS_END
--   days_away        return_date - departure_date (NULL if not returned)
--   home_cbg         HOME_GEO10 from 00_residents_detection (Cuebiq recurring home)
--   destination_cbg  12-digit GEO10 of the destination block group
--
-- Aggregation to CBG and any distance calculation are done outside Snowflake.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_INDIVIDUAL
AS

SELECT
    r.cuebiq_id,
    r.home_geo10 AS home_cbg,

    IFF(c.cuebiq_id IS NOT NULL, 1, 0) AS in_cohort,

    CASE
        WHEN c.cuebiq_id IS NULL THEN NULL
        WHEN d.cuebiq_id IS NOT NULL THEN 1
        ELSE 0
    END AS evacuee,

    d.departure_phase,
    d.departure_date,
    d.departure_streak_end_date,
    d.departure_streak_length,

    t.return_date,
    CASE
        WHEN d.cuebiq_id IS NULL THEN NULL
        WHEN t.return_date IS NOT NULL THEN 1
        ELSE 0
    END AS returned_by_end,
    t.days_away,

    x.destination_cbg,
    x.destination_block_group_id,
    x.destination_n_nights,
    x.destination_night_share

FROM DEDICATED.HOUPU.FL_RESIDENT AS r

LEFT JOIN DEDICATED.HOUPU.FL_ALLDAY_COHORT AS c
    ON r.cuebiq_id = c.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_DEPARTURE AS d
    ON r.cuebiq_id = d.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_RETURN AS t
    ON r.cuebiq_id = t.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_DESTINATION_CBG AS x
    ON r.cuebiq_id = x.cuebiq_id;
