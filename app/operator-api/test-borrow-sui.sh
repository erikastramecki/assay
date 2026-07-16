#!/usr/bin/env bash
# Boot the Sui Operator API + run the attestation → on-chain disburse integration test.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LENDING=0xc0083f1ce9b44beaddd46b10f25cabbf3f96dc9069f58d775103a66548899bab
COINS=0x537ba694cf26744a208ac69001a2102f12258e2999834ed8ea0b0cc941667d1f
CAP_USDC=0x6ac4c50740c98fc78057c62efb00bc96ca7e0201f7c854f5d86bb906cafe6446
CAP_SSPX=0x5fe17ffa2c469bb2432bba37e2bcc1a02e633b54ef9b491271abe76ed89cf12c
BTC_FEED=0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43

echo "pre-build dregg_borrow…"
( cd "$HOME/Developer/dregg-lab/dregg" && cargo build -q -p dregg-sdk --example dregg_borrow 2>/dev/null )

# SSPX priced off the 24/7 BTC feed so the loan authorizes regardless of US market hours
REG=$(python3 -c "import json;print(json.dumps({'$COINS::sspx::SSPX':{'feedId':'$BTC_FEED','ltvBps':4000,'decimals':8}}))")
pkill -f server-sui.mjs 2>/dev/null; sleep 1
( cd "$HERE" && COLLATERAL_REGISTRY="$REG" PORT=8788 node --import tsx server-sui.mjs >/tmp/op-sui.log 2>&1 & )
for i in $(seq 1 20); do curl -s http://127.0.0.1:8788/health >/dev/null 2>&1 && break; sleep 1; done
curl -s http://127.0.0.1:8788/health; echo

export SUI_PRIVKEY=$(sui keytool export --key-identity "$(sui client active-address)" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['exportedPrivateKey'])")
LENDING=$LENDING COINS=$COINS CAP_USDC=$CAP_USDC CAP_SSPX=$CAP_SSPX API_URL=http://127.0.0.1:8788 \
  node --import tsx "$HERE/test-borrow-sui.mjs" 2>&1 | grep -vE "ExperimentalWarning|--import|node:internal"
RC=${PIPESTATUS[0]}
unset SUI_PRIVKEY
pkill -f server-sui.mjs 2>/dev/null
exit $RC