-- processing_geteps.sql
-- gets information required for "Events/Second"

SELECT
    ts_s AS y,
    COUNT(*) AS x
FROM events
WHERE ts_s >= :min_ts
    AND ts_s <= :max_ts
GROUP BY y; 

-- FIXME what was I thinking?