-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Table name is kept as FL_EVAC_KNN for backward compatibility (03_unfamiliar_days.sql
-- joins to it by name), but as of this version it covers every day
-- from EVAC_START through RETURN_END, not just the evacuation window. EVAC_END and
-- RETURN_START are back-to-back (2022-09-30 -> 2022-10-01), so this is one
-- contiguous range. The extra RETURN-window rows let 03_unfamiliar_days.sql produce
-- an unfamiliar_day flag for every day after departure too, which
-- 05_persistence/04_return_detection.sql uses to detect when a candidate returned
-- home (the same personal baseline is used as the comparison set throughout, since
-- "baseline" below is unchanged).

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_KNN
AS

WITH baseline AS (

    SELECT
        cuebiq_id,
        event_date,
        center_geog

    FROM DEDICATED.HOUPU.FL_ALLDAY_DAILY_CENTER
    WHERE event_date BETWEEN $BASELINE_START AND $BASELINE_END
),

target_days AS (

    SELECT
        cuebiq_id,
        event_date,
        center_lat,
        center_lng,
        center_geog

    FROM DEDICATED.HOUPU.FL_ALLDAY_DAILY_CENTER
    WHERE event_date BETWEEN $EVAC_START AND $RETURN_END
),

pairwise AS (

    SELECT
        e.cuebiq_id,
        e.event_date,
        e.center_lat,
        e.center_lng,
        b.event_date AS baseline_date,
        ST_DISTANCE(e.center_geog, b.center_geog) / 1000.0
            AS spatial_distance_km

    FROM target_days AS e

    INNER JOIN baseline AS b
        ON e.cuebiq_id = b.cuebiq_id
),

ranked AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY spatial_distance_km, baseline_date
        ) AS neighbor_rank

    FROM pairwise
)

SELECT
    cuebiq_id,
    event_date,
    MAX(center_lat) AS center_lat,
    MAX(center_lng) AS center_lng,
    AVG(spatial_distance_km) AS evac_knn_score_km,
    MIN(spatial_distance_km) AS nearest_baseline_day_km,
    MAX(spatial_distance_km) AS kth_nearest_baseline_day_km

FROM ranked
WHERE neighbor_rank <= $K_NEIGHBORS
GROUP BY cuebiq_id, event_date
HAVING COUNT(*) = $K_NEIGHBORS;
