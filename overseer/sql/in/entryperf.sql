-- systemperfentry.sql
-- add a system performance snapshot row

INSERT INTO system_perf (
    ts_s,
    ts_ms,
    core_count,
    avg_cpu_pct,
    mem_total_kb,
    mem_free_kb,
    mem_available_kb,
    mem_cached_kb,
    load_1m,
    load_5m,
    load_15m,
    cores_json
) VALUES (
    :ts_s,
    :ts_ms,
    :core_count,
    :avg_cpu_pct,
    :mem_total_kb,
    :mem_free_kb,
    :mem_available_kb,
    :mem_cached_kb,
    :load_1m,
    :load_5m,
    :load_15m,
    :cores_json
);
