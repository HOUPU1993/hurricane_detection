# 03_daily_center

Summarizes each eligible user-day as a single dwell-time-weighted activity center.

## Run order

Run `../../PARAMETERS.sql` first in the same session, then `01_daily_weighted_center.sql`.

| Script | Reads | Writes |
|---|---|---|
| `01_daily_weighted_center.sql` | `FL_ALLDAY_STOPS_UNIONED`, `FL_ALLDAY_USER_DAY`, `FL_ALLDAY_COHORT` | `FL_ALLDAY_DAILY_CENTER` |

## What it does

1. Keeps stops of cohort users on days with `eligible_day = 1`. This covers every date in the extracted range (baseline through `RETURN_END`).
2. Converts each stop's `lat`/`lng` to a 3-D unit vector on the sphere.
3. Averages the vectors with weight `dwell_time_minutes_in_event_date`, which comes from the de-conflicted table, so overlapping time is not double-counted.
4. Converts the mean vector back to `center_lat`/`center_lng` and builds `center_geog = ST_MAKEPOINT(lng, lat)`.

The spherical mean avoids distortions from averaging longitudes directly.

Output columns:

- `cuebiq_id`, `home_geo10`, `event_date`;
- `mean_x/y/z`;
- `total_weight_minutes`, `n_stop_rows`;
- `center_lat`, `center_lng`, `center_geog`.

## Parameters used

No parameters are referenced directly. Results depend on the eligible-day rule (`01_preprocessing`) and cohort rule (`02_cohort`).
