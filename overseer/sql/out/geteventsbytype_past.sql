-- geteventbytype_past.sql

-- TODO reconsider star SELECT
SELECT *
FROM events
WHERE ts_s >= :min_ts
    AND ts_s <= :max_ts
    AND type = ":type"
ORDER BY ts_s ASC;
