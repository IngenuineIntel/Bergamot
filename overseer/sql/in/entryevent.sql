-- evententry.sql
-- adding a new event

INSERT INTO events (
    ts_s, ts_ms, pid, ppid, uid, type, subtype, comm, arg1, arg2, retval
) VALUES (
    :ts_s,
    :ts_ms,
    :pid,
    :ppid,
    :uid,
    :type,
    :subtype,
    :comm,
    :arg1,
    :arg2,
    :retval
);