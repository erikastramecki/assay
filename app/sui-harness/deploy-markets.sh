#!/usr/bin/env bash
# Push the current markets live: update the operator's registry + faucet env from the generated
# files, redeploy the operator, then rebuild + redeploy the web (markets.ts is baked in — coinTypes
# are self-contained, so no per-market env needed). Run after add-market.sh (or any markets.json edit
# followed by `python3 gen-configs.py`).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
OPDIR="$ROOT/operator-api"; OPVDIR="$OPDIR/assay-operator"; WEBDIR="$ROOT/web"
. "$ROOT/lib-operator-env.sh"

echo "── operator: env + redeploy ──"
( cd "$OPVDIR"
  vercel env rm COLLATERAL_REGISTRY production --yes >/dev/null 2>&1; vercel env add COLLATERAL_REGISTRY production --force < "$HERE/registry.json" >/dev/null 2>&1
  vercel env rm FAUCET_MINTS production --yes >/dev/null 2>&1;        vercel env add FAUCET_MINTS production --force < "$HERE/faucet.json" >/dev/null 2>&1 )
# POOL_ID/STABLE_TYPE via the shared helper — one definition, used by deploy.sh too
provision_operator_env "$WEBDIR" "$OPVDIR" || { echo "❌ operator env provisioning failed"; exit 1; }
# re-bundle (picks up any server code changes) + deploy
( cd "$OPDIR" && ./node_modules/.bin/esbuild server-sui.mjs --bundle --platform=node --format=esm --target=node20 \
    --outfile=assay-operator/api/index.mjs --log-level=warning \
    --banner:js="import { createRequire as __cr } from 'module'; import { fileURLToPath as __fp } from 'url'; import { dirname as __dn } from 'path'; const require = __cr(import.meta.url); const __filename = __fp(import.meta.url); const __dirname = __dn(__filename);" >/dev/null 2>&1 )
( cd "$OPVDIR" && vercel deploy --prod --yes 2>&1 | grep -oE "https://assay-operator-[a-z0-9-]+\.vercel\.app" | head -1 > /tmp/dm-op )
( cd "$OPVDIR" && vercel alias set "$(cat /tmp/dm-op)" assay-operator-sui.vercel.app >/dev/null 2>&1 ) || { echo "❌ operator alias set failed"; exit 1; }
echo "  operator → https://assay-operator-sui.vercel.app"

echo "── web: rebuild + redeploy ──"
( cd "$WEBDIR" && npx vite build >/dev/null 2>&1 && printf '%s' '{ "rewrites": [{ "source": "/((?!assets/|favicon).*)", "destination": "/index.html" }] }' > dist/vercel.json )
( cd "$WEBDIR/dist" && vercel deploy --prod --yes 2>&1 | grep -oE "https://[a-z0-9-]+\.vercel\.app" | tail -1 > /tmp/dm-web )
( cd "$WEBDIR/dist" && vercel alias set "$(cat /tmp/dm-web)" assay-sui.vercel.app >/dev/null 2>&1 ) && echo "  web → https://assay-sui.vercel.app"

# FAIL on a bad status (audit R3): this previously piped a 500 body into python and swallowed the
# error, printing "✅ live. markets: " with an empty count and exiting 0.
smoke_check "operator /health" "https://assay-operator-sui.vercel.app/health" || { echo "❌ operator smoke check failed"; exit 1; }
MARKETS=$(curl -s --max-time 20 https://assay-operator-sui.vercel.app/health | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["markets"]))' 2>/dev/null)
[ -z "$MARKETS" ] && { echo "❌ /health returned no market list"; exit 1; }
echo; echo "✅ live. markets: $MARKETS"
