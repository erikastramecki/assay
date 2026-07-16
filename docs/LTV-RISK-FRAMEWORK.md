# LTV & risk-parameter framework

How Assay sets loan-to-value (LTV) and liquidation thresholds safely — the methodology,
how the big lenders do it, and the concrete schema for our assets (esp. the RWA gap-risk
that makes equities different from crypto).

## The one question LTV answers
> If the collateral price falls, can a liquidation still fully cover the debt before the
> position goes underwater?

LTV must leave enough headroom to survive **four things** between "healthy" and "bad debt":
1. **Price drop during the liquidation window** — the time to detect + execute a liquidation.
2. **Slippage** — the liquidator has to sell the collateral; thin liquidity = worse fills.
3. **Liquidation penalty/bonus** — the incentive paid to liquidators (they buy collateral at a discount).
4. **Oracle error/latency** — the price we act on may lag or be uncertain.

So there are **two** numbers per asset, and their gap is the safety:
- **Max LTV** (borrow LTV) — the most you can borrow when opening. e.g. 40%.
- **Liquidation Threshold (LT)** — the debt/value ratio that triggers liquidation. e.g. 50%.
- **LT > Max LTV** always, so a fresh max loan isn't instantly liquidatable. And **LT itself is
  set below the "stress-survivable" ratio** so a liquidation at LT still clears the debt.

## How other platforms do it

| Platform | Model | Who sets it | Key factors |
|----------|-------|-------------|-------------|
| **Aave** | Per-asset LTV / liq-threshold / liq-bonus; supply+borrow caps; isolation mode; e-mode for correlated pairs | Governance, advised by **risk firms (Gauntlet, Chaos Labs) running agent-based simulations** | volatility, on-chain liquidity/depth, oracle quality, correlation |
| **Compound** | Collateral factor (= LTV) per asset | Governance | same |
| **MakerDAO** | Min collateralization ratio per collateral type (inverse LTV), debt ceilings, stability fees, liquidation penalty | Governance + risk core units | volatility, liquidity, systemic risk |
| **Morpho Blue** | **Immutable per-market LLTV** chosen at market creation from a whitelist; markets are **isolated** | Market creator; curators choose which to fund | oracle + LLTV picked for the pair |
| **Kamino** | Per-asset LTV/LT + caps + e-mode | Governance/risk | volatility, liquidity, oracle |

**The common thread:** LTV is a **governance risk parameter**, not a live computation. The
number comes from a **stress/simulation model** of "how bad can this get in a liquidation,"
and it's **monitored and adjusted** as volatility and liquidity change. The best shops
(Aave via Gauntlet/Chaos) literally run Monte-Carlo simulations of price paths + liquidation
cascades to pick the caps and thresholds. Smaller/newer protocols start with a
**conservative rules table** and tighten/loosen from observation.

## The risk inputs (what feeds the number)

1. **Volatility** — the worst plausible drawdown over the liquidation window. Use a high
   percentile (e.g. 99th) of historical + implied vol. Higher vol → lower LTV.
2. **Liquidity / market depth** — how much can you liquidate without moving the price? Thin
   liquidity → high slippage → **lower LTV AND a supply cap** (never let one market's
   liquidation exceed what the market can absorb).
3. **Oracle quality** — Pyth confidence width, update frequency, manipulation resistance.
   Wide/slow oracle → more conservative. (We already value collateral at `price − k·conf`.)
4. **Liquidation feasibility** — how fast can our keeper act? Slower → bigger buffer.
5. **Gap risk (THE RWA-specific one — see below).**

## The formula (how a threshold is derived)
For a stress drop `D` (a high-percentile adverse move over the liquidation window, **plus the
overnight gap for equities**), slippage `S`, and liquidation penalty `P`, the liquidation
threshold must satisfy: after the drop, the (discounted) collateral still covers the debt +
penalty. Intuitively:

```
LT  ≈  (1 − D − S) / (1 + P)          # threshold survives a stress drop + slippage + penalty
maxLTV  =  LT − margin                # a fresh loan can't be instantly liquidatable (margin ~10%)
supplyCap  ≈  k · (market depth that can be liquidated in one window)
```

Example (a large-cap equity): plausible stress drop incl. an overnight gap `D≈35%`, slippage
`S≈5%`, penalty `P≈8%` → `LT ≈ (1−.35−.05)/1.08 ≈ 0.55`. Round DOWN for safety → **LT 55%**,
**maxLTV ~45%**. (Then tighten for single-name / volatile names.)

## THE RWA DIFFERENCE — gap risk (our defining constraint)
A tokenized stock (xStock) trades **24/7 on-chain, but the underlying share only trades
9:30–16:00 ET**. Overnight / weekend / on a trading halt, the oracle price is a **stale
last-print** while the real value can gap on news (earnings, a halt, a macro shock). An
attacker can borrow at Friday's price right before a Monday gap-down.

This is why **equities get much lower LTV than crypto even at similar volatility** — the LTV
must survive a *discontinuous* overnight move, not just intraday drift:
- **Single-name stock** overnight gaps can be 10–30% on bad news → LTV **40%** (a 60% cushion).
- **Index (SPYx)** is diversified → gaps far less → LTV **55%**.
- **Crypto (BTC/ETH)** trades 24/7 — **no gap** (the token *is* the asset, always priced) → LTV **70%**.

Our oracle policy already enforces the freshness side of this: **tighter max-staleness
off-hours** (15s vs 60s) so a stale equity price is *refused*, and the `assetClass` branch
keeps crypto (always-fresh) from being wrongly refused. LTV handles the *magnitude* of the
gap; the oracle handles *not lending on a stale print*.

## Assay's schema (the per-asset table + how a new asset is parameterized)

**To onboard a market, classify it and set params from this table (conservative to start):**

| Class | Example | Max LTV | Liq threshold | Rationale |
|-------|---------|--------:|-------------:|-----------|
| Crypto major | cbBTC, ETH | 70% | 80% | 24/7, deep liquidity, robust oracle, no gap |
| Crypto (volatile) | SOL | 60% | 72% | 24/7 but higher vol |
| Index equity | SPYx | 55% | 65% | diversified → small gap |
| Large-cap single equity | AAPLx, NVDAx | 40–45% | 55–58% | gap risk + single-name vol |
| Volatile single equity | MSTRx, COINx | 30–35% | 45–48% | high vol + gap |
| Yield-stable | USDY | 85% | 95% | near-peg, but accrues + issuer restrictions (not 100%) |
| Tokenized treasury | OUSG | 90% | 96% | low vol — BUT permissioned transfers gate it (later) |

**The onboarding checklist for a new asset's LTV:**
1. **Classify** (crypto / index / single-equity / stable / treasury) → start from the row above.
2. **Adjust for the specifics:** vol percentile, on-chain liquidity/depth (→ maybe lower + a
   supply cap), oracle confidence width, and — for equities — the plausible **overnight gap**
   for that name (single-stock > index).
3. **Set LT from the stress formula**, then **maxLTV = LT − ~10% margin**.
4. **Set a supply/borrow cap** sized to liquidatable depth (don't let a liquidation exceed
   market depth in one window).
5. **Add a reserve/insurance buffer** target (a borrow-fee cut) for residual gap-tail risk.
6. **Review + monitor:** re-evaluate as vol/liquidity move; tighten fast, loosen slowly.

## Who enforces it (the Assay-specific safety)
The LTV *value* is our risk decision (the table + process above). But unlike a normal
protocol that just trusts its off-chain risk team, **dregg enforces it provably**: the borrow
turn is admitted only if `debt ≤ collateral · conservative_price · LTV` **in-kernel**, with
`conservative_price = Pyth_price − k·confidence`, plus freshness + confidence caveats. So the
risk parameters are machine-checked at authorization, not asserted in a config. Liquidation
uses the liquidation threshold the same way (`dregg_liquidate`).

## v1 vs. later
- **v1 (now):** the conservative rules table above + the stress-formula onboarding checklist +
  the oracle discipline. Deliberately conservative LTVs (esp. equities) so we're safe while
  small. TSLAx 40% / cbBTC 70% are already set this way.
- **Later (scale):** commission a Gauntlet/Chaos-style **simulation** of price paths +
  liquidation cascades to calibrate caps and thresholds precisely; add per-market isolation
  (Morpho-style) so a bad market can't contaminate the shared pool; a funded reserve.
