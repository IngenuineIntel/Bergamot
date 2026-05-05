-- newdb.sql
-- script for starting a new database

CREATE TABLE metadata (
    db_name TEXT,
    db_time TEXT,
    overseer_ver TEXT
);

INSERT INTO metadata (
    db_name, db_time, overseer_ver
) VALUES (
    :db_name, :db_time, :overseer_ver
);

CREATE TABLE events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_s INTEGER DEFAULT (unixepoch()), -- UNIX time
    ts_ms INTEGER, -- additional milliseconds
    pid INTEGER, -- PID
    ppid INTEGER, -- PPID
    uid INTEGER, -- UID
    type TEXT, -- syscall in question
    comm TEXT, -- process command
    arg1 TEXT, -- syscall argument (usually *rdi)
    -- No other implementation of the protocol has `arg2` - but one
    -- day they might
    arg2 TEXT -- syscall argument (usually *rsi)
);

CREATE TABLE procs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pid INTEGER NOT NULL,

    first_seen_ts_s INTEGER NOT NULL,
    first_seen_ts_ms INTEGER NOT NULL,
    last_seen_ts_s INTEGER NOT NULL,
    last_seen_ts_ms INTEGER NOT NULL,
    ended_ts_s INTEGER,
    ended_ts_ms INTEGER,

    first_uid INTEGER,
    first_ppid INTEGER,
    first_comm TEXT,
    last_uid INTEGER,
    last_ppid INTEGER,
    last_comm TEXT
);

CREATE INDEX idx_procs_pid ON procs(pid);
CREATE INDEX idx_procs_active ON procs(pid, ended_ts_s);
