-- Postgres memory tuning for a ~2GB Postgres service budget
-- (shared_buffers = 25%, effective_cache_size = 75% of budget).
--
-- WHEN:      Runs automatically on fresh installs via
--            /docker-entrypoint-initdb.d/migrations/99-memory.sql, so a fresh
--            PG17 deploy starts with these values. After an in-place PG15->17
--            pg_upgrade the initdb scripts do NOT rerun -- apply it manually
--            then (see db/PG17_UPGRADE.md).
-- ROLE:      Apply as a role with ALTER SYSTEM privilege (supabase_admin).
-- RESTART:   shared_buffers is PGC_POSTMASTER -> needs a Postgres RESTART.
--            The other three take effect on the pg_reload_conf() below.
-- OVERRIDE:  values come from PG_* env with defaults (same \set/echo idiom as
--            db/scripts/roles.sql); set PG_* on the Railway Postgres service.
-- COMPANION: the container/platform half of this optimization is
--            railway-memory-vars.sh (Kong/Realtime/Node/PostgREST env) and
--            railway-envoy-swap.sh (gateway swap) -- run them in the same window.
-- MANUAL APPLY (existing container, post-upgrade):
--   docker exec -i -e PGPASSWORD="$DB_SUPERUSER_PASSWORD" \
--     -e PG_SHARED_BUFFERS -e PG_EFFECTIVE_CACHE_SIZE -e PG_WORK_MEM -e PG_MAINTENANCE_WORK_MEM \
--     supabase-db psql -h localhost -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
--     -f /docker-entrypoint-initdb.d/migrations/99-memory.sql
--   # then restart the Postgres service so shared_buffers takes effect.
-- ROLLBACK:
--   ALTER SYSTEM RESET shared_buffers;
--   ALTER SYSTEM RESET effective_cache_size;
--   ALTER SYSTEM RESET work_mem;
--   ALTER SYSTEM RESET maintenance_work_mem;
--   SELECT pg_reload_conf();   -- then restart for shared_buffers

\set shared_buffers        `echo "${PG_SHARED_BUFFERS:-512MB}"`
\set effective_cache_size  `echo "${PG_EFFECTIVE_CACHE_SIZE:-1536MB}"`
\set work_mem              `echo "${PG_WORK_MEM:-8MB}"`
\set maintenance_work_mem  `echo "${PG_MAINTENANCE_WORK_MEM:-128MB}"`

ALTER SYSTEM SET shared_buffers       = :'shared_buffers';
ALTER SYSTEM SET effective_cache_size = :'effective_cache_size';
ALTER SYSTEM SET work_mem             = :'work_mem';
ALTER SYSTEM SET maintenance_work_mem = :'maintenance_work_mem';

SELECT pg_reload_conf();
