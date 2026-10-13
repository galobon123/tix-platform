-- HU 03.2 / task 3: query-latency telemetry (p99 of the seat-availability query).
--
-- docker-entrypoint-initdb.d only runs when the data volume is created for the
-- FIRST time. On an existing volume, create the extension by hand once:
--   make psql  ->  CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
