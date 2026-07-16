# Markets expansion — what we can add next, and how to wire it

All addresses/feeds below are **verified live** (Pyth Hermes prices fetched through our
policy; cbBTC mint read on a mainnet fork). The key enabler: **the program is
collateral-agnostic** — any token can be posted as collateral against the shared USDC
pool. A "market" is not a new contract; it's a **registry entry + risk params + a vault
ATA + the operator authorizing at the right feed/LTV.** So adding markets is mostly
config + oracle discipline, not new on-chain code.

## The shared-pool model (important)
One `PoolState`, one stable (USDC). Every collateral type borrows from the **same USDC
liquidity pool**; each `Position` holds its own collateral balance. So:
- ✅ Deep shared liquidity, one pool to seed.
- ⚠️ Risk is shared — a bad liquidation in one market draws on the same pool. For v1 that's
  acceptable with conservative LTVs; per-market isolation (Morpho-style) is a later option.

## Candidate markets (verified data)

| Market | Class | Token program | Dec | Pyth feed (verified live) | Live px | Proposed LTV / liq | Notes |
|--------|-------|---------------|-----|---------------------------|---------|--------------------|-------|
| **cbBTC** | crypto | **classic SPL** (`Tokenkeg…`) | 8 | `0xe62df6c8…415b43` BTC/USD | $64,564 | **70% / 80%** | ✅ **best profile** — Coinbase-custodied, no permanent delegate, no hook, 24/7, deep liquidity, robust oracle. Mint `cbbtcf3aa214zXHbiAZQwf4122FBYbraNdFqgw4iMij` |
| ETH (wETH) | crypto | classic SPL | 8 | `0xff61491a…d0ace` ETH/USD | live | 70% / 80% | same clean profile; wrapped-ETH mint TBD |
| SOL (wSOL) | crypto | classic SPL | 9 | `0xef0d8b6f…0b56d` SOL/USD | live | 60% / 72% | native/wrapped SOL; more volatile → lower LTV |
| **SPYx** | equity (index) | Token-2022 | 8 | `0x19e09bb8…11cd5` SPY | $752.14 | **55% / 65%** | index → lower single-name gap; higher LTV than single stocks |
| **AAPLx** | equity | Token-2022 | 8 | `0x49f6b65c…55688` AAPL | $315.43 | 45% / 58% | large-cap, gap-risk |
| **NVDAx** | equity | Token-2022 | 8 | `0xb1073854…0a593` NVDA | $211.87 | 40% / 55% | large-cap, higher vol |
| MSTRx | equity (volatile) | Token-2022 | 8 | `0xe1e80251…111f09` MSTR | live | 30% / 45% | high vol + gap → tight |
| COINx | equity (volatile) | Token-2022 | 8 | `0xfee33f2a…860245` COIN | live | 35% / 48% | " |
| USDY | yield-stable | (verify) | — | `0xe393449f…0e7326` USDY | $1.13 | 85% / 95% | Ondo yield $; near-stable but accrues (not a hard peg); check transfer restrictions |
| OUSG / treasuries | treasury (permissioned) | — | — | — | — | 90% / 96% | **KYC-whitelisted transfers** — pool must be whitelisted + hook accounts. Compliance-heavy, DEFER |

*(Every xStock is the same Backed-Finance family as TSLAx — Token-2022, 8 dec, **permanent
delegate** = issuer clawback; verified on TSLAx. Their exact sibling mints just need pulling
from the xStocks registry/Solscan — a data task, not an engineering one.)*

## Two things that differ by asset class (the real work per market)

### 1. Oracle discipline — add `assetClass` to the registry
Our policy is currently **equity-tuned** (market-hours-aware: tightens staleness off-hours
for the 24/7-token-vs-session-underlying gap). **Crypto trades 24/7 — that tightening is
wrong for BTC/ETH/SOL.** So:
- Add `assetClass: "crypto" | "equity" | "treasury"` to each registry entry.
- `pyth.mjs` branches: **crypto → always-on** (skip the off-hours staleness tightening,
  standard 60s + circuit breaker); **equity → market-hours-aware** (today's behavior);
  **treasury → slow-moving** (wide staleness OK, but NAV-based).
- This is a small, well-scoped change to `applyOraclePolicy`.

### 2. Risk parameters — set per asset, not one-size
- **Crypto majors (BTC/ETH):** high LTV (70%), no gap buffer, standard liquidation.
- **Index equity (SPYx):** medium LTV (55%), modest gap buffer.
- **Single-name equity:** low LTV (40–45%), gap buffer, tighter for volatile names (MSTRx 30%).
- **Yield-stable (USDY):** high LTV (85%), but NOT 100% — it accrues, and de-peg/restriction risk.
- **Treasuries (OUSG):** high LTV, but blocked on the permissioned-transfer work.

## How to add a market — the checklist
1. **Get the mint** (Solscan) + **confirm token program + decimals** (fork-clone read, like we
   did for TSLAx/cbBTC). Classic SPL and Token-2022 are both handled by our collateral leg.
2. **Confirm the Pyth feed** live (fetch through `applyOraclePolicy`) — done above for all.
3. **Registry entry** in `operator/assets.mjs`: `{ symbol, mint, tokenProgram, decimals,
   pythFeedId, assetClass, maxLtvBps, liqThresholdBps }` (+ `permanentDelegate`/hook flags for disclosure).
4. **`assetClass` branch** in `pyth.mjs` (crypto vs equity vs treasury staleness).
5. **Create the collateral vault ATA** (pool authority's ATA for that mint + its token program) — one tx.
6. **Operator** uses that feed + LTV when authorizing (`dregg_borrow` with the asset's price/LTV).
7. **UI**: the market row is data-driven — add the registry entry and it renders (once the app reads the registry).
8. **Disclosure**: xStocks/treasuries carry issuer + permanent-delegate + (treasury) KYC risk — surface per-asset.

## Recommended rollout
1. **cbBTC first** — cleanest asset, best LTV, no securities baggage, crypto-native audience (pairs with the "onchain" story). Only needs the `assetClass: crypto` oracle branch.
2. **SPYx + AAPLx + NVDAx** — the xStocks story (answers the Route2FI tweet); same wiring as TSLAx, just add the sibling mints + registry.
3. **ETH / SOL** — trivial crypto adds once the crypto branch exists.
4. **USDY** — after verifying its token program + any transfer restrictions.
5. **OUSG / treasuries** — only after the permissioned-transfer (whitelist + hook) work; compliance-gated.

## What's genuinely blocking (so we don't overpromise)
- **Permissioned RWAs (OUSG, some Ondo):** issuer-whitelisted transfers → the pool vault must be
  approved by the issuer, and transfers carry hook accounts. Real integration + compliance work.
- **xStocks permanent delegate:** the issuer can claw back collateral (same caveat as TSLAx) —
  a v1 disclosure item, unresolved for scale (see `cv-gateway/RWA-real-token-findings.md`).
- **Per-market risk isolation:** shared USDC pool means cross-market contagion; fine for a
  conservative v1, revisit for scale.
