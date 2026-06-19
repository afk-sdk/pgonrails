#!/usr/bin/env bash
#
# Swap the Railway API gateway from Kong to Envoy (much lighter: ~30-50MB vs Kong's 200MB+).
#
# STRATEGY: convert the EXISTING gateway service in place to build ./envoy instead
# of ./kong. Because it stays the same Railway service, its internal hostname
# (what KONG_HOST resolves to) and its public domain don't change, so NO other
# service needs rewiring. Envoy's listener is port 8000 == KONG_PORT, so the
# exposed/target port is already correct.
#
# Envoy needs the same gateway variables Kong already has, EXCEPT it reads the API
# keys under the names ANON_KEY / SERVICE_ROLE_KEY (Kong used SUPABASE_ANON_KEY /
# SUPABASE_SERVICE_KEY). Everything else Envoy needs is already present with
# matching names: SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY,
# ANON_KEY_ASYMMETRIC, SERVICE_ROLE_KEY_ASYMMETRIC, DASHBOARD_USERNAME/PASSWORD,
# and all *_HOST / *_PORT pairs. This script adds only the two missing aliases.
#
# ── MANUAL STEPS (Railway dashboard — the CLI can't do these) ──────────────────
#   1. Gateway service -> Settings -> Source -> Root Directory: change /kong -> /envoy
#      (keep the same service so the hostname + domain are preserved).
#   2. Run this script to add the ANON_KEY / SERVICE_ROLE_KEY aliases.
#   3. Redeploy the gateway service (this script does it at the end).
#   4. Delete the Caddy service — Railway terminates TLS at its edge, so Caddy's
#      TLS + Studio basic-auth roles are redundant (Envoy handles dashboard auth).
# ───────────────────────────────────────────────────────────────────────────────
#
# Prereqs: railway CLI + `railway login` + `railway link`.

set -euo pipefail

# Name of the gateway service being converted (was Kong). Edit if yours differs.
SVC_GW="Kong"

echo "==> Adding Envoy key aliases to gateway service: $SVC_GW"
# Reference the values already stored on the same service (Railway resolves
# ${{Service.VAR}} at deploy time). Single quotes stop the local shell from
# touching the ${{...}} reference syntax.
railway variable set \
  'ANON_KEY=${{'"$SVC_GW"'.SUPABASE_ANON_KEY}}' \
  'SERVICE_ROLE_KEY=${{'"$SVC_GW"'.SUPABASE_SERVICE_KEY}}' \
  --service "$SVC_GW" --skip-deploys

echo "==> Redeploying $SVC_GW (now building ./envoy)"
railway redeploy --service "$SVC_GW" --yes

echo
echo "Done. Verify:"
echo "  - gateway logs show 'Starting Envoy...' (and 'sb_ key translation enabled'"
echo "    if you set the asymmetric/publishable/secret keys, else 'legacy API key mode')"
echo "  - Studio + your app still reach the API through the same gateway URL"
echo "Then delete the Caddy service in the Railway dashboard."
