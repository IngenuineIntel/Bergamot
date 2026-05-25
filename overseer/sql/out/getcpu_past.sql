-- processing_cpu.sql
-- gets information required for "CPU%" amd "RAM%"

SELECT
    ts_s AS y,
    avg_cpu_pct AS cpu_x,
    CAST(mem_total_kb - mem_available_kb AS FLOAT)
        / CAST(mem_total_kb AS FLOAT)
        * 100
        AS ram_x 
FROM perf
WHERE
    ts_s >= :min_ts
    AND ts_s <= :max_ts
GROUP BY y
ORDER BY y ASC;
