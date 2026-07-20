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
  # The operator now REFUSES TO BOOT without POOL_ID/STABLE_TYPE (audit F2.3) — a module-load throw
  # 500s every route including /health. Provision them from the web build config so the app and the
  # operator can never disagree about which pool they're on, and fail loudly if they're missing.
  POOL_ID=$(grep -E '^VITE_POOL=' "$WEB/.env.production" 2>/dev/null | cut -d= -f2-)
  STABLE_TYPE=$(grep -E '^VITE_STABLE_TYPE=' "$WEB/.env.production" 2>/dev/null | cut -d= -f2-)
  [ -z "$POOL_ID" ] && fail "VITE_POOL missing from $WEB/.env.production (operator cannot boot without POOL_ID)"
  [ -z "$STABLE_TYPE" ] && fail "VITE_STABLE_TYPE missing from $WEB/.env.production"
  ( cd "$OPV"
    vercel env rm POOL_ID production --yes >/dev/null 2>&1
    printf '%s' "$POOL_ID" | vercel env add POOL_ID production --force >/dev/null 2>&1 || exit 1
    vercel env rm STABLE_TYPE production --yes >/dev/null 2>&1
    printf '%s' "$STABLE_TYPE" | vercel env add STABLE_TYPE production --force >/dev/null 2>&1 || exit 1
  ) || fail "could not provision POOL_ID/STABLE_TYPE on the operator project"
  ( cd "$OPDIR" && ./node_modules/.bin/esbuild server-sui.mjs --bundle --platform=node --format=esm --target=node20 \
      --outfile=assay-operator/api/index.mjs --log-level=error --banner:js="$BANNER" ) || fail "operator bundle failed"
  U=$( cd "$OPV" && vercel deploy --prod --yes 2>/dev/null | grep -oE "https://assay-operator-[a-z0-9-]+\.vercel\.app" | head -1 )
  [ -z "$U" ] && fail "operator deploy produced no URL"
  ( cd "$OPV" && vercel alias set "$U" "$OP_ALIAS" >/dev/null 2>&1 ) && echo "   operator → https://$OP_ALIAS"
fi

# ---- web ----
if [ "$do_web" = 1 ]; then
  echo "── web: gen-docs + build + deploy ──"
  ( cd "$WEB" && node gen-docs.mjs >/dev/null && npx vite build >/dev/null 2>&1 ) || fail "web build failed"
  printf '%s' "$REWRITE" > "$WEB/dist/vercel.json"
  U=$( cd "$WEB/dist" && vercel deploy --prod --yes 2>/dev/null | grep -oE "https://[a-z0-9-]+\.vercel\.app" | tail -1 )
  [ -z "$U" ] && fail "web deploy produced no URL"
  ( cd "$WEB/dist" && vercel alias set "$U" "$WEB_ALIAS" >/dev/null 2>&1 ) && echo "   web → https://$WEB_ALIAS"
fi

# ---- smoke ----
echo "── smoke check ──"
# Smoke checks must FAIL the deploy on a bad status (audit R2). Previously these only printed the
# code, so a 500 from a crashed operator was followed by "✅ deploy complete" and exit 0.
smoke() { # smoke <label> <url>
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$2")
  echo "   $1 → $code"
  [ "$code" = "200" ] || fail "$1 smoke check returned $code (expected 200)"
}
[ "$do_op" = 1 ]  && smoke "operator /health" "https://$OP_ALIAS/health"
[ "$do_web" = 1 ] && smoke "web" "https://$WEB_ALIAS"
echo "✅ deploy complete"
