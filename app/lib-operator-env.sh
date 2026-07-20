#!/usr/bin/env bash
# Shared operator env provisioning. The operator REFUSES TO BOOT without POOL_ID/STABLE_TYPE
# (audit F2.3) and a module-load throw 500s every route including /health, so both deploy paths
# must set them — from the WEB build config, so the app and operator can never disagree on the pool.
# Usage: source this, then `provision_operator_env <web-dir> <operator-vercel-dir>`
provision_operator_env() {
  local webdir="$1" opvdir="$2"
  local pool stable
  pool=$(grep -E '^VITE_POOL=' "$webdir/.env.production" 2>/dev/null | cut -d= -f2-)
  stable=$(grep -E '^VITE_STABLE_TYPE=' "$webdir/.env.production" 2>/dev/null | cut -d= -f2-)
  [ -z "$pool" ]   && { echo "❌ VITE_POOL missing from $webdir/.env.production (operator cannot boot)"; return 1; }
  [ -z "$stable" ] && { echo "❌ VITE_STABLE_TYPE missing from $webdir/.env.production"; return 1; }
  ( cd "$opvdir" || exit 1
    vercel env rm POOL_ID production --yes >/dev/null 2>&1
    printf '%s' "$pool"   | vercel env add POOL_ID production --force >/dev/null 2>&1 || exit 1
    vercel env rm STABLE_TYPE production --yes >/dev/null 2>&1
    printf '%s' "$stable" | vercel env add STABLE_TYPE production --force >/dev/null 2>&1 || exit 1
  ) || { echo "❌ could not provision POOL_ID/STABLE_TYPE"; return 1; }
}

# Smoke check that actually FAILS on a bad status. Both deploy scripts previously printed the code
# and then reported success, so a 500 from a crashed operator ended in "✅ deploy complete", exit 0.
smoke_check() { # smoke_check <label> <url>
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$2")
  echo "   $1 → $code"
  [ "$code" = "200" ]
}
