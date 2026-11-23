/*
===============================================================================
HURRICANE IAN EVACUATION DETECTION — PARAMETERS
===============================================================================
Edit this file when changing the main specification or running sensitivity tests.
Run this file first in the same Snowflake session before running the SQL scripts.
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
SET BASELINE_START = 20220902;
SET BASELINE_END   = 20220922;

SET EVAC_START = 20220923;
SET EVAC_END   = 20220930;

SET RETURN_START = 20221001;
SET RETURN_END   = 20221023;

-- -----------------------------------------------------------------------------
-- Eligible user-day definition
-- -----------------------------------------------------------------------------
SET MIN_COVERED_STOP_MINUTES    = 120;
SET MIN_OBSERVATION_SPAN_MINUTES = 240;
SET MAX_OVERLAPPING_ROWS        = 0;

-- -----------------------------------------------------------------------------
-- Analysis cohort
-- -----------------------------------------------------------------------------
SET MIN_BASELINE_ELIGIBLE_DAYS = 14;
SET MIN_EVAC_ELIGIBLE_DAYS     = 3;

-- -----------------------------------------------------------------------------
-- Spatial unfamiliarity
-- -----------------------------------------------------------------------------
SET K_NEIGHBORS = 3;

-- Main rule (implemented in 04_unfamiliarity/03_unfamiliar_days.sql):
-- event-day kNN score > maximum baseline leave-one-out kNN score

-- -----------------------------------------------------------------------------
-- Persistence
-- -----------------------------------------------------------------------------
-- A candidate evacuee must have a run of consecutive unfamiliar days that
-- persists at least through PERSISTENCE_CHECK_END, not necessarily all the way
-- to EVAC_END (see 05_persistence/03_candidates.sql).
--
-- Set to 2 (was 3): Ian made landfall 9/28. A departure confirmed on two
-- consecutive days (e.g. 9/27-9/28, both weekdays, ruling out an ordinary
-- weekend trip) combined with no confirmed return before PERSISTENCE_CHECK_END
-- (9/29, one day after landfall) is treated as sufficient evidence of a real,
-- storm-related departure. See PARAMETER_LOG.md for the reasoning.
SET MIN_CONSECUTIVE_UNFAMILIAR_DAYS = 2;

-- When building that run (05_persistence/01_unfamiliar_streaks.sql), a day with
-- no eligible_day data (missing/insufficient coverage, NOT a confirmed "at home"
-- day) is skipped rather than treated as a break, as long as no more than this
-- many consecutive days are missing. A confirmed familiar day (eligible_day=1
-- AND unfamiliar_day=0) always breaks the run, regardless of this setting.
SET MAX_GAP_DAYS_TO_BRIDGE = 2;

-- The date used by 05_persistence/01_unfamiliar_streaks.sql to decide whether a
-- streak "reaches" far enough to count as unresolved (reaches_window_end): a
-- streak within MAX_GAP_DAYS_TO_BRIDGE of this date, with no confirmed return
-- home on or before it, counts -- even if the person is confirmed back home
-- later in the evac window (EVAC_END). Previously this check used EVAC_END
-- (9/30) itself, which incorrectly excluded people who evacuated through
-- landfall (9/28) and returned home as soon as it was safe (9/29-9/30) -- a
-- return could not have been caused by a storm that had already passed. Set to
-- one day after landfall to give a minimal buffer.
SET PERSISTENCE_CHECK_END = 20220929;

-- Symmetric threshold for return detection (05_persistence/04_return_detection.sql):
-- how many consecutive confirmed-familiar days (same gap-bridging rule, mirrored)
-- are required before a candidate is considered to have returned home.
-- Lowered to 2 alongside MIN_CONSECUTIVE_UNFAMILIAR_DAYS for symmetry.
SET MIN_CONSECUTIVE_FAMILIAR_DAYS_RETURN = 2;

-- -----------------------------------------------------------------------------
-- Home and destination location (evacuation distance)
-- -----------------------------------------------------------------------------
-- Nighttime window used to identify where someone sleeps (wraps past
-- midnight: hour >= NIGHT_START_HOUR OR hour < NIGHT_END_HOUR).
SET NIGHT_START_HOUR = 21;
SET NIGHT_END_HOUR   = 7;

-- Two nightly weighted-centers within this radius are treated as "the same
-- place". Used both to find each person's home (majority nightly cluster
-- across the baseline period, 05_persistence/02_home_location.sql) and their
-- evacuation destination (most recent qualifying nightly cluster during their
-- confirmed away period, 05_persistence/05_destination_location.sql). Not
-- fitted from data yet -- treat as a starting point pending a QC check of
-- night-to-night distances for people with no reason to have traveled.
SET HOME_LOCATION_RADIUS_KM = 3;

-- Minimum nights at the same place (within HOME_LOCATION_RADIUS_KM) required
-- to count as a real destination rather than a one-night transit stop
-- (a highway hotel, for example).
SET MIN_CONSECUTIVE_NIGHTS_AT_DESTINATION = 2;

-- -----------------------------------------------------------------------------
-- Candidate home-location gate (Florida bounding box)
-- -----------------------------------------------------------------------------
-- FL_RESIDENT (00_build_resident.sql) selects devices by Cuebiq's
-- DEVICE_RECURRING_AREA (IS_RESID_1_5), while FL_HOME_LOCATION
-- (02_home_location.sql) is this pipeline's own home estimate from baseline
-- nighttime stops. The two can disagree: a device can pass the residency
-- filter while its nighttime home is outside Florida. Without a check
-- downstream, such a device whose daytime mobility looked "unfamiliar"
-- during the evac window (e.g. a Boston resident on a pre-booked Hawaii
-- trip that overlapped Ian's landfall) gets flagged as a candidate evacuee
-- purely on unfamiliarity, with no connection to Florida at all. 03_candidates.sql requires a candidate's home to fall within this
-- rough bounding box. This is a rectangle, not the true state boundary --
-- it includes a sliver of Georgia/Alabama and clips part of the panhandle --
-- accepted as a reasonable first pass since it only affected ~0.9% of the
-- main_v4 candidate set (150 of 15,953: 148 with home outside the box, 2
-- with no home record at all). Revisit with a real Florida boundary
-- geometry (ST_WITHIN) if that ever becomes available in this project.
SET FL_HOME_LAT_MIN = 24;
SET FL_HOME_LAT_MAX = 31;
SET FL_HOME_LNG_MIN = -88;
SET FL_HOME_LNG_MAX = -79;
