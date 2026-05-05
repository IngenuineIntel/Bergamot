-- evententry.sql
-- adding a new event

INSERT INTO events (
    ts_s, ts_ms, pid, ppid, uid, type, comm, arg1, arg2
) VALUES (
    :ts_s,
    :ts_ms,
    :pid,
    :ppid,
    :uid,
    :type,
    :comm,
    :arg1,
    :arg2
);