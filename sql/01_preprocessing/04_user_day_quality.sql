-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Reads DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED (the output of
-- 03_overlapping_time_union.sql), not the raw FL_ALLDAY_STOPS_DEDUP.
-- By the time records reach this file, same-location duplicates have
-- already been unioned and cross-location conflicts have already been
-- trimmed down to their disputed portion only (see 03's header for the
-- full algorithm). So N_OVERLAPPING_ROWS / CONFLICT_DAY below should
-- rarely fire in practice now -- this check has shifted from being the
-- primary defense against overlapping data to a safety-net assertion:
-- if it DOES fire on real data, that is a signal that 03's resolution
-- logic missed an edge case and should be revisited, not evidence that
-- this check is unnecessary.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_ALLDAY_USER_DAY
AS

WITH ordered_stops AS (

    SELECT
        t.*,
        MAX(segment_end) OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY segment_start, segment_end
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS latest_previous_end

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED AS t
),

conflict_days AS (

    SELECT
        cuebiq_id,
        event_date,
        COUNT_IF(
            latest_previous_end IS NOT NULL
            AND segment_start < latest_previous_end
        ) AS n_overlapping_rows

    FROM ordered_stops
    GROUP BY cuebiq_id, event_date
),

island_starts AS (

    SELECT
        *,
        CASE
            WHEN latest_previous_end IS NULL
              OR segment_start > latest_previous_end
            THEN 1
            ELSE 0
        END AS new_island

    FROM ordered_stops
),

island_ids AS (

    SELECT
        *,
        SUM(new_island) OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY segment_start, segment_end
            ROWS UNBOUNDED PRECEDING
        ) AS island_id

    FROM island_starts
),

coverage_islands AS (

    SELECT
        cuebiq_id,
        event_date,
        island_id,
        MIN(segment_start) AS island_start,
        MAX(segment_end) AS island_end

    FROM island_ids
    GROUP BY cuebiq_id, event_date, island_id
),

coverage_summary AS (

    SELECT
        cuebiq_id,
        event_date,
        SUM(DATEDIFF(SECOND, island_start, island_end)) / 60.0
            AS unique_covered_stop_minutes

    FROM coverage_islands
    GROUP BY cuebiq_id, event_date
),

daily_summary AS (

    SELECT
        cuebiq_id,
        home_geo10,
        event_date,
        COUNT(*) AS n_stop_rows,
        SUM(dwell_time_minutes_in_event_date) AS raw_total_stop_minutes,
        MIN(segment_start) AS first_stop,
        MAX(segment_end) AS last_stop,
        DATEDIFF(
            MINUTE,
            MIN(segment_start),
            MAX(segment_end)
        ) AS observation_span_minutes

    FROM DEDICATED.HOUPU.FL_ALLDAY_STOPS_UNIONED
    GROUP BY cuebiq_id, home_geo10, event_date
)

SELECT
    d.*,
    c.unique_covered_stop_minutes,
    COALESCE(f.n_overlapping_rows, 0) AS n_overlapping_rows,

    CASE
        WHEN COALESCE(f.n_overlapping_rows, 0) > $MAX_OVERLAPPING_ROWS
        THEN 1
        ELSE 0
    END AS conflict_day,

    CASE
        WHEN c.unique_covered_stop_minutes >= $MIN_COVERED_STOP_MINUTES
         AND d.observation_span_minutes >= $MIN_OBSERVATION_SPAN_MINUTES
        THEN 1
        ELSE 0
    END AS observation_eligible,

    CASE
        WHEN c.unique_covered_stop_minutes >= $MIN_COVERED_STOP_MINUTES
         AND d.observation_span_minutes >= $MIN_OBSERVATION_SPAN_MINUTES
         AND COALESCE(f.n_overlapping_rows, 0) <= $MAX_OVERLAPPING_ROWS
        THEN 1
        ELSE 0
    END AS eligible_day

FROM daily_summary AS d

LEFT JOIN coverage_summary AS c
    ON d.cuebiq_id = c.cuebiq_id
   AND d.event_date = c.event_date

LEFT JOIN conflict_days AS f
    ON d.cuebiq_id = f.cuebiq_id
   AND d.event_date = f.event_date;
