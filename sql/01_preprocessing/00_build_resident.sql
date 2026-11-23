-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Builds DEDICATED.HOUPU.FL_RESIDENT, the target-resident population that
-- every downstream file in this pipeline (01_extract_stops.sql via INNER
-- JOIN, 02_cohort/01_analysis_cohort.sql via FROM) depends on. This table
-- was previously assumed to already exist; it is actually derived from
-- Houpu's residency-qualification table DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_FULL
-- (built by sql/00_residents_detection/residents_detection.sql),
-- which computes several candidate "is this cuebiq_id a recurring Florida
-- resident" rules side by side (IS_RESID_1_2, IS_RESID_1_3, IS_RESID_1_4,
-- IS_RESID_1_5, IS_RESID_2_3). This pipeline uses the IS_RESID_1_5 = 1
-- definition: home detected (via Cuebiq's DEVICE_RECURRING_AREA) in a
-- target CBG -- i.e. a CBG in DEDICATED.HOUPU.HURRICANE_IAN_MANDATORY_CBG_CROSS,
-- under Ian's mandatory evacuation order -- on at least 5 of the 21
-- baseline days. The other IS_RESID_* flags are not used here.
--
-- Only the columns actually consumed downstream are carried through
-- (cuebiq_id, home_geo10, days_in_target_cbgs, days_at_home_cbg,
-- home_consistency); FL_RECURRING_RESIDENTS_FULL's per-day home_geo10
-- columns (one per baseline calendar date) are not needed here and are
-- dropped.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_RESIDENT
AS

SELECT
    cuebiq_id,
    home_geo10,
    days_in_target_cbgs,
    days_at_home_cbg,
    home_consistency

FROM DEDICATED.HOUPU.FL_RECURRING_RESIDENTS_FULL
WHERE is_resid_1_5 = 1;
