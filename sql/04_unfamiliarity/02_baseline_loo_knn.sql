-- Run ../../PARAMETERS.sql first in the same Snowflake session.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_BASELINE_LOO_KNN
AS

WITH baseline AS (

    SELECT
        cuebiq_id,
        event_date,
        center_lat,
        center_lng,
        center_geog

    FROM DEDICATED.HOUPU.FL_ALLDAY_DAILY_CENTER
    WHERE event_date BETWEEN $BASELINE_START AND $BASELINE_END
),

pairwise AS (

    SELECT
        a.cuebiq_id,
        a.event_date,
        a.center_lat,
        a.center_lng,
        b.event_date AS comparison_baseline_date,
        ST_DISTANCE(a.center_geog, b.center_geog) / 1000.0
            AS spatial_distance_km

    FROM baseline AS a

    INNER JOIN baseline AS b
        ON a.cuebiq_id = b.cuebiq_id
       AND a.event_date <> b.event_date
),

ranked AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY cuebiq_id, event_date
            ORDER BY spatial_distance_km, comparison_baseline_date
        ) AS neighbor_rank

    FROM pairwise
)

SELECT
    cuebiq_id,
    event_date,
    MAX(center_lat) AS center_lat,
    MAX(center_lng) AS center_lng,
    AVG(spatial_distance_km) AS loo_knn_score_km,
    MIN(spatial_distance_km) AS nearest_baseline_day_km,
    MAX(spatial_distance_km) AS kth_nearest_baseline_day_km

FROM ranked
WHERE neighbor_rank <= $K_NEIGHBORS
GROUP BY cuebiq_id, event_date
HAVING COUNT(*) = $K_NEIGHBORS;
