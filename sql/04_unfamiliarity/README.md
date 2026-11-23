# 04_unfamiliarity

Scores how spatially unfamiliar each post-baseline day is relative to the user's own baseline, and flags unfamiliar days.

## Run order

Run `../../PARAMETERS.sql` first in the same session, then:

| # | Script | Reads | Writes |
|---|---|---|---|
| 1 | `01_evac_knn.sql` | `FL_ALLDAY_DAILY_CENTER` | `FL_EVAC_KNN` |
| 2 | `02_baseline_loo_knn.sql` | `FL_ALLDAY_DAILY_CENTER` | `FL_BASELINE_LOO_KNN` |
| 3 | `03_unfamiliar_days.sql` | `FL_EVAC_KNN`, `FL_BASELINE_LOO_KNN` | `FL_EVAC_KNN_RARITY` |

## What each script does

**`01_evac_knn.sql`** — For every target day from `EVAC_START` through `RETURN_END`:

1. Computes the distance (km, `ST_DISTANCE`) from that day's center to each of the user's baseline daily centers.
2. Keeps the `K_NEIGHBORS` nearest (ties broken by baseline date).
3. Outputs `evac_knn_score_km` (mean of the k distances), `nearest_baseline_day_km`, and `kth_nearest_baseline_day_km`.

Days with fewer than k baseline neighbors are dropped. The table name says "evac", but it also covers the return window, which `05_persistence/04_return_detection.sql` needs.

**`02_baseline_loo_knn.sql`** — The same kNN score for each baseline day, computed against the user's *other* baseline days (leave-one-out). Output: `loo_knn_score_km`.

**`03_unfamiliar_days.sql`** — Compares each target-day score with all of the user's LOO baseline scores and outputs:

- `baseline_score_min/median/max`, `n_baseline_scores`;
- `empirical_tail_fraction`: share of baseline scores ≥ the day's score;
- `score_to_baseline_median_ratio`;
- **`unfamiliar_day`** = 1 if `evac_knn_score_km > baseline_score_max`, else 0.

A day with no row here (not eligible, or not scored) is treated as *missing* in `05_persistence`, not as familiar.

## Parameters used

| Parameter | Value | Role |
|---|---|---|
| `K_NEIGHBORS` | 3 | neighbors in the kNN score |
| `BASELINE_START..BASELINE_END` | 20220902..20220922 | reference days |
| `EVAC_START..RETURN_END` | 20220923..20221023 | scored days |

The decision rule (score > personal LOO maximum) is hard-coded in `03_unfamiliar_days.sql`. The other summary columns are kept for alternative rules or sensitivity checks.
