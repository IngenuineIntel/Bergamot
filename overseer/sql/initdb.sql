-- newdb.sql
-- script for starting a new database
PRAGMA jorunal_mode=WAL;
PRAGMA busy_timeout=5000;

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

CREATE TABLE overviewdata (
    hostname TEXT, -- computer hostname
    kernelver TEXT, -- kernel version
    distro TEXT, -- *nix distribution
    ipaddr TEXT, -- IP address
    macaddr TEXT, -- MAC address
    processor TEXT, -- processor
    processor_vend TEXT, -- processor vendor
    ram_gbs INTEGER -- nr GBs of RAM
);

INSERT INTO overviewdata VALUES (
    :hostname, :kernelver, :distro, :ipaddr, :macaddr, :processor,
    :processor_vend, :ram_gbs
);

CREATE TABLE events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_s INTEGER DEFAULT (unixepoch()), -- UNIX time
    ts_ms INTEGER, -- additional milliseconds
    pid INTEGER, -- PID
    ppid INTEGER, -- PPID
    uid INTEGER, -- UID
    type TEXT, -- syscall (or syscall family) in question
    subtype TEXT, -- further minutia of the specific syscall
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

CREATE TABLE system_perf (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_s INTEGER NOT NULL,
    ts_ms INTEGER NOT NULL,
    core_count INTEGER NOT NULL,
    avg_cpu_pct REAL NOT NULL,
    mem_total_kb INTEGER NOT NULL,
    mem_free_kb INTEGER NOT NULL,
    mem_available_kb INTEGER NOT NULL,
    mem_cached_kb INTEGER NOT NULL,
    load_1m REAL NOT NULL,
    load_5m REAL NOT NULL,
    load_15m REAL NOT NULL,
    cores_json TEXT NOT NULL
);

CREATE INDEX idx_system_perf_ts ON system_perf(ts_s, ts_ms);
