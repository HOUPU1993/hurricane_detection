# 05_persistence

Turns daily unfamiliarity flags into candidate evacuees, then adds departure date, return date, home, destination, and evacuation distance. The final output is `FL_EVAC_SUMMARY`.

## Run order

Run `../../PARAMETERS.sql` first in the same session, then run the scripts in filename order. `02_home_location.sql` must run before `03_candidates.sql`, which joins to it.

| # | Script | Reads | Writes |
|---|---|---|---|
| 1 | `01_unfamiliar_streaks.sql` | `FL_ALLDAY_COHORT`, `FL_EVAC_KNN_RARITY` | `FL_EVAC_FLAG_STREAKS` |
| 2 | `02_home_location.sql` | `FL_ALLDAY_STOPS_UNIONED` | `FL_HOME_LOCATION` |
| 3 | `03_candidates.sql` | `FL_EVAC_FLAG_STREAKS`, `FL_HOME_LOCATION` | `FL_EVAC_CANDIDATES` |
| 4 | `04_return_detection.sql` | `FL_EVAC_CANDIDATES`, `FL_EVAC_KNN_RARITY` | `FL_EVAC_RETURN_DATES` |
| 5 | `05_destination_location.sql` | `FL_EVAC_CANDIDATES`, `FL_EVAC_RETURN_DATES`, `FL_ALLDAY_STOPS_UNIONED` | `FL_EVAC_DESTINATION` |
| 6 | `06_evacuation_distance.sql` | `FL_EVAC_CANDIDATES`, `FL_EVAC_RETURN_DATES`, `FL_HOME_LOCATION`, `FL_EVAC_DESTINATION` | `FL_EVAC_SUMMARY` |

`01` and `04` set helper session variables (`N_EVAC_CALENDAR_DAYS`, `N_RETURN_CALENDAR_DAYS`), because `GENERATOR(ROWCOUNT => ...)` needs a constant.

## Three-state day model

Scripts 01 and 04 build a full calendar per user and classify every day as:

| State | Condition | Departure side (01) | Return side (04) |
|---|---|---|---|
| 1 unfamiliar | `unfamiliar_day = 1` | counted in streak | hard break |
| 2 familiar | `unfamiliar_day = 0` | hard break | counted in streak |
| 3 missing | no row in `FL_EVAC_KNN_RARITY` | bridged if ≤ `MAX_GAP_DAYS_TO_BRIDGE` consecutive days | same |

`streak_length` counts confirmed days only. `streak_calendar_span_days` also counts bridged missing days.

## What each script does

**`01_unfamiliar_streaks.sql`** — Builds unfamiliar streaks in `EVAC_START..EVAC_END`. A streak gets `reaches_window_end = 1` when two conditions hold:

- its last unfamiliar day is within `MAX_GAP_DAYS_TO_BRIDGE` days of `PERSISTENCE_CHECK_END` (or later);
- no confirmed familiar day falls between the streak end and `PERSISTENCE_CHECK_END`.

**`02_home_location.sql`** — Estimates home for every resident with baseline nighttime stops, not only candidates:

1. Nighttime stops are those whose `segment_start` hour is ≥ `NIGHT_START_HOUR` or < `NIGHT_END_HOUR`. Early-morning stops are assigned to the previous evening's night.
2. One weighted center is computed per night.
3. The night with the most other nights within `HOME_LOCATION_RADIUS_KM` is the anchor (ties go to the earliest night).
4. Home nights are the anchor plus all nights within the radius of it.
5. Home is the weighted center of the raw stops from those nights.

Output: `n_home_nights`, `home_lat`, `home_lng`, `home_geog`.

**`03_candidates.sql`** — A candidate needs both:

- a streak with `reaches_window_end = 1` and `streak_length ≥ MIN_CONSECUTIVE_UNFAMILIAR_DAYS`;
- a home in `FL_HOME_LOCATION` inside the Florida box (`FL_HOME_LAT_MIN..MAX`, `FL_HOME_LNG_MIN..MAX`). Users without a home row are excluded.

At most one streak per user can qualify. `candidate_start_date` is the departure date.

**`04_return_detection.sql`** — For each candidate, finds familiar streaks in `RETURN_START..RETURN_END` with the mirrored state model. The earliest streak with `streak_length ≥ MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` gives `return_date`. Candidates with no qualifying streak have no row, meaning return was not observed by `RETURN_END`.

**`05_destination_location.sql`** — Searches nighttime stops from `candidate_start_date` through the day before `return_date`, or through `RETURN_END` if no return was found:

1. A night qualifies when it plus the other nights within `HOME_LOCATION_RADIUS_KM` number at least `MIN_CONSECUTIVE_NIGHTS_AT_DESTINATION`. These nights do not have to be consecutive; the match is by distance only.
2. The most recent qualifying night is the anchor.
3. The destination is the weighted center of the anchor plus all nights within the radius of it.

Output: `n_destination_nights`, `destination_arrival_night`, `destination_last_confirmed_night`, `destination_lat`, `destination_lng`.

**`06_evacuation_distance.sql`** — One row per candidate combining departure, return, home, and destination. `evacuation_distance_km` = `ST_DISTANCE(home, destination)` / 1000, or NULL when no destination was found. Return fields are NULL when no return was observed.

## Parameters used

| Parameter | Value | Script |
|---|---|---|
| `EVAC_START`, `EVAC_END` | 20220923, 20220930 | 01 |
| `PERSISTENCE_CHECK_END` | 20220929 | 01 |
| `MAX_GAP_DAYS_TO_BRIDGE` | 2 | 01, 04 |
| `MIN_CONSECUTIVE_UNFAMILIAR_DAYS` | 2 | 03 |
| `FL_HOME_LAT_MIN/MAX`, `FL_HOME_LNG_MIN/MAX` | 24/31, -88/-79 | 03 |
| `RETURN_START`, `RETURN_END` | 20221001, 20221023 | 04, 05 |
| `MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` | 2 | 04 |
| `BASELINE_START`, `BASELINE_END` | 20220902, 20220922 | 02 |
| `NIGHT_START_HOUR`, `NIGHT_END_HOUR` | 21, 7 | 02, 05 |
| `HOME_LOCATION_RADIUS_KM` | 3 | 02, 05 |
| `MIN_CONSECUTIVE_NIGHTS_AT_DESTINATION` | 2 | 05 |

See `../../PARAMETER_LOG.md` for why `PERSISTENCE_CHECK_END`, the streak thresholds, and the Florida gate were set this way.
