#!/usr/bin/env bash
# Live on-chain Sui lending loop (devnet) — the Sui-native twin of the Solana "3 loans"
# evidence. init_pool -> deposit -> disburse (operator) -> repay, all real txs on devnet.
# Reuses the sui CLI's active address for signing. Prints every tx digest.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # repo root (portable)

CLOCK=0x6
LENDING=${LENDING:-0xf05ad39908244ae7312a7fea808ec527e42b63b0c0cc2d39679ed1ce1d777a22}
COINS=${COINS:-0x537ba694cf26744a208ac69001a2102f12258e2999834ed8ea0b0cc941667d1f}
CAP_USDC=${CAP_USDC:-0x6ac4c50740c98fc78057c62efb00bc96ca7e0201f7c854f5d86bb906cafe6446}
CAP_SSPX=${CAP_SSPX:-0x5fe17ffa2c469bb2432bba37e2bcc1a02e633b54ef9b491271abe76ed89cf12c}
TUSDC="$COINS::tusdc::TUSDC"
SSPX="$COINS::sspx::SSPX"
ME=$(sui client active-address)
VK=$(grep -E '^VK_HEX=' "$ROOT/perloan-prep/proof_A_sui_hex.txt" | cut -d= -f2)

DEPOSIT=1000000000     # 1000 TUSDC (6 dec) LP deposit
COLLAMT=10000000000    # 100 SSPX  (8 dec) collateral
DEBT=500000000         # 500 TUSDC borrow (rate=0 -> owed == principal, deterministic repay)
COMMIT=999             # loan_commit (u256), folded into the batch accumulator

echo "signer: $ME  |  lending: ${LENDING:0:10}…  |  coins: ${COINS:0:10}…"

# helper: run a call, print digest, save json
call() { # $1=label  $rest=sui client call args
  local label="$1"; shift
  sui client call "$@" --gas-budget 200000000 --json 2>/tmp/sui-step-err.log >/tmp/sui-step.json
  local rc=$?
  if [ $rc -ne 0 ]; then echo "❌ $label FAILED"; tail -4 /tmp/sui-step-err.log; return 1; fi
  python3 -c "import json;d=json.load(open('/tmp/sui-step.json'));print('✅ $label  tx',d.get('digest'),' ',d.get('effects',{}).get('status',{}).get('status'))"
}
# extract a created object id whose type contains $1 from the last step json
obj() { python3 -c "
import json;d=json.load(open('/tmp/sui-step.json'))
for c in d.get('objectChanges',[]):
  if c.get('type')=='created' and '$1' in str(c.get('objectType','')): print(c['objectId']); break
"; }

echo; echo "── 1. mint test coins ──"
call "mint 1000 TUSDC (deposit)" --package "$COINS" --module tusdc --function mint --args "$CAP_USDC" "$DEPOSIT" "$ME" || exit 1
DEP_COIN=$(obj "coin::Coin<$COINS::tusdc::TUSDC>"); [ -z "$DEP_COIN" ] && DEP_COIN=$(obj "tusdc::TUSDC")
echo "   deposit coin: $DEP_COIN"
call "mint 100 SSPX (collateral)" --package "$COINS" --module sspx --function mint --args "$CAP_SSPX" "$COLLAMT" "$ME" || exit 1
COLL_COIN=$(obj "sspx::SSPX"); echo "   collateral coin: $COLL_COIN"

echo; echo "── 2. init_pool<TUSDC> (zero rate curve, share Pool + mint OperatorCap) ──"
# args: base slope1 slope2 kink reserve cap vk operator_pubkey clock (cap-path loop → pubkey unused)
DUMMY_PK=d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a
call "init_pool" --package "$LENDING" --module async_lending --function init_pool \
  --type-args "$TUSDC" --args 0 0 0 8000 0 1000000000000 "0x$VK" "0x$DUMMY_PK" "$CLOCK" || exit 1
POOL=$(obj "async_lending::Pool"); OPCAP=$(obj "async_lending::OperatorCap")
echo "   pool: $POOL"; echo "   operator cap: $OPCAP"

echo; echo "── 3. deposit 1000 TUSDC into the pool ──"
call "deposit" --package "$LENDING" --module async_lending --function deposit \
  --type-args "$TUSDC" --args "$POOL" "$DEP_COIN" "$CLOCK" || exit 1

echo; echo "── 4. disburse_entry<SSPX,TUSDC>: operator lends 500 TUSDC vs 100 SSPX ──"
call "disburse" --package "$LENDING" --module async_lending --function disburse_entry \
  --type-args "$SSPX" "$TUSDC" \
  --args "$OPCAP" "$POOL" "$COLL_COIN" "$DEBT" "$ME" "$COMMIT" "$CLOCK" || exit 1
POSITION=$(obj "async_lending::Position")
LOAN_COIN=$(obj "coin::Coin<$COINS::tusdc::TUSDC>"); [ -z "$LOAN_COIN" ] && LOAN_COIN=$(obj "tusdc::TUSDC")
echo "   position: $POSITION"; echo "   loan coin (500 TUSDC to borrower): $LOAN_COIN"

echo; echo "── 5. repay 500 TUSDC → reclaim collateral, close position ──"
# repay is a public fun returning Coin<Collateral>; a PTB must transfer the result
# (plain `sui client call` leaves it as UnusedValueWithoutDrop). Call + transfer here.
sui client ptb \
  --move-call "$LENDING::async_lending::repay" "<$SSPX,$TUSDC>" @$POOL @$POSITION @$LOAN_COIN @$CLOCK \
  --assign coll \
  --transfer-objects "[coll]" @$ME \
  --gas-budget 200000000 --json 2>/tmp/sui-step-err.log >/tmp/sui-step.json \
  && python3 -c "import json;d=json.load(open('/tmp/sui-step.json'));print('✅ repay  tx',d.get('digest'),' ',d.get('effects',{}).get('status',{}).get('status'))" \
  || { echo '❌ repay FAILED'; tail -4 /tmp/sui-step-err.log; exit 1; }
RET_COLL=$(obj "sspx::SSPX")
echo "   collateral returned to borrower: $RET_COLL"

echo; echo "════════ SUI LENDING LOOP COMPLETE ON DEVNET ════════"
echo "pool $POOL"
echo "position (now deleted) $POSITION"