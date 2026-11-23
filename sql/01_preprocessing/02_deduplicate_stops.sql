-- Run ../../PARAMETERS.sql first in the same Snowflake session.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_STOPS_DEDUP
AS

WITH parsed AS (

    SELECT
        t.*,
        TRY_TO_TIMESTAMP_TZ(stop_zoned_datetime_in_event_date) AS segment_start

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS AS t
),

intervalized AS (

    SELECT
        *,
        DATEADD(
            SECOND,
            ROUND(dwell_time_minutes_in_event_date * 60)::INTEGER,
            segment_start
        ) AS segment_end

    FROM parsed
    WHERE segment_start IS NOT NULL
),

deduped AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY
                cuebiq_id,
                event_date,
                lat,
                lng,
                segment_start,
                segment_end
            ORDER BY avg_accuracy_meters ASC NULLS LAST
        ) AS duplicate_rank

    FROM intervalized
)

SELECT * EXCLUDE (duplicate_rank)
FROM deduped
WHERE duplicate_rank = 1;
