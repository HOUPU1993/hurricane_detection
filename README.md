# Hurricane Ian Evacuation Detection

Snowflake SQL that identifies candidate evacuees from Cuebiq mobility data (Cuebiq Snowflake platform) during Hurricane Ian (2022), and estimates each candidate's departure date, return date, home, destination, and evacuation distance.

## Method in one line

**Target residents → cleaned stops → eligible user-days → analysis cohort → daily weighted activity center → kNN spatial unfamiliarity → persistence → candidate evacuee → return date + home/destination distance**

An evacuation-period day is *unfamiliar* when its kNN score is higher than all of that user's leave-one-out baseline scores. A user is a *candidate evacuee* when their last run of unfamiliar days is long enough and is still ongoing at `PERSISTENCE_CHECK_END` (9/29, one day after Ian's 9/28 landfall), and their nighttime home is in Florida.

See [`METHOD.md`](METHOD.md) for the formal definition.

## Repository layout

```text
PARAMETERS.sql        # all tunable parameters (Snowflake session variables)
PARAMETER_LOG.md      # parameter sets used for main results / sensitivity checks
METHOD.md             # short method definition
run_all.sql           # PARAMETERS.sql + every sql/*/*.sql, concatenated in run order
sql/
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
└── 05_persistence/     README.md  → FL_EVAC_SUMMARY (final output)
    ├── 01_unfamiliar_streaks.sql
    ├── 02_home_location.sql
    ├── 03_candidates.sql
    ├── 04_return_detection.sql
    ├── 05_destination_location.sql
    └── 06_evacuation_distance.sql
```

Each `sql/` subfolder has its own `README.md` describing how its scripts run, their inputs/outputs, and the parameters they use.

## How to run

All scripts write `TRANSIENT` tables to `DEDICATED.HOUPU` and read the Cuebiq share `CUEBIQ_DATA.PAAS_CDA_PE_V3`.

**Option A — step by step.** In one Snowflake worksheet/session:

1. Run `PARAMETERS.sql` (sets session variables; every script reads them as `$NAME`).
2. Run the scripts in `sql/` in folder order, then filename order (`01_preprocessing/00_...` → `05_persistence/06_...`).

**Option B — one shot.** Run `run_all.sql`, which is `PARAMETERS.sql` followed by every script in the same order.

`run_all.sql` is a generated copy. After editing `PARAMETERS.sql` or any script, regenerate it from the repo root:

```bash
{ cat PARAMETERS.sql; for f in sql/*/*.sql; do printf '\n\n-- ===== %s =====\n' "$f"; cat "$f"; done; } > run_all.sql
```

Session variables do not persist across sessions, so `PARAMETERS.sql` must be re-run whenever you open a new session.

## Parameters

**Start here:** [`PARAMETERS.sql`](PARAMETERS.sql) — the single place to change the specification. Current values (`main_v5`):

| Group | Parameter | Value | Used in |
|---|---|---|---|
| Source | `PROVIDER_1`, `PROVIDER_2` | `SIERRA`, `LIMA` | 01_preprocessing |
| Source | `EXCLUDE_UPLEVELLED` | 0 (keep) | 01_preprocessing |
| Windows | `BASELINE_START`..`BASELINE_END` | 2022-09-02..09-22 | all |
| Windows | `EVAC_START`..`EVAC_END` | 2022-09-23..09-30 | 02–05 |
| Windows | `RETURN_START`..`RETURN_END` | 2022-10-01..10-23 | 02–05 |
| Eligible day | `MIN_COVERED_STOP_MINUTES` | 120 | 01_preprocessing |
| Eligible day | `MIN_OBSERVATION_SPAN_MINUTES` | 240 | 01_preprocessing |
| Eligible day | `MAX_OVERLAPPING_ROWS` | 0 | 01_preprocessing |
| Cohort | `MIN_BASELINE_ELIGIBLE_DAYS` | 14 | 02_cohort |
| Cohort | `MIN_EVAC_ELIGIBLE_DAYS` | 3 | 02_cohort |
| Unfamiliarity | `K_NEIGHBORS` | 3 | 04_unfamiliarity |
| Persistence | `MIN_CONSECUTIVE_UNFAMILIAR_DAYS` | 2 | 05_persistence |
| Persistence | `MAX_GAP_DAYS_TO_BRIDGE` | 2 | 05_persistence |
| Persistence | `PERSISTENCE_CHECK_END` | 2022-09-29 | 05_persistence |
| Persistence | `MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` | 2 | 05_persistence |
| Home/destination | `NIGHT_START_HOUR`, `NIGHT_END_HOUR` | 21, 7 | 05_persistence |
| Home/destination | `HOME_LOCATION_RADIUS_KM` | 3 | 05_persistence |
| Home/destination | `MIN_CONSECUTIVE_NIGHTS_AT_DESTINATION` | 2 | 05_persistence |
| Florida gate | `FL_HOME_LAT_MIN/MAX`, `FL_HOME_LNG_MIN/MAX` | 24/31, -88/-79 | 05_persistence |

Record every reported or sensitivity specification in [`PARAMETER_LOG.md`](PARAMETER_LOG.md) (`main_v1`..`main_v5`).

## Key design notes

**Study population.** `00_build_resident.sql` builds `FL_RESIDENT` from `DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_FULL` with `IS_RESID_1_5 = 1`: home detected (via Cuebiq's `DEVICE_RECURRING_AREA`) in a target CBG on at least 5 of the 21 baseline days. Target CBGs are those in `DEDICATED.HOUPU.HURRICANE_IAN_MANDATORY_CBG_CROSS` — block groups under Ian's *mandatory* evacuation order. This is narrower than all of Florida and narrower than the counties those CBGs sit in. A broader, county-wide population (`FL_RECURRING_RESIDENTS_FULL_COUNTYWIDE`, built from `COUNTY_CBG_LOOKUP`) exists but is deliberately not used.

**Overlapping stops.** `03_overlapping_time_union.sql` unions same-location fragments and trims cross-location conflicts by positional accuracy. All downstream stop-level steps read `FL_ALLDAY_STOPS_UNIONED`, not `FL_ALLDAY_STOPS_DEDUP`.

**`home_geo10`.** A home CBG ID carried through earlier stages only as a passthrough/QC field. The home location used for evacuation distance is computed independently from nighttime stops in `05_persistence/02_home_location.sql`.

**Candidate rule.** A candidate's *last* unfamiliar streak must be at least `MIN_CONSECUTIVE_UNFAMILIAR_DAYS` confirmed unfamiliar days and must reach `PERSISTENCE_CHECK_END` (9/29) with no confirmed familiar day in between. Up to `MAX_GAP_DAYS_TO_BRIDGE` consecutive missing/ineligible days are bridged; a confirmed familiar day always breaks a streak. A return home *after* 9/29 does not disqualify a candidate, since it cannot have been caused by a storm that had already passed. The streak's first day is the departure date.

**Florida home gate.** `FL_RESIDENT` comes from Cuebiq's recurring-area home, while `FL_HOME_LOCATION` is the pipeline's own nighttime-stop home. The two can disagree, so `03_candidates.sql` also requires the nighttime home to fall inside a rough Florida bounding box (removed 150 of 15,953 `main_v4` candidates). The box is a rectangle, not the state boundary.

**Return, home, destination.** Return date = first run of at least `MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` confirmed familiar days in `RETURN_START..RETURN_END` (same gap tolerance, mirrored). Home = majority same-place cluster of baseline nights; destination = most recent same-place cluster of at least `MIN_CONSECUTIVE_NIGHTS_AT_DESTINATION` nights during the away period. `evacuation_distance_km` is the straight-line home-to-destination distance in `FL_EVAC_SUMMARY`.

## Data

No data is stored in this repository. All inputs are Cuebiq tables accessed under the Cuebiq data-use agreement on Snowflake.
