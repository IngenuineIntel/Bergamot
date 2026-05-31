-- getcpu_live.sql

SELECT
    ts_s as y,
    avg_cpu_pct AS cpu_x,
    CAST(mem_total_kb - mem_available_kb AS FLOAT)
        / CAST(mem_total_kb AS FLOAT)
        * 100
        AS ram_x
FROM perf
ORDER BY y ASC;