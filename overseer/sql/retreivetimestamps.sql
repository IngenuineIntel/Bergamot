-- retreiveextremetimestamps.sql
-- retreiving max and min timestamps for view

SELECT
    MAX(ts_s) as max,
    MIN(ts_s) as min
FROM events; -- or procs, or system_perf, doesn't matter
