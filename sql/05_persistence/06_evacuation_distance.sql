-- Run ../../PARAMETERS.sql first in the same Snowflake session.
--
-- Final summary table for the persistence stage: one row per candidate
-- evacuee, combining departure, return, home location, destination
-- location, and the single home->destination "evacuation distance" number
-- requested for this analysis. A candidate may have no confirmed return
-- in the observed data (return still pending as of RETURN_END), and
-- FL_EVAC_DESTINATION can be missing for a candidate whose away-period
-- nights never formed a qualifying same-place cluster (sparse data) --
-- those rows keep their other fields and simply have NULLs where the
-- missing piece would go. FL_HOME_LOCATION is always present here, since
-- 03_candidates.sql already inner-joins it (home-location gate); its LEFT
-- JOIN below is kept only as a harmless safeguard.

CREATE OR REPLACE TRANSIENT TABLE
DEDICATED.HOUPU.FL_EVAC_SUMMARY
AS

SELECT
    c.cuebiq_id,

    -- departure
    c.candidate_start_date,
    c.candidate_streak_end_date,
    c.candidate_streak_length,
    c.candidate_streak_calendar_span_days,

    -- return
    r.return_date,
    r.return_streak_length,
    r.return_streak_calendar_span_days,

    -- home location
    h.n_home_nights,
    h.home_lat,
    h.home_lng,

    -- destination location
    d.n_destination_nights,
    d.destination_arrival_night,
    d.destination_last_confirmed_night,
    d.destination_lat,
    d.destination_lng,

    -- evacuation distance: single home -> destination number, NULL if
    -- either endpoint could not be determined
    CASE
        WHEN h.home_geog IS NOT NULL AND d.destination_geog IS NOT NULL
            THEN ST_DISTANCE(h.home_geog, d.destination_geog) / 1000.0
        ELSE NULL
    END AS evacuation_distance_km

FROM DEDICATED.HOUPU.FL_EVAC_CANDIDATES AS c

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_RETURN_DATES AS r
    ON c.cuebiq_id = r.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_HOME_LOCATION AS h
    ON c.cuebiq_id = h.cuebiq_id

LEFT JOIN DEDICATED.HOUPU.FL_EVAC_DESTINATION AS d
    ON c.cuebiq_id = d.cuebiq_id;
