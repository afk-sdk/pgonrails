-- Enable every extension present on the self-hosted (prod) database.
-- Idempotent (create extension if not exists): no-op where the image already installed it,
-- creates the rest on a fresh deploy. Generated from live pg_extension on 2026-06-19.
-- 'extensions'-schema group is pinned to schema extensions; the rest use their fixed control-file schema.

create extension if not exists citext with schema extensions;
create extension if not exists fuzzystrmatch with schema extensions;
create extension if not exists hstore with schema extensions;
create extension if not exists hypopg with schema extensions;
create extension if not exists index_advisor with schema extensions;
create extension if not exists insert_username with schema extensions;
create extension if not exists ltree with schema extensions;
create extension if not exists moddatetime with schema extensions;
create extension if not exists pg_cron;
create extension if not exists pg_graphql;
create extension if not exists pg_jsonschema with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_stat_statements with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pgmq;
create extension if not exists pgsodium;
create extension if not exists rum with schema extensions;
create extension if not exists supabase_vault;
create extension if not exists tcn with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists vector with schema extensions;
create extension if not exists wrappers with schema extensions;
