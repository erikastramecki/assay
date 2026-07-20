#!/usr/bin/env bash
# Shared operator env provisioning. The operator REFUSES TO BOOT without POOL_ID/STABLE_TYPE
# (audit F2.3) and a module-load throw 500s every route including /health, so both deploy paths
# must set them — from the WEB build config, so the app and operator can never disagree on the pool.
# Usage: source this, then `provision_operator_env <web-dir> <operator-vercel-dir>`

# Shared build constants — these were byte-identical copies in deploy.sh and deploy-markets.sh.
ESM_BANNER="import { createRequire as __cr } from 'module'; import { fileURLToPath as __fp } from 'url'; import { dirname as __dn } from 'path'; const require = __cr(import.meta.url); const __filename = __fp(import.meta.url); const __dirname = __dn(__filename);"
SPA_REWRITE='{ "rewrites": [{ "source": "/((?!assets/|favicon).*)", "destination": "/index.html" }] }'

# Bundle the operator with esbuild. The committed api/index.mjs is a build artifact (gitignored),
# so every deploy path MUST run this or it ships nothing.
bundle_operator() { # bundle_operator <operator-api-dir>
  ( cd "$1" && ./node_modules/.bin/esbuild server-sui.mjs --bundle --platform=node --format=esm \
      --target=node20 --outfile=assay-operator/api/index.mjs --log-level=error \
      --banner:js="$ESM_BANNER" ) || { echo "❌ operator bundle failed"; return 1; }
}

# Deploy a directory to Vercel prod and alias it. Fails on an empty URL or a failed alias — an
# unaliased deploy leaves the alias pointing at the PREVIOUS build, which the smoke check then
# happily validates.
deploy_and_alias() { # deploy_and_alias <dir> <url-grep> <alias>
  local url
  url=$( cd "$1" && vercel deploy --prod --yes 2>/dev/null | grep -oE "$2" | tail -1 )
  [ -z "$url" ] && { echo "❌ deploy of $1 produced no URL"; return 1; }
  ( cd "$1" && vercel alias set "$url" "$3" >/dev/null 2>&1 ) || { echo "❌ alias set failed for $3"; return 1; }
  echo "   → https://$3"
}
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
