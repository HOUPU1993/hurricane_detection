# 05_persistence

Turns daily unfamiliarity flags into departure, return, and destination for each cohort user. The final individual-level table is `FL_EVAC_INDIVIDUAL`, with one row per resident.

## Run order

Run `../../PARAMETERS.sql` first in the same session, then run the scripts in filename order.

| # | Script | Reads | Writes |
|---|---|---|---|
| 1 | `01_daily_states.sql` | `FL_ALLDAY_COHORT`, `FL_EVAC_KNN_RARITY` | `FL_DAILY_STATE` |
| 2 | `02_departure.sql` | `FL_DAILY_STATE` | `FL_EVAC_DEPARTURE` |
| 3 | `03_return.sql` | `FL_DAILY_STATE`, `FL_EVAC_DEPARTURE` | `FL_EVAC_RETURN` |
| 4 | `04_destination_cbg.sql` | `FL_EVAC_DEPARTURE`, `FL_EVAC_RETURN`, `FL_ALLDAY_STOPS_UNIONED` | `FL_EVAC_DESTINATION_CBG` |
| 5 | `05_individual_table.sql` | `FL_RESIDENT`, `FL_ALLDAY_COHORT`, and tables 2–4 | **`FL_EVAC_INDIVIDUAL`** |

`01_daily_states.sql` also sets the helper session variable `N_STATE_DAYS`, because `GENERATOR(ROWCOUNT => ...)` needs a constant.

## Phases

| Phase | Dates | Meaning |
|---|---|---|
| 1 | `PHASE1_START`..`PHASE2_START`-1 (9/23–9/27) | pre-landfall |
| 2 | `PHASE2_START`..`PHASE3_START`-1 (9/28–9/30) | landfall (Ian landfall 9/28) |
| 3 | `PHASE3_START`..`DEPARTURE_END` (10/1–10/7) | post-landfall |
| 4 | after `DEPARTURE_END` to `OBS_END` (10/8–10/23) | return observation only |

## Day states (`01_daily_states.sql`)

Each cohort user gets every calendar day from 9/23 to 10/23. Each day is classified as:

| `day_state` | Condition |
|---|---|
| 1 unfamiliar | `unfamiliar_day = 1` |
| 2 familiar | `unfamiliar_day = 0` |
| 3 missing | no row in `FL_EVAC_KNN_RARITY` (day not eligible) |

## Departure rule (`02_departure.sql`)

1. Unfamiliar streaks are built over the full 9/23–10/23 range, so a streak can cross phase boundaries:
   - a familiar day always breaks a streak;
   - up to `MAX_GAP_DAYS_TO_BRIDGE` consecutive missing days are bridged;
   - `streak_length` counts confirmed unfamiliar days only.
2. A streak qualifies if:
   - its **start** falls between `PHASE1_START` and `DEPARTURE_END`;
   - `streak_length >= MIN_CONSECUTIVE_UNFAMILIAR_DAYS`;
   - **phase 1 only:** the person is still away on landfall day (`PHASE2_START`). That means the streak ends within `MAX_GAP_DAYS_TO_BRIDGE` days of 9/28 or later, and no familiar day falls between its end and 9/28. This excludes ordinary trips that ended before the storm.
3. The **earliest** qualifying streak is the departure:
   - `departure_date` = streak start;
   - `departure_phase` = the phase of that date.

A user whose phase-1 trip ended before landfall can still qualify through a later phase-2 or phase-3 streak.

## Return rule (`03_return.sql`)

The return rule is the same for all phases, mirrored from the departure rule. Familiar days build a streak, an unfamiliar day breaks it, and missing days are bridged in the same way.

- `return_date` is the start of the first familiar streak that begins after `departure_streak_end_date` and has at least `MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` days. The search runs through `OBS_END`.
- `days_away` = `return_date - departure_date`.
- Evacuees with no qualifying familiar streak have no row: they had not returned by `OBS_END`.

## Destination (`04_destination_cbg.sql`)

- **Away nights:** from `departure_date` to `return_date - 1`. If no return was detected, the last night is `OBS_END`.
- **Night window:** night *d* runs from `NIGHT_START_HOUR` on day *d* to `NIGHT_END_HOUR` on day *d+1*.
- **Clipping:** each stop interval from `FL_ALLDAY_STOPS_UNIONED` (overlaps already resolved) is clipped to the night window in minutes.
- **Choice of CBG:** minutes are summed by `block_group_id`. The block group with the most minutes is the destination (ties → lowest ID).
- **CBG format:** Cuebiq's `US.<ST>.<county>.<tract>.<bg>` is converted to a 12-digit GEO10 with a state-abbreviation → FIPS lookup. IDs that do not match this format get `destination_cbg = NULL`; the raw ID is kept.

QC fields:

- `destination_n_nights`: nights with any stop in that block group;
- `destination_night_share`: that block group's share of all away-night minutes.

## Final table `FL_EVAC_INDIVIDUAL`

| Column | Definition |
|---|---|
| `cuebiq_id` | device ID |
| `home_cbg` | `HOME_GEO10` from `00_residents_detection` |
| `in_cohort` | 1 if in `FL_ALLDAY_COHORT` |
| `evacuee` | NULL if not in cohort; 1 if a departure was detected; else 0 |
| `departure_phase` | 1 / 2 / 3 |
| `departure_date` | first day of the departure streak |
| `departure_streak_end_date`, `departure_streak_length` | departure streak details |
| `return_date` | first day of the return streak |
| `returned_by_end` | NULL for non-evacuees; 1 if returned by `OBS_END`, else 0 (right-censored) |
| `days_away` | `return_date - departure_date` |
| `destination_cbg`, `destination_block_group_id` | destination as GEO10 and as the raw Cuebiq ID |
| `destination_n_nights`, `destination_night_share` | destination QC |

Aggregation to CBG and any home-to-destination distance are done outside Snowflake.

## Parameters used

| Parameter | Value | Script |
|---|---|---|
| `PHASE1_START`, `PHASE2_START`, `PHASE3_START`, `DEPARTURE_END` | 20220923, 20220928, 20221001, 20221007 | 01, 02 |
| `OBS_END` | 20221023 | 01, 04 |
| `MIN_CONSECUTIVE_UNFAMILIAR_DAYS` | 2 | 02 |
| `MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` | 2 | 03 |
| `MAX_GAP_DAYS_TO_BRIDGE` | 2 | 02, 03 |
| `NIGHT_START_HOUR`, `NIGHT_END_HOUR` | 21, 7 | 04 |

## Known limitations

- **Daily resolution.** Departures on 9/28 are assigned to phase 2, even though some of them left before landfall later that day.
- **Departures before 9/23.** A user who left before 9/23 gets `departure_date` = 9/23.
- **Weekend in phase 3.** 10/1–10/2 is a weekend, so with a 2-day minimum some phase-3 departures may be ordinary weekend trips. Consider a sensitivity run with a 3-day minimum for phase 3.
- **No home-location gate.** `main_v5` excluded candidates whose nighttime home was outside Florida (~0.9% of candidates). `main_v6` has no such gate, so devices whose `HOME_GEO10` is in the target area while they actually live elsewhere can appear as evacuees. Their `destination_cbg` will often be out of state.

## QC queries

```sql
-- Departures and returns by phase
SELECT departure_phase, COUNT(*) AS n, AVG(returned_by_end) AS share_returned,
       MEDIAN(days_away) AS median_days_away
FROM DEDICATED.HOUPU.FL_EVAC_INDIVIDUAL
WHERE evacuee = 1
GROUP BY departure_phase ORDER BY departure_phase;

-- Destination CBG conversion failures and destination == home
SELECT COUNT_IF(destination_cbg IS NULL AND destination_block_group_id IS NOT NULL) AS n_unconverted,
       COUNT_IF(destination_block_group_id IS NULL) AS n_no_destination,
       COUNT_IF(destination_cbg = home_cbg) AS n_destination_is_home_cbg
FROM DEDICATED.HOUPU.FL_EVAC_INDIVIDUAL
WHERE evacuee = 1;
```
