-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- A candidate evacuee is someone whose LAST unfamiliar streak (from
-- 01_unfamiliar_streaks.sql) reaches at least through $PERSISTENCE_CHECK_END
-- (reaches_window_end = 1, within the same $MAX_GAP_DAYS_TO_BRIDGE
-- tolerance used to build the streak) AND is at least
-- $MIN_CONSECUTIVE_UNFAMILIAR_DAYS long. This replaces the previous
-- "earliest qualifying streak" rule: a streak that ends and is followed by
-- a confirmed return home before $PERSISTENCE_CHECK_END no longer counts,
-- even if it was long enough on its own, because it wasn't necessarily
-- caused by the storm (e.g. someone who left on 9/24, came home on 9/27 and
-- stayed, before Ian made landfall on 9/28, should not be flagged). A
-- confirmed return AFTER $PERSISTENCE_CHECK_END (e.g. home by 9/30, once
-- the storm has already passed) does not disqualify the candidate -- see
-- 01_unfamiliar_streaks.sql's header for the reasoning.
--
-- Because at most one streak per user can reach $PERSISTENCE_CHECK_END, no
-- ranking is needed here -- the WHERE clause alone picks at most one row per
-- cuebiq_id (verified empirically: n_rows = n_users in FL_EVAC_CANDIDATES).
-- candidate_start_date is therefore the true departure date: the first day
-- of the run that persists, uninterrupted by a confirmed return, through
-- $PERSISTENCE_CHECK_END.
--
-- Home-location gate: also requires a confirmed home (FL_HOME_LOCATION,
-- 02_home_location.sql) within the rough Florida bounding box defined by
-- $FL_HOME_LAT_MIN/MAX and $FL_HOME_LNG_MIN/MAX (see PARAMETERS.sql).
-- FL_RESIDENT is defined from Cuebiq's DEVICE_RECURRING_AREA, while
-- FL_HOME_LOCATION is estimated independently from baseline nighttime
-- stops; the two can disagree, so without this join someone whose nighttime
-- home is nowhere near Florida but whose daytime mobility happened to look
-- unfamiliar during the evac window would still be flagged as a
-- candidate (found via spot-check: a Boston resident on a pre-booked Hawaii
-- trip that overlapped Ian's landfall). A candidate with no FL_HOME_LOCATION
-- row at all (sparse baseline nighttime coverage) is also excluded here,
-- since their home cannot be confirmed to be in Florida either.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_CANDIDATES
AS

SELECT
    s.cuebiq_id,
    s.streak_start AS candidate_start_date,
    s.streak_end AS candidate_streak_end_date,
    s.streak_length AS candidate_streak_length,
    s.streak_calendar_span_days AS candidate_streak_calendar_span_days,
    s.min_knn_score_km,
    s.median_knn_score_km,
    s.max_knn_score_km,
    s.baseline_score_max_km,
    s.median_score_to_baseline_ratio

FROM DEDICATED.HOUPU.FL_EVAC_FLAG_STREAKS AS s

INNER JOIN DEDICATED.HOUPU.FL_HOME_LOCATION AS h
    ON s.cuebiq_id = h.cuebiq_id
   AND h.home_lat BETWEEN $FL_HOME_LAT_MIN AND $FL_HOME_LAT_MAX
   AND h.home_lng BETWEEN $FL_HOME_LNG_MIN AND $FL_HOME_LNG_MAX

WHERE s.reaches_window_end = 1
  AND s.streak_length >= $MIN_CONSECUTIVE_UNFAMILIAR_DAYS;
