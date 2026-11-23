-- Run ../../PARAMETERS.sql first in the same Snowflake session.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_KNN_RARITY
AS

WITH comparisons AS (

    SELECT
        e.cuebiq_id,
        e.event_date,
        e.center_lat,
        e.center_lng,
        e.evac_knn_score_km,
        b.loo_knn_score_km

    FROM DEDICATED.HOUPU.FL_EVAC_KNN AS e

    INNER JOIN DEDICATED.HOUPU.FL_BASELINE_LOO_KNN AS b
        ON e.cuebiq_id = b.cuebiq_id
),

rank_summary AS (

    SELECT
        cuebiq_id,
        event_date,
        MAX(center_lat) AS center_lat,
        MAX(center_lng) AS center_lng,
        MAX(evac_knn_score_km) AS evac_knn_score_km,

        COUNT(*) AS n_baseline_scores,
        MIN(loo_knn_score_km) AS baseline_score_min,
        MEDIAN(loo_knn_score_km) AS baseline_score_median,
        MAX(loo_knn_score_km) AS baseline_score_max,

        COUNT_IF(loo_knn_score_km >= evac_knn_score_km)
            AS n_baseline_scores_ge

    FROM comparisons
    GROUP BY cuebiq_id, event_date
)

SELECT
    *,

    n_baseline_scores_ge::DOUBLE
        / NULLIF(n_baseline_scores, 0) AS empirical_tail_fraction,

    evac_knn_score_km
        / NULLIF(baseline_score_median, 0)
        AS score_to_baseline_median_ratio,

    CASE
        WHEN evac_knn_score_km > baseline_score_max THEN 1
        ELSE 0
    END AS unfamiliar_day

FROM rank_summary;
