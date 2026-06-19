# Postgres 15 → 17 upgrade runbook (Railway, self-hosted Supabase)

**Status of prod (2026-06-19):** Railway project `incredible-nature`, service **Postgres**,
running **15.14** on a PG15 data volume. The repo already ships a PG17 image
(`db/pg17.Dockerfile`, `docker-compose.pg17.yml`) but the live volume has never been migrated.

A PG major upgrade **cannot** be done by swapping the image over the existing volume — PG17
refuses to start on a v15 data directory (`database files are incompatible with server`).
The volume must be rebuilt via dump → fresh PG17 → restore.

> Two birds: the live DB also logs a **collation mismatch** (built under glibc 2.39, OS now
> provides 2.40). A from-scratch restore rebuilds every index under the new collation and clears
> this — no separate `REINDEX` needed.

---

## 0. Decide: greenfield shortcut vs. dump/restore

If prod holds little/no real data (auth users, storage objects, app rows are throwaway), **skip the
dump entirely**: deploy the PG17 image on a fresh volume, let init + `db/scripts/*` + `supabase db push`
rebuild the structure, and re-seed by hand. Faster and lower-risk.

Use the dump/restore below only when you must preserve live data.

---

## 1. Pre-flight (do not skip)

- [ ] **Maintenance window.** Writes during the dump will be lost on cutover.
- [ ] **Snapshot the PG15 Railway volume** (Railway dashboard → Postgres → Volume → backup) so you can roll back.
- [ ] **Stop writers**: pause the app services (auth, rest, realtime, storage, studio) that write to the DB, or
      put the app in read-only. Keeps the dump consistent.
- [ ] **Use a PG17 client** for every dump/restore command so output is forward-compatible. All commands
      below run `pg_dump`/`psql` *inside* the supabase PG17 image, so the client is always 17:

```bash
IMG=public.ecr.aws/supabase/postgres:17.6.1.136
dump(){ docker run --rm -i --entrypoint "$1" "$IMG" "${@:2}"; }
```

- [ ] **Connection strings.** Old DB via the Railway public proxy; SSL is **off**, so append `?sslmode=disable`:

```bash
OLD="$(railway variables --json | jq -r .DB_PUBLIC_CONNECTION_STRING)?sslmode=disable"   # PG15 source
# NEW=... set in step 3 once the PG17 service has a proxy domain
```

---

## 2. Dump from PG15

Run from a host with Docker + the Railway CLI logged in. Order matters: roles → schema → data.

```bash
mkdir -p ./pg17-migration && cd ./pg17-migration

# 2a. Roles + passwords (supabase_admin, authenticator, supabase_auth_admin, ... )
docker run --rm -i --entrypoint pg_dumpall "$IMG" -d "$OLD" --globals-only --no-tablespaces > roles.sql

# 2b. Both databases, full (schema + data). Self-hosted Supabase uses `postgres` and `_supabase`.
docker run --rm -i --entrypoint pg_dump "$IMG" "$OLD" \
  --format=custom --no-owner --no-privileges --file=/dev/stdout > postgres.dump

OLD_SUPA="${OLD/\/postgres?/\/_supabase?}"   # same creds, db=_supabase
docker run --rm -i --entrypoint pg_dump "$IMG" "$OLD_SUPA" \
  --format=custom --no-owner --no-privileges --file=/dev/stdout > _supabase.dump
```

> Why full custom-format dumps and not `supabase db dump`: the new image re-initialises the supabase
> system schemas (auth/storage/realtime) and roles itself, so we restore **data** selectively in step 4
> rather than overwriting those. Custom format lets `pg_restore` pick which sections to load.

Sanity check the dumps are non-empty:

```bash
ls -la roles.sql postgres.dump _supabase.dump
docker run --rm -i --entrypoint pg_restore "$IMG" -l postgres.dump | head
```

---

## 3. Provision the PG17 service

1. Deploy the PG17 image (`db/pg17.Dockerfile` / `docker-compose.pg17.yml`) as a **new** Railway service
   with a **new empty volume** — leave the PG15 service untouched for rollback.
2. Copy the same env vars (all `DB_*_PASSWORD`, `POSTGRES_*`, `JWT_SECRET`, etc.) so `db/scripts/roles.sql`
   sets the same role passwords and the app keeps working post-cutover.
3. Let it boot fully. On first init the image creates roles, the supabase schemas, and the extensions;
   then run your migrations against it:

```bash
NEW="postgres://postgres:<NEW_SUPERUSER_PW>@<new-proxy-host>:<port>/postgres?sslmode=disable"
cd /path/to/repo/site && supabase db push --db-url "$NEW" --yes
```

After this the new DB has the **structure** (incl. the new `*_enable_extensions` and `*_live_drift`
migrations) but only seed data.

> **Memory tuning is automatic on this path.** The image bakes `db/scripts/memory.sql` into
> `/docker-entrypoint-initdb.d/migrations/99-memory.sql`, so a fresh-volume PG17 boot applies
> `shared_buffers`/`effective_cache_size`/`work_mem`/`maintenance_work_mem` from the first start
> (override via `PG_*` vars on the Postgres service). No manual step needed here; an *in-place*
> `pg_upgrade` would instead need the manual apply documented in that file's header. Run the
> platform companions (`railway-memory-vars.sh`, `railway-envoy-swap.sh`) in the same window.

---

## 4. Restore data into PG17

The structure already exists, so restore **data only**, and only the schemas you own + supabase data
schemas. Disable triggers during load to avoid FK/order issues.

```bash
# 4a. App + supabase data from the `postgres` db (auth.users, storage.*, public.*, private.*)
docker run --rm -i --entrypoint pg_restore "$IMG" \
  --data-only --disable-triggers --no-owner --no-privileges \
  --schema=auth --schema=storage --schema=public --schema=private \
  -d "$NEW" postgres.dump

# 4b. _supabase db (analytics/_realtime internal data), if you use it
NEW_SUPA="${NEW/\/postgres?/\/_supabase?}"
docker run --rm -i --entrypoint pg_restore "$IMG" \
  --data-only --disable-triggers --no-owner --no-privileges \
  -d "$NEW_SUPA" _supabase.dump
```

> If a data-only restore hits "relation already has data" / duplicate-key errors, the image seeded a
> row the dump also contains (e.g. a default bucket). Either `truncate` that table on NEW first, or add
> `--exclude-table-data=<schema.table>` to the dump in step 2.

Reset sequences after a data-only load:

```bash
docker run --rm -i --entrypoint psql "$IMG" "$NEW" -X -c "
  select setval(pg_get_serial_sequence(format('%I.%I',schemaname,tablename), c.column_name),
                coalesce(max_val,1))
  from ( /* fill per-table or use a helper */ ) s;" || true   # or re-run app-specific reseed
```

---

## 5. Verify

```bash
psql_new(){ docker run --rm -i --entrypoint psql "$IMG" "$NEW" -X -A -t -c "$1"; }
psql_new "select version();"                                   # expect 17.x
psql_new "select count(*) from auth.users;"                    # matches PG15
psql_new "select count(*) from public.boards;"                 # matches PG15
psql_new "select extname from pg_extension order by 1;"        # all 23 present
psql_new "select count(*) from pg_class where relhasindex;"    # indexes rebuilt, no collation warning on connect
psql_new "select name,setting,pending_restart from pg_settings
          where name in ('shared_buffers','effective_cache_size','work_mem','maintenance_work_mem');"  # tuned, shared_buffers not pending
```

Smoke-test the app against NEW (auth login, a board read/write, a storage upload).

---

## 6. Cutover

1. Point the app services (kong/rest/auth/realtime/storage/studio) at the NEW DB host — update their
   `DB_HOST`/connection vars, or move the Railway public proxy / internal hostname to the new service.
2. Re-enable writers / take the app out of maintenance.
3. Watch logs for connection or permission errors (role passwords must match step 3.2).

## 7. Rollback

If verification fails: repoint services back to the PG15 service (still running, untouched) and
re-enable writers. Investigate, then retry. Only delete the PG15 volume after NEW has run clean for a
few days.

## 8. Cleanup

- [ ] `trash ./pg17-migration` (contains a full data dump — do not commit).
- [ ] Delete the old PG15 service/volume once confident.
- [ ] Bump the main compose to the PG17 image so future deploys use it.
