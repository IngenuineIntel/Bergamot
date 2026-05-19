-- initialview_geteps.sql
-- gets information required for "Events/Second"

SELECT
    ts_s AS y,
    COUNT(*) AS x
FROM events
WHERE (
    y >= :min_ts AND
    y <= :max_ts
)
GROUP BY y; 
