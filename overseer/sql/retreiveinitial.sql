-- retreiveinitial.sql
-- retreiving all preliminary data for main view

-- args:
-- :min_ts: starting timestamp for view
-- :max_ts: ending timestamp for view

SELECT
    ts_s as cpu_ts,         -- timestamp for CPU% read
    avg_cpu_pct as cpu_perc -- or whatever the CPU% val is
FROM system_perf
WHERE ts_s >= :min_ts AND ts_s <= :max_ts
UNION SELECT
    ts_s as events_ts -- every timestamp is its own data point
FROM events
WHERE ts_s >= :min_ts AND ts_s <= :max_ts
UNION SELECT
    TOTAL(pid) as total_proc -- total processes seen
FROM procs
WHERE first_seen_ts_s >= :min_ts and first_seen_ts_s <= :max_ts
UNION SELECT
    TOTAL(pid) as total_dead_proc -- total dead processes seen
FROM procs
WHERE last_seen_ts_s >= :min_ts and last_seen_ts_s <= :max_ts;


