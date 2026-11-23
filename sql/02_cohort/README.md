# 02_cohort

Selects the users with enough eligible days to support detection.

## Run order

Run `../../PARAMETERS.sql` first in the same session, then `01_analysis_cohort.sql`. It requires `FL_RESIDENT` and `FL_ALLDAY_USER_DAY` from `01_preprocessing`.

| Script | Reads | Writes |
|---|---|---|
| `01_analysis_cohort.sql` | `FL_RESIDENT`, `FL_ALLDAY_USER_DAY` | `FL_ALLDAY_COHORT_COUNTS`, `FL_ALLDAY_COHORT` |

## What it does

1. **`FL_ALLDAY_COHORT_COUNTS`** — one row per `FL_RESIDENT` device. It uses a LEFT JOIN, so residents with no stops get zero counts. It counts:
   - `n_baseline_eligible_days`: eligible days in `BASELINE_START..BASELINE_END`;
   - `n_departure_window_eligible_days`: eligible days in `PHASE1_START..DEPARTURE_END` (9/23–10/7);
   - `n_post_window_eligible_days`: eligible days after `DEPARTURE_END` through `OBS_END` (reported only, not used as a filter);
   - `n_conflict_days`: days with `conflict_day = 1`.
2. **`FL_ALLDAY_COHORT`** — the rows of the count table that pass both thresholds below. All downstream steps use this cohort.

## Parameters used

| Parameter | Value | Role |
|---|---|---|
| `MIN_BASELINE_ELIGIBLE_DAYS` | 14 | of 21 baseline days |
| `MIN_DEPARTURE_WINDOW_ELIGIBLE_DAYS` | 3 | of 15 departure-window days (9/23–10/7) |
| `BASELINE_*`, `PHASE1_START`, `DEPARTURE_END`, `OBS_END` | see `PARAMETERS.sql` | counting windows |

`FL_ALLDAY_COHORT_COUNTS` is useful for reporting sample attrition (residents → cohort).
