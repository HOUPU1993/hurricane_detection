-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Scores every day from PHASE1_START through OBS_END (9/23-10/23) against the
-- user's baseline daily centers. Covering the whole post-baseline range lets
-- 05_persistence build departure streaks (which may run past DEPARTURE_END)
-- and detect returns up to OBS_END. The table name FL_EVAC_KNN is kept for
-- continuity; 03_unfamiliar_days.sql joins to it by name.

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
    WHERE event_date BETWEEN $PHASE1_START AND $OBS_END
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
