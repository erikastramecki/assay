#!/usr/bin/env bash
# Bring up the full Assay SUI stack on devnet: init a seeded pool pinned to the operator key,
# start the Sui Operator API (attestation + /quote + /faucet), and write app/web/.env.local so
# `cd app/web && npm run dev` is clickable end-to-end (Supply/Borrow/Repay/Withdraw).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
LENDING=${LENDING:-0xc0083f1ce9b44beaddd46b10f25cabbf3f96dc9069f58d775103a66548899bab}
COINS=${COINS:-0x537ba694cf26744a208ac69001a2102f12258e2999834ed8ea0b0cc941667d1f}
CAP_USDC=${CAP_USDC:-0x6ac4c50740c98fc78057c62efb00bc96ca7e0201f7c854f5d86bb906cafe6446}
CAP_SSPX=${CAP_SSPX:-0x5fe17ffa2c469bb2432bba37e2bcc1a02e633b54ef9b491271abe76ed89cf12c}
BTC_FEED=0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
SSPX_TYPE="$COINS::sspx::SSPX"; TUSDC_TYPE="$COINS::tusdc::TUSDC"

echo "pre-build dregg_borrow…"; ( cd "$HOME/Developer/dregg-lab/dregg" && cargo build -q -p dregg-sdk --example dregg_borrow 2>/dev/null )

export SUI_PRIVKEY=$(sui keytool export --key-identity "$(sui client active-address)" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['exportedPrivateKey'])")
echo "on-chain setup (init pool, seed, hand faucet caps to operator)…"
SETUP=$(cd "$ROOT/sui-sdk" && LENDING=$LENDING COINS=$COINS CAP_USDC=$CAP_USDC CAP_SSPX=$CAP_SSPX \
  node --import tsx scripts/setup-sui.mjs 2>/tmp/setup-sui.log)
echo "$(cat /tmp/setup-sui.log)"
POOL=$(echo "$SETUP" | python3 -c "import sys,json;print(json.load(sys.stdin)['pool'])")
OP_ADDR=$(echo "$SETUP" | python3 -c "import sys,json;print(json.load(sys.stdin)['operatorAddress'])")
[ -z "$POOL" ] && { echo "setup failed"; exit 1; }
echo "pool: $POOL"

# registry + faucet for ALL markets, from the shared markets.json (operator holds the caps)
python3 - "$HERE/markets.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); pkg = d["marketsPkg"]
reg = {}; fau = [{"target": d["stable"]["target"], "cap": d["stable"]["cap"], "amount": d["stable"]["faucetAmount"]}]
for m in d["markets"]:
    ct = f'{pkg}::{m["module"]}::{m["struct"]}'
    reg[ct] = {"feedId": m["feedId"], "ltvBps": m["ltvBps"], "decimals": m["decimals"], "assetClass": m["assetClass"]}
    fau.append({"target": f'{pkg}::{m["module"]}::mint', "cap": m["cap"], "amount": m["faucetAmount"]})
open("/tmp/dev-reg.json", "w").write(json.dumps(reg)); open("/tmp/dev-fau.json", "w").write(json.dumps(fau))
PY
REG=$(cat /tmp/dev-reg.json); FAU=$(cat /tmp/dev-fau.json)
MPKG=$(python3 -c "import json;print(json.load(open('$HERE/markets.json'))['marketsPkg'])")
pkill -f server-sui.mjs 2>/dev/null; sleep 1
( cd "$ROOT/operator-api" && COLLATERAL_REGISTRY="$REG" FAUCET_MINTS="$FAU" PORT=8788 SUI_NETWORK=devnet \
  POOL_ID="$POOL" STABLE_TYPE="$TUSDC_TYPE" \
  node --import tsx server-sui.mjs >/tmp/op-sui.log 2>&1 & )
for i in $(seq 1 20); do curl -s http://127.0.0.1:8788/health >/dev/null 2>&1 && break; sleep 1; done
echo "operator API: $(curl -s http://127.0.0.1:8788/health)"

cat > "$ROOT/web/.env.local" <<EOF
VITE_SUI_NETWORK=devnet
VITE_PKG=$LENDING
VITE_POOL=$POOL
VITE_STABLE_TYPE=$TUSDC_TYPE
VITE_STABLE_DECIMALS=6
VITE_MARKETS_PKG=$MPKG
VITE_OPERATOR_API=http://127.0.0.1:8788
EOF
unset SUI_PRIVKEY
echo "wrote web/.env.local"
echo; echo "✅ stack up. Now:  cd app/web && npm run dev  → http://localhost:5173"
echo "   (get test coins: POST http://127.0.0.1:8788/faucet {\"address\":\"<your wallet>\"})"