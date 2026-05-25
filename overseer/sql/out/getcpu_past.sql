-- processing_cpu.sql
-- gets information required for "CPU%" amd "RAM%"

SELECT
    ts_s AS y,
    avg_cpu_pct AS cpu_x,
    CAST(mem_total_kb - mem_available_kb AS float)
        / CAST(mem_total_kb AS float)
        * 100
        AS ram_x 
FROM system_perf
WHERE ts_s >= :min_ts
    AND ts_s <= :max_ts
GROUP BY y;
