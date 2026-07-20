# What actually works today — and how to test it

The **backend is real and tested**; the **web UI is not built yet** (Assay is a static
mockup). Here's exactly what runs, and one command to see it all go green.

## The one command
```
./test-all.sh
```
It spins up a local Solana validator, deploys the program fresh, and runs every flow,
printing a green/red line per capability. ~3–5 min. (Needs: the Solana CLI + `cargo-build-sbf`,
Node, and `npm i` already run in `tests/localnet/`.)

## What each flow proves (all currently GREEN on localnet)

| Flow | Script | What it proves |
|------|--------|----------------|
| **Lender pool + interest** | `tests/localnet/pool_flow.mjs` | deposit 1000 → borrow 500 (**real Token-2022 collateral**, like TSLAx) → interest accrues → repay 523.78 → withdraw → LP earns the exact interest. Conservation holds. |
| **Async batch + guards** | `tests/localnet/async_flow.mjs` | operator disburses instantly (PENDING) → batch proof settles (PROVEN); init-authority, operator-gate, exposure-cap, proof-reconcile guards all reject. |
| **Liquidation + keeper** | `tests/localnet/liquidate_flow.mjs` | healthy position SKIPPED; price drops → underwater → liquidated on a PENDING position; collateral seized; operator-gated. |
| **Live oracle → kernel** | `operator/rwa-real-e2e.mjs` | **LIVE Pyth TSLAx price** → dregg authorizes a 40%-LTV borrow / refuses over-LTV / triggers liquidation on a gap-down. (No validator needed — real network price.) |
| **Real-token verify** | `operator/rwa-real-e2e.mjs --clone` | forks the **real TSLAx mint** from mainnet, confirms Token-2022 + decimals + permanent-delegate. |
| **Mainnet borrow (staged)** | `mainnet-demo/borrow-demo.mjs` | the real headline borrow, config-flip to mainnet; localnet-validated against a Token-2022 fixture. |

## Test it piece by piece

**No validator needed (real network):**
```
cd operator && node rwa-real-e2e.mjs          # live TSLAx price → real kernel decisions
```

**Needs a local validator (the on-chain flows):**
```
# terminal 1
solana-test-validator -q --reset
# terminal 2 — deploy once, then run any flow with the program id
cd programs/dregg_lending_async && cargo-build-sbf --arch v3
PROG=$(solana program deploy target/deploy/dregg_lending_async.so --output json | jq -r .programId)
cd ../../tests/localnet
node pool_flow.mjs      "$PROG"
node async_flow.mjs     "$PROG"   # (fresh program id each — re-deploy between runs)
node liquidate_flow.mjs "$PROG"
```
(`test-all.sh` runs every Move package, the SDK unit tests, the web typecheck and shell syntax. Live devnet flows — the pentest suite and the operator borrow path — need SUI_PRIVKEY and a deployed package, and are listed at the bottom of that script.)

## What you CANNOT test yet (because it isn't built)
- Clicking anything in a real Assay web app — **no frontend exists** (the Artifact is a mockup).
- A borrow from a browser wallet — needs the **Operator API** (not built).
- Devnet — flows run on **localnet**; no persistent devnet deploy yet.

## The honest status line
> The money engine works and is tested end-to-end on localnet, against real Token-2022
> collateral and a live Pyth price. The product (a web app you click) is the next build —
> see `V1-MVP-PLAN.md`.
