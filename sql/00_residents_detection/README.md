# 00_residents_detection

Identifies the study population: devices whose Cuebiq-detected home falls in a CBG under Hurricane Ian's **mandatory** evacuation order during the 21-day baseline (2022-09-02 .. 2022-09-22).

## Run order

`residents_detection.sql` does **not** read `PARAMETERS.sql`. The baseline dates and the 21-day length are hard-coded, so keep them in sync with `BASELINE_START`/`BASELINE_END` by hand. Run it once, before `01_preprocessing/00_build_resident.sql`.

| Step | Reads | Writes |
|---|---|---|
| 0 | `DEDICATED.HOUPU.HURRICANE_IAN_MANDATORY_CBG_CROSS` | `CBG_CUEBIQ_LOOKUP` (intermediate) |
| 1 | `CUEBIQ_DATA.PAAS_CDA_PE_V3.DEVICE_RECURRING_AREA`, `CBG_CUEBIQ_LOOKUP` | `IAN_RECURRING_HOME_DAILY` (intermediate) |
| 2 | `IAN_RECURRING_HOME_DAILY` | `FL_RECURRING_RESIDENTS_SUMMARY` (intermediate) |
| 3 | `IAN_RECURRING_HOME_DAILY`, `FL_RECURRING_RESIDENTS_SUMMARY` | **`FL_RECURRING_RESIDENTS_FULL`** |
| cleanup | — | drops the three intermediate tables |

All tables are permanent tables in `DEDICATED.HOUPU`, unlike the downstream steps, which write `TRANSIENT` tables.

## What each step does

**Step 0 — CBG lookup.** Converts each 12-digit `GEO10` (state 2 + county 3 + tract 6 + block group 1) into Cuebiq's block-group ID format, `US.FL.<county>.<tract>.<bg>`.

**Step 1 — daily home.** From `DEVICE_RECURRING_AREA`, keeps rows that:

- have `TAG_TYPE_CODE = 'HOME'` and `COUNTRY_CODE = 'US'`;
- have a snapshot date in the baseline window;
- have `CONFIDENCE_LEVEL > 0.5`;
- fall in a target CBG.

If a device has several such rows on one day, it keeps the highest-confidence row (ties go to the lowest `GEO10`). Output: one home CBG per device-day.

**Step 2 — per-device summary.**

| Column | Definition |
|---|---|
| `DAYS_IN_TARGET_CBGS` | days with a home in *any* target CBG |
| `HOME_GEO10` | target CBG with the most days (ties → lowest `GEO10`) |
| `DAYS_AT_HOME_CBG` | days at `HOME_GEO10` |
| `HOME_CONSISTENCY` | `DAYS_AT_HOME_CBG / DAYS_IN_TARGET_CBGS` (2 decimals) |
| `IS_RESID_a_b` | 1 if `DAYS_IN_TARGET_CBGS >= CEIL(21 * a/b)` |

The `IS_RESID` tiers translate to minimum day counts as follows:

| Flag | `IS_RESID_1_5` | `IS_RESID_1_4` | `IS_RESID_1_3` | `IS_RESID_1_2` | `IS_RESID_2_3` |
|---|---|---|---|---|---|
| Min. days of 21 | 5 | 6 | 7 | 11 | 14 |

The main pipeline uses **`IS_RESID_1_5`**.

**Step 3 — final table.** Pivots the daily home `GEO10` into 21 date columns (`"2022-09-02"` .. `"2022-09-22"`; NULL means no qualifying home that day) and attaches the Step 2 summary.

## Key parameters (hard-coded)

| Item | Value |
|---|---|
| Target CBG list | `HURRICANE_IAN_MANDATORY_CBG_CROSS` |
| Baseline window | 20220902 .. 20220922 (21 days) |
| Tag type | `HOME` |
| Confidence floor | `CONFIDENCE_LEVEL > 0.5` |
| Residency rule used downstream | `IS_RESID_1_5` (≥ 5 of 21 days) |

## Notes

- **Join order.** Step 1 joins to the target CBGs *before* the daily ranking. On a day when a device's top-confidence home is outside the target area, a lower-confidence target-CBG home (> 0.5) still counts. This is one way a device can pass the residency rule while it actually lives elsewhere. The current pipeline (`main_v6`) has no downstream filter for such devices; see `05_persistence/README.md` → Known limitations.
- **Providers.** Residency is computed from all providers, while stop extraction (`01_preprocessing/01_extract_stops.sql`) keeps only `PROVIDER_1`/`PROVIDER_2`. Residents with no stops from those providers drop out at the cohort step.
- **QC queries.** The two commented-out queries at the top of the script check for devices with more than one provider, and for device-days with more than one HOME block group.
