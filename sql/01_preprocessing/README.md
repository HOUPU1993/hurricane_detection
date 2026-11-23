# 01_preprocessing

Builds the study population, extracts its Cuebiq stops, cleans them into a non-overlapping timeline, and flags which user-days have enough data to be analyzed.

## Run order

Run `../../PARAMETERS.sql` first in the same Snowflake session, then:

| # | Script | Reads | Writes |
|---|---|---|---|
| 0 | `00_build_resident.sql` | `DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_FULL` | `FL_RESIDENT` |
| 1 | `01_extract_stops.sql` | `CUEBIQ_DATA.PAAS_CDA_PE_V3.STOP_BY_EVENT_DATE_UPLEVELLED`, `FL_RESIDENT` | `FL_ALLDAY_STOPS` |
| 2 | `02_deduplicate_stops.sql` | `FL_ALLDAY_STOPS` | `FL_ALLDAY_STOPS_DEDUP` |
| 3 | `03_overlapping_time_union.sql` | `FL_ALLDAY_STOPS_DEDUP` | `FL_ALLDAY_STOPS_UNIONED` |
| 4 | `04_user_day_quality.sql` | `FL_ALLDAY_STOPS_UNIONED` | `FL_ALLDAY_USER_DAY` |

All output tables are `TRANSIENT` in `DEDICATED.HOUPU`.

## What each script does

**`00_build_resident.sql`** — Keeps devices with `IS_RESID_1_5 = 1` in `FL_RECURRING_RESIDENTS_FULL`: home detected (via Cuebiq's `DEVICE_RECURRING_AREA`) in a target CBG on at least 5 of the 21 baseline days. Target CBGs are those in `HURRICANE_IAN_MANDATORY_CBG_CROSS` (mandatory evacuation order). Carries `cuebiq_id`, `home_geo10`, `days_in_target_cbgs`, `days_at_home_cbg`, `home_consistency`. Uses no session parameters.

**`01_extract_stops.sql`** — Inner-joins Cuebiq stops to `FL_RESIDENT` and keeps stops that:

- have `event_date` between `BASELINE_START` and `RETURN_END`;
- come from `PROVIDER_1` or `PROVIDER_2`;
- are not `UPLEVELLED` when `EXCLUDE_UPLEVELLED = 1`;
- have `dwell_time_minutes_in_event_date > 0` and non-null `lat`/`lng`.

It adds an `is_uplevelled` flag and keeps accuracy/provenance fields for QC.

**`02_deduplicate_stops.sql`** — Converts each stop into a time interval: `segment_start` = `stop_zoned_datetime_in_event_date`, `segment_end` = `segment_start` + `dwell_time_minutes_in_event_date`. Rows whose start cannot be parsed are dropped. Exact duplicates on (`cuebiq_id`, `event_date`, `lat`, `lng`, `segment_start`, `segment_end`) are reduced to the row with the best `avg_accuracy_meters`.

**`03_overlapping_time_union.sql`** — Resolves overlapping intervals per user-day in two stages, without dropping any observed time wholesale:

1. *Same-location union.* Fragments in the same 8-character geohash cell (~19 m × 38 m) are merged with an interval-union ("island") algorithm. Descriptive fields come from the most accurate fragment in each merged group.
2. *Cross-location conflict resolution.* Every interval boundary cuts the day into micro-intervals. In each micro-interval only the location with the best `avg_accuracy_meters` is kept (ties broken by `geohash8`). Consecutive micro-intervals won by the same location are re-merged.

`dwell_time_minutes_in_event_date` is recomputed from the resolved interval. Uses no session parameters. Recommended checks:

- daily total dwell time per user-day should never exceed 1440 minutes;
- spot-check a few user-days that had overlap conflicts before this step.

**`04_user_day_quality.sql`** — One row per user-day with:

- `unique_covered_stop_minutes`: union of stop intervals, in minutes;
- `observation_span_minutes`: first stop start to last stop end;
- `n_overlapping_rows` and `conflict_day`: remaining overlaps, a safety net that should rarely fire after step 3;
- `eligible_day`: 1 when coverage ≥ `MIN_COVERED_STOP_MINUTES`, span ≥ `MIN_OBSERVATION_SPAN_MINUTES`, and overlaps ≤ `MAX_OVERLAPPING_ROWS`.

## Parameters used

| Parameter | Value | Script |
|---|---|---|
| `PROVIDER_1`, `PROVIDER_2` | `SIERRA`, `LIMA` | 01 |
| `EXCLUDE_UPLEVELLED` | 0 | 01 |
| `BASELINE_START`, `RETURN_END` | 20220902, 20221023 | 01 |
| `MIN_COVERED_STOP_MINUTES` | 120 | 04 |
| `MIN_OBSERVATION_SPAN_MINUTES` | 240 | 04 |
| `MAX_OVERLAPPING_ROWS` | 0 | 04 |

Hard-coded choices: resident flag `IS_RESID_1_5` (00) and geohash precision 8 (03).
