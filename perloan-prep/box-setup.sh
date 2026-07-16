#!/usr/bin/env bash
# On-box setup for the per-loan proof run. Run this ON a fresh CCX33 (ubuntu-24.04)
# after first SSH connect. Automates everything that was manual last time.
# AFTER this: from the Mac, rsync the vanilla gnark:
#   rsync -az /tmp/gnark-tip/chain/gnark/ root@<IP>:/root/dregg/chain/gnark/
# then apply the v4 port (see RUNBOOK.md) and run the emit/prove.
set -euo pipefail

echo "=== swap (64G) ==="
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 64G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile
fi
free -h | awk '/Swap/{print "swap:", $2}'

echo "=== toolchain ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq build-essential git curl pkg-config libssl-dev >/dev/null 2>&1
[ -x "$HOME/.cargo/bin/rustc" ] || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null 2>&1
source "$HOME/.cargo/env"
[ -x /usr/local/go/bin/go ] || curl -sSL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz | tar -C /usr/local -xz
export PATH="$PATH:/usr/local/go/bin"
echo "rust: $(rustc --version)"; echo "go: $(go version)"

echo "=== clone dregg (fork main = the BUILDING v1 emitter) ==="
cd /root
[ -d dregg/circuit-prove ] || git clone --depth 1 -b main https://github.com/erikastramecki/dregg.git dregg
echo "dregg HEAD: $(cd dregg && git rev-parse --short HEAD)  (expect 8ef3294 or later fork main)"

echo "=== clone plonky3-recursion @ be52a51 (pairs with the fork emitter) ==="
[ -d plonky3-recursion/circuit ] || { git clone https://github.com/emberian/plonky3-recursion.git plonky3-recursion && (cd plonky3-recursion && git checkout be52a51); }
echo "plonky3 HEAD: $(cd plonky3-recursion && git rev-parse --short HEAD)  (expect be52a51)"

echo
echo "NEXT (from the Mac): rsync -az /tmp/gnark-tip/chain/gnark/ root@<IP>:/root/dregg/chain/gnark/"
echo "THEN: apply the v4 port (RUNBOOK.md §port) + the_chain loan edit, then:"
echo "  cd /root/dregg && cargo test -p dregg-circuit-prove --release --test apex_shrink_gnark_fixture --no-run"
