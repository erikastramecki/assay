# Assay — system architecture (V1 MVP)

Assay is a **provably-safe RWA lending market**: borrow USDC against tokenized stocks
(xStocks), where every borrow is authorized in-kernel by dregg and (eventually) settled
against a zk proof. This doc maps the tiers, who signs what, and what's built vs. to-build.

## The four tiers

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. FRONTEND  (Assay web app — the thing users see)                    │
│    wallet connect · markets · borrow/repay · supply/withdraw · positions │
└───────────────┬───────────────────────────────┬───────────────────────┘
                │ direct-signed txs             │ borrow / liquidate
                │ (deposit/withdraw/repay)      │ (needs dregg authorization)
                ▼                               ▼
┌───────────────────────────┐      ┌────────────────────────────────────┐
│ 3. SOLANA PROGRAM          │◀─────│ 2. OPERATOR API  (Node service)     │
│    dregg_lending_async     │ co-  │    runs dregg_borrow (kernel LTV/   │
│    8 instructions          │ sign │    oracle authorize) + co-signs      │
│    (deposit/borrow/…)      │      │    disburse; runs the keeper         │
└───────────┬────────────────┘      └──────────────┬─────────────────────┘
            │ reads price                          │ fetches price
            ▼                                       ▼
┌───────────────────────────┐      ┌────────────────────────────────────┐
│ (on-chain state)           │      │ 4. PYTH ORACLE (Hermes REST)        │
│  Config · Pool · Positions │      │    live TSLAx/NVDAx/… equity prices │
└───────────────────────────┘      └────────────────────────────────────┘
```

## Who signs what (the key design fact)

| Action | Signers | Path | Why |
|--------|---------|------|-----|
| **Deposit** (supply USDC) | lender | **direct from wallet** | no risk decision — just adds cash |
| **Withdraw** | lender | **direct from wallet** | proportional claim, program-checked |
| **Repay** | borrower | **direct from wallet** | pays debt, program-checked |
| **Borrow** (disburse) | **operator + borrower** | **via Operator API** | dregg must authorize LTV/oracle BEFORE money moves |
| **Liquidate** | operator + liquidator | keeper (Operator API) | dregg authorizes "underwater"; not user-facing |
| **Settle batch** | anyone (permissionless) | operator/cron | proof-gated batch finalize |

**The one thing that forces a backend:** a borrow can't be pure client-side — the dregg
kernel authorization (`dregg_borrow`, a Rust program) runs off-chain and the **operator
co-signs** the disburse. Everything else the user's wallet signs directly. So the V1 MVP is
frontend + a thin operator API, not a pure dapp.

## What's built today (backend, all tested on localnet)

- **Solana program `programs/dregg_lending_async`** — 8 instructions:
  `0 init_config · 1 disburse · 2 settle_batch · 3 init_pool · 4 deposit · 5 withdraw · 6 repay · 7 liquidate`.
  Token-2022 collateral leg (real xStocks), borrow-index interest, exposure cap, proof-gated settle.
- **Oracle** — `operator/pyth.mjs`: Hermes fetch + fail-closed policy (conservative price,
  staleness tighter off-hours, confidence ceiling, circuit breaker). `operator/assets.mjs`:
  the TSLAx registry (real mint + real Pyth feed).
- **Operator logic** — `operator/operator-service.mjs` (dregg authorize → disburse),
  `operator/keeper.mjs` (liquidation). These are scripts today, not yet an HTTP API.
- **Instruction builders** — currently inline in the localnet test `.mjs` files
  (`tests/localnet/*.mjs`) + `mainnet-demo/borrow-demo.mjs`. To be extracted into a shared TS SDK.
- **Sui twin** — `move/dregg_lending_async` (same model, `sui move test` green).

## What's NOT built (the V1 MVP gap)

- **The web app** — no frontend exists; Assay is a static HTML mockup (Artifact).
- **The Operator API** — the borrow/keeper logic is scripts, not an HTTP service.
- **A TS client SDK** — instruction builders are copy-pasted in test files, not a reusable lib.
- **A positions/dashboard view** — not in the current design; needed so a borrower can see + manage loans.
- **Devnet deployment + a funded pool** — flows run on localnet; need a persistent devnet deploy.

See `V1-MVP-PLAN.md` for the phased build and `COMPONENT-MAP.md` for every UI element's wiring.
