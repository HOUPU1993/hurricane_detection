# Method

The current evacuation-detection pipeline (`main_v6`) is:

**eligible user-days → daily weighted activity center → kNN spatial unfamiliarity → departure by phase → return → destination CBG → individual table**

* **Population.** Devices whose Cuebiq recurring-area home is in a CBG under Hurricane Ian's mandatory evacuation order on at least 5 of the 21 baseline days (9/2–9/22).

* **Eligible user-day.** After deduplication and overlap resolution, a day is eligible when two conditions hold:
  - its non-overlapping stop coverage is at least `MIN_COVERED_STOP_MINUTES`;
  - the span from first to last stop is at least `MIN_OBSERVATION_SPAN_MINUTES`.

  Users enter the cohort with at least `MIN_BASELINE_ELIGIBLE_DAYS` eligible baseline days and at least `MIN_DEPARTURE_WINDOW_ELIGIBLE_DAYS` eligible days in 9/23–10/7.

* **Daily activity center.** For each eligible user-day, all stop locations are combined into a dwell-time-weighted spherical activity center.

* **Unfamiliarity score.** For a post-baseline day $t$ (9/23–10/23), its spatial unfamiliarity score $S_t$ is the mean distance to the user's $k$ nearest eligible baseline daily centers.

* **Personal threshold.** For every eligible baseline day $b$, a leave-one-out score $S_b^{LOO}$ is calculated in the same way after excluding that day itself. A day is unfamiliar when

$$
S_t > \max_b S_b^{LOO}.
$$

* **Phases.** Phase 1 runs 9/23–9/27 (pre-landfall), phase 2 runs 9/28–9/30 (landfall), and phase 3 runs 10/1–10/7 (post-landfall).

* **Departure.** Runs of unfamiliar days are built over 9/23–10/23. A run may cross phase boundaries. A missing/ineligible day does not break a run if at most `MAX_GAP_DAYS_TO_BRIDGE` consecutive days are missing; a day observed as familiar always breaks it. A run qualifies as a departure when:
  - it starts between 9/23 and 10/7;
  - it contains at least `MIN_CONSECUTIVE_UNFAMILIAR_DAYS` confirmed unfamiliar days;
  - if it starts in phase 1, the user is still away on landfall day (9/28).

  The earliest qualifying run is the departure. Its first day is the departure date, and that day's phase is the departure phase. A user with a departure is an evacuee; other cohort users are non-evacuees.

* **Return.** The same run logic, mirrored, is applied after the departure run ends. A run of at least `MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN` familiar days, broken by any unfamiliar day, marks a return. The first such run's first day is the return date. Users with no return by 10/23 are right-censored.

* **Home and destination.** Home is the Cuebiq recurring-home CBG from residents detection. Destination is the block group with the most night-window (`NIGHT_START_HOUR`..`NIGHT_END_HOUR`) stop minutes between departure and return, computed from overlap-resolved stops.
