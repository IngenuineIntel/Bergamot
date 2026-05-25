-- processing_getmaxmints.sql
-- gets maximum and minimum possible timestamps within event logs

-- we select from events, as there are more events than anything else
SELECT MIN(ts_s), MAX(ts_s) FROM events;
