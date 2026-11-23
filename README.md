# Hurricane Ian Evacuation Detection

Snowflake SQL that identifies evacuees from Cuebiq mobility data (Cuebiq Snowflake platform) during Hurricane Ian (2022). It produces an individual-level table with departure phase, departure date, return date, home CBG, and destination CBG.

## Method in one line

**Target residents → cleaned stops → eligible user-days → analysis cohort → daily weighted activity center → kNN spatial unfamiliarity → departure (by phase) → return → destination CBG → individual table**

A post-baseline day is *unfamiliar* when its kNN score is higher than all of that user's leave-one-out baseline scores. A user is an *evacuee* when a run of at least 2 unfamiliar days starts between 9/23 and 10/7. The run's start date defines the departure phase. Phase-1 (pre-landfall) runs must still be ongoing on landfall day, 9/28.

See [`METHOD.md`](METHOD.md) for the formal definition.

## Repository layout

```text
PARAMETERS.sql        # all tunable parameters (Snowflake session variables)
PARAMETER_LOG.md      # parameter sets used for main results / sensitivity checks
METHOD.md             # short method definition
run_all.sql           # PARAMETERS.sql + every sql/*/*.sql, concatenated in run order
sql/
├── 00_residents_detection/ README.md → FL_RECURRING_RESIDENTS_FULL
│   └── residents_detection.sql
├── 01_preprocessing/   README.md  → FL_RESIDENT ... FL_ALLDAY_USER_DAY
│   ├── 00_build_resident.sql
│   ├── 01_extract_stops.sql
│   ├── 02_deduplicate_stops.sql
│   ├── 03_overlapping_time_union.sql
│   └── 04_user_day_quality.sql
├── 02_cohort/          README.md  → FL_ALLDAY_COHORT
│   └── 01_analysis_cohort.sql
├── 03_daily_center/    README.md  → FL_ALLDAY_DAILY_CENTER
│   └── 01_daily_weighted_center.sql
├── 04_unfamiliarity/   README.md  → FL_EVAC_KNN_RARITY
│   ├── 01_evac_knn.sql
│   ├── 02_baseline_loo_knn.sql
│   └── 03_unfamiliar_days.sql
└── 05_persistence/     README.md  → FL_EVAC_INDIVIDUAL (final output)
    ├── 01_daily_states.sql
    ├── 02_departure.sql
    ├── 03_return.sql
    ├── 04_destination_cbg.sql
    └── 05_individual_table.sql
```

Each `sql/` subfolder has its own `README.md` describing how its scripts run, their inputs/outputs, and the parameters they use.

## How to run

All scripts read the Cuebiq share `CUEBIQ_DATA.PAAS_CDA_PE_V3` and write tables to `DEDICATED.HOUPU`.

**Option A — step by step.** In one Snowflake worksheet/session:

1. Run `sql/00_residents_detection/residents_detection.sql` once to build `FL_RECURRING_RESIDENTS_FULL`. It does not use `PARAMETERS.sql`; its baseline dates are hard-coded.
2. Run `PARAMETERS.sql`, which sets session variables. Every later script reads them as `$NAME`.
3. Run the remaining scripts in `sql/`, in folder order and then filename order (`01_preprocessing/00_...` → `05_persistence/05_...`).

**Option B — one shot.** Run `run_all.sql`. It contains `PARAMETERS.sql` followed by every script in `sql/` in the same order, including `00_residents_detection`.

`run_all.sql` is a generated copy. After editing `PARAMETERS.sql` or any script, regenerate it from the repo root:

```bash
{ cat PARAMETERS.sql; for f in sql/*/*.sql; do printf '\n\n-- ===== %s =====\n' "$f"; cat "$f"; done; } > run_all.sql
```

Session variables do not persist across sessions, so re-run `PARAMETERS.sql` whenever you open a new session.

## Parameters

**Start here:** [`PARAMETERS.sql`](PARAMETERS.sql) is the single place to change the specification. Current values (`main_v6`):

| Group | Parameter | Value | Used in |
|---|---|---|---|
| Source | `PROVIDER_1`, `PROVIDER_2` | `SIERRA`, `LIMA` | 01_preprocessing |
| Source | `EXCLUDE_UPLEVELLED` | 0 (keep) | 01_preprocessing |
| Windows | `BASELINE_START`..`BASELINE_END` | 2022-09-02..09-22 | all |
| Windows | `PHASE1_START` | 2022-09-23 (phase 1: pre-landfall) | 02–05 |
| Windows | `PHASE2_START` | 2022-09-28 (phase 2: landfall) | 05 |
| Windows | `PHASE3_START` | 2022-10-01 (phase 3: post-landfall) | 05 |
| Windows | `DEPARTURE_END` | 2022-10-07 (last possible departure day) | 02, 05 |
| Windows | `OBS_END` | 2022-10-23 (end of observation) | 01, 02, 04, 05 |
| Eligible day | `MIN_COVERED_STOP_MINUTES` | 120 | 01_preprocessing |
| Eligible day | `MIN_OBSERVATION_SPAN_MINUTES` | 240 | 01_preprocessing |
| Eligible day | `MAX_OVERLAPPING_ROWS` | 0 | 01_preprocessing |
| Cohort | `MIN_BASELINE_ELIGIBLE_DAYS` | 14 | 02_cohort |
| Cohort | `MIN_DEPARTURE_WINDOW_ELIGIBLE_DAYS` | 3 | 02_cohort |
| Unfamiliarity | `K_NEIGHBORS` | 3 | 04_unfamiliarity |
| Departure/return | `MIN_CONSECUTIVE_UNFAMILIAR_DAYS` | 2 | 05_persistence |
| Departure/return | `MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` | 2 | 05_persistence |
| Departure/return | `MAX_GAP_DAYS_TO_BRIDGE` | 2 | 05_persistence |
| Destination | `NIGHT_START_HOUR`, `NIGHT_END_HOUR` | 21, 7 | 05_persistence |

Record every reported or sensitivity specification in [`PARAMETER_LOG.md`](PARAMETER_LOG.md).

## Key design notes

**Study population.** `00_residents_detection/residents_detection.sql` builds `FL_RECURRING_RESIDENTS_FULL` from Cuebiq's `DEVICE_RECURRING_AREA`. `01_preprocessing/00_build_resident.sql` then builds `FL_RESIDENT` from it with `IS_RESID_1_5 = 1`: home detected in a target CBG on at least 5 of the 21 baseline days.

Target CBGs are those in `DEDICATED.HOUPU.HURRICANE_IAN_MANDATORY_CBG_CROSS`, the block groups under Ian's *mandatory* evacuation order. This is narrower than all of Florida, and narrower than the counties those CBGs sit in. See [`sql/00_residents_detection/README.md`](sql/00_residents_detection/README.md).

**Overlapping stops.** `03_overlapping_time_union.sql` unions same-location fragments and trims cross-location conflicts by positional accuracy. All downstream stop-level steps read `FL_ALLDAY_STOPS_UNIONED`, including the destination night-minute totals.

**Departure phases.** Each user has at most one departure: the earliest qualifying unfamiliar streak.

- A streak may cross phase boundaries. Its *start* date sets `departure_phase`.
- Up to `MAX_GAP_DAYS_TO_BRIDGE` consecutive missing days are bridged; a confirmed familiar day always breaks a streak.
- Only phase-1 streaks must still be ongoing on landfall day (9/28). This excludes ordinary trips that ended before the storm.

**Return.** `return_date` is the first run of at least `MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` familiar days after the departure streak ends, searched through `OBS_END`. The same rule applies to every phase. Users with no such run are right-censored (`returned_by_end = 0`).

**Home and destination.**

- `home_cbg` is `HOME_GEO10` from residents detection.
- `destination_cbg` is the block group with the most 21:00–07:00 stop minutes between departure and return. Cuebiq's block-group ID is converted to a 12-digit GEO10.
- Distances and CBG-level aggregation are computed outside Snowflake from `FL_EVAC_INDIVIDUAL`.

## Data

No data is stored in this repository. All inputs are Cuebiq tables accessed under the Cuebiq data-use agreement on Snowflake.
