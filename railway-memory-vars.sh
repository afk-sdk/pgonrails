#!/usr/bin/env bash
#
# Apply memory-footprint tuning to Railway service variables.
#
# WHY THIS EXISTS: Railway builds each service from its Dockerfile and injects
# Railway-defined variables; it does NOT read docker-compose.yml `environment:`
# blocks (those are for local `docker compose` only). So the memory env vars must
# live here as Railway variables to actually take effect in production.
#
# Prereqs:
#   - railway CLI installed
#   - `railway login`
#   - `railway link`  (select the project + environment once)
#   - verify your exact service names below (dashboard, or `railway list`)
#
# Easier one-off alternative: Railway dashboard -> <service> -> Variables ->
# "Raw Editor" lets you paste KEY=VALUE lines and bulk-upserts. This script is
# the repeatable / infra-as-code version.

set -euo pipefail

# --- service names: edit to match your Railway project ---
SVC_KONG="Kong"
SVC_REALTIME="Supabase Realtime"
SVC_STORAGE="Supabase Storage"
SVC_META="Postgres Meta"
SVC_STUDIO="Supabase Studio"
SVC_REST="PostgREST"
SVC_DB="Postgres"

ALL_SERVICES=(
  "$SVC_KONG" "$SVC_REALTIME" "$SVC_STORAGE" "$SVC_META"
  "$SVC_STUDIO" "$SVC_REST" "$SVC_DB"
)

# set_vars <service> KEY=VALUE [KEY=VALUE ...]
# --skip-deploys batches changes; we redeploy once at the end.
set_vars() {
  local svc="$1"; shift
  echo "==> setting variables on: $svc"
  railway variable set "$@" --service "$svc" --skip-deploys
}

set_vars "$SVC_KONG" \
  KONG_NGINX_WORKER_PROCESSES=1 \
  KONG_MEM_CACHE_SIZE=32m

# ERL_AFLAGS value contains spaces -> keep it one quoted argument.
set_vars "$SVC_REALTIME" \
  "ERL_AFLAGS=-proto_dist inet6_tcp +S 2:2 +SDcpu 1:1 +SDio 1 +sbwt none +sbwtdcpu none +sbwtdio none"

set_vars "$SVC_STORAGE" \
  MALLOC_ARENA_MAX=2 \
  NODE_OPTIONS=--max-old-space-size=256 \
  STORAGE_S3_MAX_SOCKETS=50

set_vars "$SVC_META" \
  MALLOC_ARENA_MAX=2 \
  NODE_OPTIONS=--max-old-space-size=192

set_vars "$SVC_STUDIO" \
  MALLOC_ARENA_MAX=2 \
  NODE_OPTIONS=--max-old-space-size=256

set_vars "$SVC_REST" \
  PGRST_DB_POOL=10 \
  PGRST_DB_POOL_ACQUISITION_TIMEOUT=10 \
  PGRST_DB_POOL_MAX_IDLETIME=30 \
  PGRST_DB_POOL_MAX_LIFETIME=1800

# These override db/wrapper.sh defaults (which are sized for a ~2GB Postgres budget).
# NOTE: they only take effect once the updated db/wrapper.sh is deployed from source
# (git push the repo so Railway rebuilds the Postgres service).
set_vars "$SVC_DB" \
  PG_SHARED_BUFFERS=512MB \
  PG_EFFECTIVE_CACHE_SIZE=1536MB \
  PG_WORK_MEM=8MB \
  PG_MAINTENANCE_WORK_MEM=128MB

echo
echo "Variables set. Redeploying each service to apply..."
for svc in "${ALL_SERVICES[@]}"; do
  echo "==> redeploy: $svc"
  railway redeploy --service "$svc" --yes
done

echo
echo "Done. Watch each service's memory graph and adjust if needed."
echo "If Realtime struggles under load, bump ERL_AFLAGS '+S 2:2' to '+S 4:4'."
