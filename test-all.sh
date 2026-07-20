#!/usr/bin/env bash
# Run every suite in the Sui stack — one green/red line per capability. ~1 min, no validator needed.
#   ./test-all.sh
#
# (This replaced a Solana-era script that built programs/dregg_lending_async with cargo-build-sbf
# and needed solana-test-validator. That directory does not exist in this repo; the script could
# not run at all, while docs pointed at it as the primary way to verify the project.)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
green() { printf "\033[32m✔ %s\033[0m\n" "$1"; pass=$((pass+1)); }
red()   { printf "\033[31mx %s\033[0m\n" "$1"; fail=$((fail+1)); }

command -v sui >/dev/null 2>&1 || { echo "sui CLI not on PATH"; exit 1; }

echo "== Move packages =="
for d in "$ROOT"/move/*/; do
  [ -d "$d/sources" ] || continue
  name=$(basename "$d")
  out=$( cd "$d" && sui move test --build-env testnet 2>&1 | grep -E "^Test result" )
  case "$out" in
    *"OK"*) green "$name — ${out#Test result: }" ;;
    *)      red   "$name — ${out:-build failed}" ;;
  esac
done

echo "== SDK unit tests =="
if ( cd "$ROOT/app/sui-sdk" && npx tsx test/unit.mjs >/tmp/assay-sdk.log 2>&1 ); then
  green "sui-sdk — $(grep -oE '[0-9]+ passed' /tmp/assay-sdk.log | tail -1)"
else red "sui-sdk unit tests (see /tmp/assay-sdk.log)"; fi

echo "== web typecheck =="
if ( cd "$ROOT/app/web" && npx tsc --noEmit >/tmp/assay-web.log 2>&1 ); then
  green "web tsc --noEmit"
else red "web typecheck (see /tmp/assay-web.log)"; fi

echo "== shell syntax =="
sh_ok=1
for f in "$ROOT"/app/deploy.sh "$ROOT"/app/lib-operator-env.sh "$ROOT"/app/sui-harness/*.sh "$ROOT"/app/operator-api/*.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" 2>/dev/null || { red "syntax: ${f#$ROOT/}"; sh_ok=0; }
done
[ "$sh_ok" = 1 ] && green "all deploy/harness scripts parse"

echo
echo "$pass passed, $fail failed"
# Live devnet flows (need SUI_PRIVKEY + a deployed package) are not run here:
#   app/sui-sdk/test/pentest-sui.mjs   — attack suite, every case must be BLOCKED
#   app/operator-api/test-borrow-sui.sh — operator attestation -> on-chain disburse
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
