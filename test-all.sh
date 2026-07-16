#!/usr/bin/env bash
# See what actually works: spin up a local validator, deploy the program fresh, and run
# every flow — one green/red line per capability. ~3–5 min.
#   ./test-all.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SBIN="$HOME/.local/share/solana/install/active_release/bin"
export PATH="$SBIN:$PATH"
LEDGER="/tmp/assay-testall"
PROG_SO="$ROOT/programs/dregg_lending_async/target/deploy/dregg_lending_async.so"
pass=0; fail=0
green() { printf "\033[32m✔ %s\033[0m\n" "$1"; pass=$((pass+1)); }
red()   { printf "\033[31mx %s\033[0m\n" "$1"; fail=$((fail+1)); }

command -v solana-test-validator >/dev/null 2>&1 || { echo "solana-test-validator not on PATH ($SBIN)"; exit 1; }

echo "== build program =="
( cd "$ROOT/programs/dregg_lending_async" && cargo-build-sbf --arch v3 >/tmp/assay-build.log 2>&1 ) \
  && green "program builds" || { red "program build failed (see /tmp/assay-build.log)"; exit 1; }

echo "== live oracle (no validator) =="
if ( cd "$ROOT/operator" && node rwa-real-e2e.mjs 2>/dev/null | grep -q "REAL oracle"; ); then
  green "live Pyth → dregg kernel decisions (TSLAx)"
else red "live oracle e2e"; fi

echo "== start validator =="
pkill -f solana-test-validator 2>/dev/null; sleep 1; rm -rf "$LEDGER"
solana-test-validator -q --reset --ledger "$LEDGER" >/tmp/assay-val.log 2>&1 &
VAL=$!; sleep 8
solana config set --url http://127.0.0.1:8899 >/dev/null 2>&1
solana airdrop 100 >/dev/null 2>&1 || true

deploy_fresh() { # → prints a fresh program id
  local kp; kp="$(mktemp -u)"
  solana-keygen new --no-bip39-passphrase -s -o "$kp" --force >/dev/null 2>&1
  solana airdrop 100 >/dev/null 2>&1 || true
  solana program deploy "$PROG_SO" --program-id "$kp" --output json 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['programId'])"
}

run_flow() { # name  script  pass-marker
  local name="$1" script="$2" marker="$3" prog
  prog="$(deploy_fresh)"
  if ( cd "$ROOT/tests/localnet" && node "$script" "$prog" 2>/dev/null | grep -q "$marker"; ); then
    green "$name"; else red "$name"; fi
}

echo "== on-chain flows =="
run_flow "lender pool + interest (Token-2022 collateral)" pool_flow.mjs      "POOL FLOW PASS"
run_flow "async batch + settle + guards"                  async_flow.mjs     "ASYNC FLOW PASS"
run_flow "liquidation + keeper"                           liquidate_flow.mjs "LIQUIDATION FLOW PASS"

echo "== teardown =="
kill -9 "$VAL" 2>/dev/null; pkill -f solana-test-validator 2>/dev/null; rm -rf "$LEDGER"

echo
echo "==================  $pass passed · $fail failed  =================="
[ "$fail" -eq 0 ] && echo "everything that's built works. UI is the next build (docs/V1-MVP-PLAN.md)." || echo "see /tmp/assay-*.log"
exit "$fail"
