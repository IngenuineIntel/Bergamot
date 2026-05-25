-- gets process information within a certain timestamp

-- TODO if ended_ts_s == max_max_ts, we don't actually know when the process
-- died and it needs to be handled somehow, either here in the SQL (fastest?)
-- or in the calling Python

SELECT
    pid,
    first_seen_ts_s,
    first_seen_ts_ms,
    last_seen_ts_s,
    last_seen_ts_ms,
    ended_ts_s,
    ended_ts_ms,
    first_uid,
    first_ppid,
    first_comm,
    last_uid,
    last_ppid,
    last_comm
FROM procs
WHERE first_seen_ts_s > :min_ts
    AND first_seen_ts_s <= :max_ts
ORDER BY first_seen_ts_s ASC;