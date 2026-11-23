-- Run ../../PARAMETERS.sql first in the same Snowflake session.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_STOPS
AS

SELECT
    s.cuebiq_id,

    /* Resident information */
    r.home_geo10,
    r.days_in_target_cbgs,
    r.days_at_home_cbg,
    r.home_consistency,

    /* Stop information */
    s.event_date,
    s.lat,
    s.lng,
    s.geohash_id,
    s.block_group_id,

    /* Daily dwell-time weight */
    s.dwell_time_minutes_in_event_date,

    /* Original stop duration for QC */
    s.dwell_time_minutes,

    /* Time information */
    s.stop_zoned_datetime,
    s.stop_zoned_datetime_in_event_date,
    s.timezone_offset_seconds,

    /* Quality / provenance */
    s.avg_accuracy_meters,
    s.classification_type,
    s.transformation_type,
    s.provider_id,

    CASE
        WHEN s.transformation_type = 'UPLEVELLED' THEN 1
        ELSE 0
    END AS is_uplevelled

FROM CUEBIQ_DATA.PAAS_CDA_PE_V3.STOP_BY_EVENT_DATE_UPLEVELLED AS s

INNER JOIN DEDICATED.HOUPU.FL_RESIDENT AS r
    ON s.cuebiq_id = r.cuebiq_id

WHERE s.event_date BETWEEN $BASELINE_START AND $OBS_END
  AND s.provider_id IN ($PROVIDER_1, $PROVIDER_2)
  AND (
        $EXCLUDE_UPLEVELLED = 0
        OR s.transformation_type <> 'UPLEVELLED'
      )
  AND s.dwell_time_minutes_in_event_date > 0
  AND s.lat IS NOT NULL
  AND s.lng IS NOT NULL;
