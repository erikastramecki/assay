#!/usr/bin/env bash
# One-command deploy for the Assay stack. Preflight (tsc, optional move test) → build → deploy →
# pin the stable alias → smoke check. Replaces the manual rebuild/vercel/alias dance.
#   bash deploy.sh              # web + operator
#   bash deploy.sh --web        # web only
#   bash deploy.sh --operator   # operator only
#   bash deploy.sh --test       # also run `sui move test` in preflight
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WEB="$HERE/web"; OPDIR="$HERE/operator-api"; OPV="$OPDIR/assay-operator"
WEB_ALIAS=assay-sui.vercel.app; OP_ALIAS=assay-operator-sui.vercel.app
BANNER="import { createRequire as __cr } from 'module'; import { fileURLToPath as __fp } from 'url'; import { dirname as __dn } from 'path'; const require = __cr(import.meta.url); const __filename = __fp(import.meta.url); const __dirname = __dn(__filename);"
REWRITE='{ "rewrites": [{ "source": "/((?!assets/|favicon).*)", "destination": "/index.html" }] }'
fail() { echo "❌ $1"; exit 1; }
. "$HERE/lib-operator-env.sh"

do_web=0; do_op=0; run_test=0
[ $# -eq 0 ] && { do_web=1; do_op=1; }
for a in "$@"; do case "$a" in
  --web) do_web=1 ;; --operator) do_op=1 ;; --all) do_web=1; do_op=1 ;; --test) run_test=1 ;;
  *) fail "unknown flag $a" ;; esac; done

# ---- preflight ----
if [ "$do_web" = 1 ]; then echo "── preflight: web tsc ──"; ( cd "$WEB" && npx tsc --noEmit ) || fail "web tsc failed"; fi
if [ "$run_test" = 1 ]; then echo "── preflight: sui move test ──"
  ( cd "$HERE/../move/dregg_lending_async" && sui move test --build-env testnet 2>&1 | grep -q "Test result: OK" ) || fail "move test failed"; fi

# ---- operator ----
if [ "$do_op" = 1 ]; then
  echo "── operator: bundle + deploy ──"
  provision_operator_env "$WEB" "$OPV" || fail "operator env provisioning failed"
  ( cd "$OPDIR" && ./node_modules/.bin/esbuild server-sui.mjs --bundle --platform=node --format=esm --target=node20 \
      --outfile=assay-operator/api/index.mjs --log-level=error --banner:js="$BANNER" ) || fail "operator bundle failed"
  U=$( cd "$OPV" && vercel deploy --prod --yes 2>/dev/null | grep -oE "https://assay-operator-[a-z0-9-]+\.vercel\.app" | head -1 )
  [ -z "$U" ] && fail "operator deploy produced no URL"
  ( cd "$OPV" && vercel alias set "$U" "$OP_ALIAS" >/dev/null 2>&1 ) || fail "operator alias set failed (smoke would validate the PREVIOUS deploy)"
  echo "   operator → https://$OP_ALIAS"
fi

# ---- web ----
if [ "$do_web" = 1 ]; then
  echo "── web: gen-docs + build + deploy ──"
  ( cd "$WEB" && node gen-docs.mjs >/dev/null && npx vite build >/dev/null 2>&1 ) || fail "web build failed"
  printf '%s' "$REWRITE" > "$WEB/dist/vercel.json"
  U=$( cd "$WEB/dist" && vercel deploy --prod --yes 2>/dev/null | grep -oE "https://[a-z0-9-]+\.vercel\.app" | tail -1 )
  [ -z "$U" ] && fail "web deploy produced no URL"
  ( cd "$WEB/dist" && vercel alias set "$U" "$WEB_ALIAS" >/dev/null 2>&1 ) || fail "web alias set failed (smoke would validate the PREVIOUS deploy)"
  echo "   web → https://$WEB_ALIAS"
fi

# ---- smoke ----
echo "── smoke check ──"
[ "$do_op" = 1 ]  && { smoke_check "operator /health" "https://$OP_ALIAS/health" || fail "operator smoke check failed"; }
[ "$do_web" = 1 ] && { smoke_check "web" "https://$WEB_ALIAS" || fail "web smoke check failed"; }
echo "✅ deploy complete"
