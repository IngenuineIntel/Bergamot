-- procentry.sql
-- process lifecycle insert/update statements

INSERT INTO procs (
    pid,
    first_seen_ts_s, first_seen_ts_ms,
    last_seen_ts_s, last_seen_ts_ms,
    ended_ts_s, ended_ts_ms,
    first_uid, first_ppid, first_comm,
    last_uid, last_ppid, last_comm
) VALUES (
    :pid,
    :first_seen_ts_s, :first_seen_ts_ms,
    :last_seen_ts_s, :last_seen_ts_ms,
    :ended_ts_s, :ended_ts_ms,
    :first_uid, :first_ppid, :first_comm,
    :last_uid, :last_ppid, :last_comm
);

UPDATE procs
SET
    last_seen_ts_s = :last_seen_ts_s,
    last_seen_ts_ms = :last_seen_ts_ms,
    last_uid = :last_uid,
    last_ppid = :last_ppid,
    last_comm = :last_comm
WHERE id = :id;

UPDATE procs
SET
    ended_ts_s = :ended_ts_s,
    ended_ts_ms = :ended_ts_ms
WHERE id = :id;