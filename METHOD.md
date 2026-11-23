# Method

The current evacuation-detection pipeline (`main_v5`) is:

**eligible user-days → daily weighted activity center → kNN spatial unfamiliarity → persistence → candidate evacuee → return date + home/destination distance**

* **Population.** Devices whose Cuebiq recurring-area home is in a CBG under Hurricane Ian's mandatory evacuation order on at least 5 of the 21 baseline days (`FL_RESIDENT`).

* **Eligible user-day.** After deduplication and overlap resolution, a day is eligible when its non-overlapping stop coverage is at least `MIN_COVERED_STOP_MINUTES` and the span from first to last stop is at least `MIN_OBSERVATION_SPAN_MINUTES`. Users enter the cohort with at least `MIN_BASELINE_ELIGIBLE_DAYS` baseline and `MIN_EVAC_ELIGIBLE_DAYS` evacuation-period eligible days.

* **Daily activity center.** For each eligible user-day, all stop locations are combined into a dwell-time-weighted spherical activity center.

* **Unfamiliarity score.** For a post-baseline day $t$ (evacuation and return windows), its spatial unfamiliarity score $S_t$ is the mean distance to the user's $k$ nearest eligible baseline daily centers.

* **Personal threshold.** For every eligible baseline day $b$, a leave-one-out score $S_b^{LOO}$ is calculated in the same way after excluding that day itself. A day is unfamiliar when

$$
S_t > \max_b S_b^{LOO}.
$$

* **Candidate evacuee.** A user becomes a candidate when their *last* run of unfamiliar days in the evacuation window (a) contains at least `MIN_CONSECUTIVE_UNFAMILIAR_DAYS` confirmed unfamiliar days and (b) reaches `PERSISTENCE_CHECK_END` (9/29, one day after the 9/28 landfall) with no confirmed familiar day in between. Up to `MAX_GAP_DAYS_TO_BRIDGE` consecutive missing/ineligible days do not break a run; a day observed as familiar always does. A return after `PERSISTENCE_CHECK_END` does not disqualify the candidate. The run's first day is the departure date.

* **Florida home gate.** The candidate's nighttime home (below) must fall inside a rough Florida bounding box. This removes devices whose recurring-area home passed the population filter but whose nighttime home is outside Florida.

* **Return date.** The same persistence logic, mirrored (a run of at least `MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` confirmed-familiar days, broken by any confirmed unfamiliar day), is applied in the return window; the first such run's first day is the return date.

* **Home, destination, distance.** Home and destination are each estimated from nighttime stops only (`NIGHT_START_HOUR`..`NIGHT_END_HOUR`), using the same weighted spherical center, restricted to a same-place cluster of nights within `HOME_LOCATION_RADIUS_KM`. Home uses the largest cluster of baseline nights; destination uses the most recent cluster of at least `MIN_CONSECUTIVE_NIGHTS_AT_DESTINATION` nights during the away period. The evacuation distance is the straight-line distance between the two.
