-- geteventsbypid_past.sql

SELECT *
FROM events
WHERE ts_s >= :min_ts
    AND ts_s <= :max_ts
    AND pid = :pid;
ORDER BY ts_s ASC;
