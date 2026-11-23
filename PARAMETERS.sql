/*
===============================================================================
HURRICANE IAN EVACUATION DETECTION — PARAMETERS (main_v6)
===============================================================================
Edit this file when changing the main specification or running sensitivity tests.
Run this file first in the same Snowflake session before running the SQL scripts
(sql/00_residents_detection does not read it; see that folder's README).
===============================================================================
*/

-- -----------------------------------------------------------------------------
-- Source filters
-- -----------------------------------------------------------------------------
SET PROVIDER_1 = 'SIERRA';
SET PROVIDER_2 = 'LIMA';

-- 0 = keep UPLEVELLED stops; 1 = exclude them
SET EXCLUDE_UPLEVELLED = 0;

-- -----------------------------------------------------------------------------
-- Analysis windows
-- -----------------------------------------------------------------------------
-- Baseline: each user's normal mobility (reference for unfamiliarity).
SET BASELINE_START = 20220902;
SET BASELINE_END   = 20220922;

-- Departure phases. A departure is assigned to the phase in which its
-- unfamiliar streak STARTS; the streak itself may cross phase boundaries.
--   Phase 1 (pre-landfall):   PHASE1_START .. PHASE2_START - 1   (9/23-9/27)
--   Phase 2 (landfall):       PHASE2_START .. PHASE3_START - 1   (9/28-9/30)
--   Phase 3 (post-landfall):  PHASE3_START .. DEPARTURE_END      (10/1-10/7)
-- PHASE2_START is Ian's landfall day; phase-1 departures must still be away
-- on this day (see 05_persistence/02_departure.sql).
SET PHASE1_START  = 20220923;
SET PHASE2_START  = 20220928;
SET PHASE3_START  = 20221001;
SET DEPARTURE_END = 20221007;

-- End of observation: last day used for streaks, return detection and
-- destination search.
SET OBS_END = 20221023;

-- -----------------------------------------------------------------------------
-- Eligible user-day definition
-- -----------------------------------------------------------------------------
SET MIN_COVERED_STOP_MINUTES     = 120;
SET MIN_OBSERVATION_SPAN_MINUTES = 240;
SET MAX_OVERLAPPING_ROWS         = 0;

-- -----------------------------------------------------------------------------
-- Analysis cohort
-- -----------------------------------------------------------------------------
SET MIN_BASELINE_ELIGIBLE_DAYS         = 14;  -- within BASELINE_START..BASELINE_END
SET MIN_DEPARTURE_WINDOW_ELIGIBLE_DAYS = 3;   -- within PHASE1_START..DEPARTURE_END

-- -----------------------------------------------------------------------------
-- Spatial unfamiliarity
-- -----------------------------------------------------------------------------
SET K_NEIGHBORS = 3;

-- Rule (04_unfamiliarity/03_unfamiliar_days.sql):
-- day kNN score > maximum baseline leave-one-out kNN score

-- -----------------------------------------------------------------------------
-- Departure and return
-- -----------------------------------------------------------------------------
-- Minimum confirmed unfamiliar days in a departure streak (all phases).
SET MIN_CONSECUTIVE_UNFAMILIAR_DAYS = 2;

-- Minimum confirmed familiar days in a return streak.
SET MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN = 2;

-- Up to this many consecutive missing/ineligible days are bridged inside a
-- streak. A confirmed opposite-state day always breaks a streak.
SET MAX_GAP_DAYS_TO_BRIDGE = 2;

-- -----------------------------------------------------------------------------
-- Destination CBG
-- -----------------------------------------------------------------------------
-- Night window (wraps past midnight). Destination = the block group with the
-- most night-window stop minutes between departure and return.
SET NIGHT_START_HOUR = 21;
SET NIGHT_END_HOUR   = 7;
