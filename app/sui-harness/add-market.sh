#!/usr/bin/env bash
# Add new markets WITHOUT touching existing coin packages. Generates + publishes a SMALL new coin
# package (one coin per new market), transfers the mint caps to the operator, appends the markets
# to markets.json (each self-contained with its own pkg/coinType/cap), and regenerates all configs.
# Then run:  bash deploy-markets.sh   to push them live.
#
# Usage:  bash add-market.sh <spec.json>
#   spec.json = [ { "sym":"AVAX", "name":"Avalanche", "decimals":8, "assetClass":"crypto",
#                   "ltvBps":5000, "feedId":"0x…", "faucetAmount":"10000000000", "gap":false }, … ]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"; MOVE="$(cd "$ROOT/../move" && pwd)"
OPERATOR=0x438e70af0318316c75fea50950489fb6dcd2bc9a7d76df08eaa5ff254605671a
SPEC="${1:?usage: add-market.sh <spec.json>}"
STAMP=$(date +%s); PKGNAME="assay_ext_$STAMP"; PKGDIR="$MOVE/$PKGNAME"
mkdir -p "$PKGDIR/sources"
cat > "$PKGDIR/Move.toml" <<EOF
[package]
name = "$PKGNAME"
edition = "2024.beta"
[addresses]
$PKGNAME = "0x0"
EOF

# generate one Move coin module per spec entry
python3 - "$SPEC" "$PKGDIR" "$PKGNAME" <<'PY'
import json, sys
spec, pkgdir, pkgname = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
for m in spec:
    sym=m["sym"]; mod="t"+sym.lower(); st="T"+sym.upper(); dec=m.get("decimals",8); nm=m.get("name",sym)
    open(f"{pkgdir}/sources/{mod}.move","w").write(f'''/// Test collateral coin for the Assay {sym} market (devnet demo; mintable via TreasuryCap).
module {pkgname}::{mod} {{
    use sui::coin::{{Self, TreasuryCap}};
    public struct {st} has drop {{}}
    fun init(w: {st}, ctx: &mut TxContext) {{
        let (t, mt) = coin::create_currency(w, {dec}, b"t{sym}", b"{nm}", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(mt);
        transfer::public_transfer(t, ctx.sender());
    }}
    public entry fun mint(cap: &mut TreasuryCap<{st}>, amount: u64, to: address, ctx: &mut TxContext) {{
        coin::mint_and_transfer(cap, amount, to, ctx);
    }}
}}
''')
print(f"generated {len(spec)} module(s)")
PY

echo "publishing $PKGNAME …"
( cd "$PKGDIR" && sui client test-publish --build-env devnet --pubfile-path "/tmp/$PKGNAME.toml" --gas-budget 500000000 --json 2>/tmp/ext-err.log > /tmp/ext-pub.json )
PKG=$(python3 -c "import json;d=json.load(open('/tmp/ext-pub.json'));print(next((c['packageId'] for c in d['objectChanges'] if c['type']=='published'),''))")
[ -z "$PKG" ] && { echo "publish failed:"; tail -6 /tmp/ext-err.log; exit 1; }
echo "published: $PKG"

# transfer the new caps to the operator, then append the markets + regenerate
CAPIDS=$(python3 -c "
import json
d=json.load(open('/tmp/ext-pub.json'))
caps=[c['objectId'] for c in d['objectChanges'] if c['type']=='created' and 'TreasuryCap' in str(c.get('objectType',''))]
print(','.join('@'+c for c in caps))
")
echo "transferring $(echo "$CAPIDS" | tr ',' '\n' | wc -l | tr -d ' ') cap(s) → operator …"
sui client ptb --transfer-objects "[$CAPIDS]" @$OPERATOR --gas-budget 30000000 --json 2>/tmp/ext-x.log | \
  python3 -c "import sys,json;print('  cap transfer', json.load(sys.stdin)['effects']['status']['status'])" || { tail -3 /tmp/ext-x.log; exit 1; }

python3 - "$SPEC" "$PKG" <<'PY'
import json, sys
spec, pkg = json.load(open(sys.argv[1])), sys.argv[2]
pub = json.load(open("/tmp/ext-pub.json"))
capByStruct = {c["objectType"].split("::")[-1].rstrip(">"): c["objectId"]
               for c in pub["objectChanges"] if c["type"]=="created" and "TreasuryCap" in str(c.get("objectType",""))}
mj = json.load(open("markets.json"))
have = {m["coinType"] for m in mj["markets"]}
added=0
for m in spec:
    sym=m["sym"]; mod="t"+sym.lower(); st="T"+sym.upper()
    ct=f"{pkg}::{mod}::{st}"
    if ct in have: continue
    ltv=m["ltvBps"]; liq=min(ltv+1200, 8500)
    mj["markets"].append({
        "sym":sym,"name":m.get("name",sym),"pkg":pkg,"module":mod,"struct":st,
        "coinType":ct,"mintTarget":f"{pkg}::{mod}::mint","cap":capByStruct[st],
        "decimals":m.get("decimals",8),"assetClass":m["assetClass"],"ltvBps":ltv,"liqBps":liq,
        "feedId":m["feedId"],"gap":m.get("gap", m["assetClass"]=="equity"),"faucetAmount":m.get("faucetAmount","10000000000"),
    }); added+=1
json.dump(mj, open("markets.json","w"), indent=1)
print(f"appended {added} market(s) to markets.json (total {len(mj['markets'])})")
PY

python3 "$HERE/gen-configs.py"
echo; echo "✅ markets added. Deploy them live:  bash $HERE/deploy-markets.sh"
