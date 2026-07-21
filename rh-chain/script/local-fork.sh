#!/usr/bin/env bash
# Zero-cost local rig: fork Robinhood Chain mainnet, deploy Assay, drive it to a borrowable state.
#
# Real AAPL Stock Token, real USDG, real mainnet prices, anvil's prefunded keys. No wallet, no gas,
# no testnet — Robinhood Chain testnet has none of these tokens deployed, so mocking all three
# there would prove less than this does.
#
#   bash script/local-fork.sh          # then follow the printed MCP command
set -uo pipefail
RPC=http://127.0.0.1:8545
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil account 0
MAINNET=https://rpc.mainnet.chain.robinhood.com
AAPL=0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9
AAPL_FEED=0x6B22A786bAa607d76728168703a39Ea9C99f2cD0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

rpc() { curl -s -X POST $RPC -H 'content-type: application/json' --data "$1" >/dev/null; }
warp() { rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_increaseTime\",\"params\":[$1]}"; rpc '{"jsonrpc":"2.0","id":1,"method":"evm_mine","params":[]}'; }
beat() { cast send "$LV" "heartbeat()" --rpc-url $RPC --private-key $PK >/dev/null 2>&1; }

if ! curl -s --max-time 3 -X POST $RPC -H 'content-type: application/json' \
     --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null 2>&1; then
  echo "starting anvil (fork of Robinhood Chain mainnet)…"
  nohup anvil --fork-url $MAINNET --chain-id 4663 --port 8545 --silent >/tmp/anvil.log 2>&1 &
  sleep 12
fi

echo "── deploy ──"
OUT=$(FOUNDRY_PROFILE=script forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $PK 2>&1)
LV=$(echo "$OUT" | grep -oE "liveness   0x[a-fA-F0-9]{40}" | awk '{print $2}')
MK=$(echo "$OUT" | grep -oE "markets    0x[a-fA-F0-9]{40}" | awk '{print $2}')
PL=$(echo "$OUT" | grep -oE "pool       0x[a-fA-F0-9]{40}" | awk '{print $2}')
[ -z "$PL" ] && { echo "deploy failed"; echo "$OUT" | tail -20; exit 1; }

# Forking pins the real feed's updatedAt at fork height, and the 2-day timelock forces the clock
# past it — so the genuine feed always reads stale here. This mock reports the REAL mainnet price
# at the CURRENT block time; only the timestamp is synthetic, and it is fork-only.
PRICE=$(cast call $AAPL_FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $MAINNET 2>/dev/null | sed -n 2p | awk '{print $1}')
FEED=$(forge create test/mocks/AlwaysFreshFeed.sol:AlwaysFreshFeed --rpc-url $RPC --private-key $PK \
  --broadcast --constructor-args "$PRICE" 2>/dev/null | grep -oE "Deployed to: 0x[a-fA-F0-9]+" | awk '{print $3}')
echo "   real AAPL price $PRICE -> fork feed $FEED"

cast send $MK "proposeMarket(address,address,uint32,uint8,(bool,uint16,uint16,uint16,uint8,uint128))" \
  $AAPL $FEED 90000 8 "(true,3500,5500,800,18,10000000000)" --rpc-url $RPC --private-key $PK >/dev/null 2>&1

echo "── 2-day timelock ──"
warp 172801
cast send $MK "commitMarket(address)" $AAPL --rpc-url $RPC --private-key $PK >/dev/null 2>&1

echo "── jump to a session open ──"
NOW=$(cast block latest --rpc-url $RPC 2>/dev/null | grep -E "^timestamp" | awk '{print $2}')
TARGET=$(python3 -c "
d=$NOW//86400
for i in range(1,10):
    day=d+i
    if (day+3)%7 < 5: print(day*86400+14*3600+35*60); break")
rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"evm_setNextBlockTimestamp\",\"params\":[$TARGET]}"
rpc '{"jsonrpc":"2.0","id":1,"method":"evm_mine","params":[]}'

# Liveness must be established INSIDE the session, in steps under the 600s gap threshold —
# a larger jump reads as an outage and re-arms the grace period.
echo "── keeper beats through the grace period ──"
for _ in $(seq 1 16); do warp 300; beat; done

echo
echo "canBorrow: $(cast call $MK 'canBorrow(address)(bool)' $AAPL --rpc-url $RPC 2>/dev/null)"
echo "liveness:  $(cast call $LV 'liquidationsAllowed()(bool)' --rpc-url $RPC 2>/dev/null)"
echo
echo "Drive it from an agent:"
echo "  ASSAY_CHAIN=local-fork ASSAY_POOL=$PL ASSAY_MARKETS=$MK node ../mcp/assay-mcp.mjs"
