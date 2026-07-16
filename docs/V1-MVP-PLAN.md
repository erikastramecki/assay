# Assay V1 MVP — the functional build plan

Turn the static Assay design into a working app. Sequenced so each phase leaves something
you can click and demo. Cluster: **devnet** (deployable, no real funds; localnet for dev).
Stack: **Vite + React + TypeScript** frontend, **Solana wallet adapter**, a thin **Node
(Express) Operator API** for the dregg-authorized borrow. Everything reuses the tested
backend (`dregg_lending_async` + `pyth.mjs` + `assets.mjs`).

## Phase 0 — foundations (no UI yet)
- **Extract a TS client SDK** (`packages/sdk`): typed instruction builders for all 8
  instructions + PDA derivations + account decoders (PoolState, Position, LenderPosition).
  Today these are copy-pasted in `tests/localnet/*.mjs` — lift them into one lib the app + API + tests share.
- **Deploy to devnet** + one-time init (config, pool, USDC vault) + seed the pool with devnet USDC.
- **Wire the real markets we have**: TSLAx (mint + Pyth feed) confirmed; add NVDAx/AAPLx/SPYx feed ids to `assets.mjs` (mints from Solscan) so the table isn't hardcoded.

## Phase 1 — the shell + live data (read-only, no signing)
- Scaffold the Vite/React app; port the Assay HTML/CSS into components (keep the exact design).
- **Connect wallet** (wallet-adapter, Phantom). → unlocks balances.
- **Live Pyth** everywhere: ticker, markets table prices, market-hours pill — poll Hermes via
  the shared oracle policy. → the page stops being static.
- **Live pool stats**: read PoolState → KPIs, utilization, APY, available liquidity.
- Market-row click → opens the Borrow panel for that asset.
- *Milestone: the page shows real numbers and you can connect a wallet. Nothing signs yet.*

## Phase 2 — Earn (the simplest real money, wallet-signed)
- **Supply USDC** → `deposit` (instruction 4), wallet-signed. Refresh pool + "your share".
- **Withdraw** → `withdraw` (5). Supply/Withdraw toggle live.
- Transaction UX: pending → confirm → success/error toasts; block dismiss mid-sign; refresh after.
- *Milestone: a lender can supply and withdraw real (devnet) USDC and see yield accrue.*

## Phase 3 — Positions + Repay (close the borrower loop, wallet-signed)
- **Your positions** view (new — not in the mockup): read `Position` PDAs by borrower →
  collateral, live debt (principal · index/snapshot), health, liq price, **Repay**.
- **Repay** → `repay` (6), wallet-signed, releases Token-2022 collateral.
- *Milestone: a borrower can see and repay loans. (Borrows still done via the test harness.)*

## Phase 4 — Borrow (needs the Operator API)
- **Operator API** (`operator/api`): wrap `operator-service.mjs` as HTTP —
  `POST /quote` (live Pyth + kernel max-borrow) and `POST /borrow` (run `dregg_borrow`
  authorize → build + partially sign the `disburse` tx → return for the borrower to co-sign).
  Holds the operator keypair; never the user's.
- Frontend "Review & borrow" → `/quote` for the live health/terms → `/borrow` → user co-signs
  → submit. LTV slider + gauge now drive a real loan.
- *Milestone: end-to-end borrow against a real xStock from the browser. THE demo.*

## Phase 5 — polish + ship
- Keeper as a devnet cron (liquidation) using `keeper.mjs`.
- Empty/loading/error states, devnet faucet hints, disclaimers (permanent-delegate is already in the footer).
- Deploy: frontend on **Vercel**, Operator API on a small host (Railway/Fly). Wire `/docs` + GitHub links.
- *Milestone: a shareable devnet demo of the whole loop.*

## Scope guardrails for "V1 MVP"
- **One real collateral to start (TSLAx)** — the others can render "coming soon" until their
  mint+feed are wired. Don't fake six live markets.
- **Honest-operator trust model** (v1) — the trustless zk terms-binding is a separate track
  (see `cv-gateway/DESIGN-v2-terms-binding.md`); the UI's "proof-gated" story is accurate for
  the settlement path, and the v1 disclaimer should say the operator is trusted for authorization.
- **Devnet, tiny amounts.** Not a mainnet launch (securities-lending posture is unresolved —
  see `cv-gateway/RWA-real-token-findings.md`).

## Deferred to post-MVP (noted, not lost)
- **Add more markets** — cbBTC, SPYx/AAPLx/NVDAx, ETH/SOL, USDY. Fully scoped with verified
  feeds in `docs/MARKETS-EXPANSION.md`; cbBTC already in the registry. Wire *after* the app
  works end-to-end for TSLAx (P1–P4), since each market is just registry + risk params + the
  `assetClass` oracle branch. OUSG/treasuries need permissioned-transfer work — later.

## Component-by-component status → this plan closes them
Every 🔴/🟡 in `COMPONENT-MAP.md` is addressed: wallet (P1), live data (P1), supply/withdraw
(P2), positions/repay (P3), borrow (P4), links/polish (P5).
