# Assay — UI/UX component map (every element → wiring → status)

Every interactive component in the Assay design, what it needs to become functional, and
its status today. **Status legend:** 🟢 works · 🟡 partial (client-only) · 🔴 dead (no wiring).
Source of truth for the design: the Assay Artifact. Backend it maps to: `dregg_lending_async`
(instructions in **bold**), `operator/pyth.mjs`, the Operator API (to build).

## Nav bar
| Component | Should do | Wiring | Status |
|-----------|-----------|--------|--------|
| Brand / logo | scroll to top | anchor `#top` | 🟢 |
| Markets / Borrow / Proof links | scroll to section | anchors | 🟢 |
| Earn link | scroll to Earn | **anchor `#earn` missing** (earn lives in `#borrow`) | 🟡 fix anchor |
| Docs link | open docs | `href="#"` | 🔴 point at `/docs` |
| Theme toggle | light/dark | client JS | 🟢 |
| **Connect wallet** | connect Phantom/Solana | **Solana wallet adapter** | 🔴 **core — build first** |
| "Solana" network pill | show network + status | read RPC / cluster | 🟡 static → live |

## Hero
| Component | Should do | Wiring | Status |
|-----------|-----------|--------|--------|
| "Open a position" | scroll to borrow | anchor | 🟢 |
| "View markets" | scroll to markets | anchor | 🟢 |
| Live ticker (Pyth) | stream collateral prices | **`pyth.mjs` → Hermes**, poll ~2s | 🔴 hardcoded → live |
| "US markets open" pill | market-hours state | `isUsMarketHours()` in `pyth.mjs` | 🔴 static → computed |

## KPI ribbon
| KPI | Source | Status |
|-----|--------|--------|
| Total supplied | Pool `cash + total_borrows` (read PoolState acct) | 🔴 static |
| Total borrowed | Pool `total_borrows` | 🔴 static |
| Avg borrow APR | Pool `rate_bps` (V1: single rate) | 🔴 static |
| Proofs settled | count of `settle_batch` (or `last_settled`) | 🔴 static / stub |

## Markets table
| Component | Should do | Wiring | Status |
|-----------|-----------|--------|--------|
| Rows (TSLAx, NVDAx, AAPLx, SPYx, MSTRx, COINx) | list live markets | registry `assets.mjs` + Pyth + PoolState | 🔴 hardcoded. **V1: only TSLAx is real** — others need mint + feed id wired |
| Oracle price / 7-day spark | live price + history | Pyth Hermes (price); history = TWAP/cache | 🔴 static |
| Max LTV | per-asset `maxLtvBps` | `assets.mjs` | 🟡 static-but-correct for TSLAx (40%) |
| Borrow APR / Supply APY | from Pool rate + utilization | PoolState | 🔴 static |
| Available / Utilization bar | Pool cash / (cash+borrows) | PoolState | 🔴 static |
| Row click | open Borrow panel for that asset | set panel state | 🔴 `cursor:pointer` but no handler |
| gap-risk / index flag tooltip | explain LTV cap | `title` attr | 🟢 |

## Borrow panel (the money moment)
| Component | Should do | Wiring | Status |
|-----------|-----------|--------|--------|
| Borrow / Repay toggle | switch mode | client state | 🔴 dead |
| Collateral field + asset picker | choose collateral + amount | wallet token balance (Token-2022 ATA) | 🔴 static |
| "You borrow" field | target debt | derived from LTV × collateral × price | 🟡 |
| LTV slider + ticks | set LTV (≤ maxLtv) | client → recompute | 🟡 (gauge updates client-side) |
| Health gauge + readouts (liq price, buffer) | live health | client math from price + LTV | 🟡 client-only |
| **"Review & borrow"** | **execute a borrow** | **Operator API `/borrow`** → dregg authorize → **`disburse`** (op+borrower cosign, Token-2022 collateral) | 🔴 **core action** |
| Repay mode (same panel) | repay a position | **`repay`** (wallet-signed) | 🔴 |

## Earn panel
| Component | Should do | Wiring | Status |
|-----------|-----------|--------|--------|
| Supply / Withdraw toggle | switch mode | client state | 🔴 dead |
| Supply field | amount | wallet USDC balance | 🔴 static |
| **"Supply USDC"** | **deposit into pool** | **`deposit`** (wallet-signed) | 🔴 core action |
| Withdraw mode | burn shares → USDC | **`withdraw`** (wallet-signed) | 🔴 |
| APY / pool liquidity / utilization / reserve | live pool stats | PoolState read | 🔴 static |
| "Your share" | lender shares | LenderPosition PDA read | 🔴 static (—) |

## Proof-flow section + footer
| Component | Should do | Wiring | Status |
|-----------|-----------|--------|--------|
| 4 proof-flow steps | explain safety | static content (fine) | 🟢 informational |
| "Read the proofs →" | link to proofs/docs | `href="#"` | 🔴 point at docs/repo |
| Footer Docs / GitHub | links | `href="#"` | 🔴 |

## Missing views to ADD for a usable V1 (not in the current design)
- **Your positions** — a borrower's open loans (read `Position` PDAs by borrower): collateral,
  current debt (principal · index/snapshot), health, liq price, **Repay** button. Essential —
  you can't manage a loan without it.
- **Transaction states** — pending/confirm/success/error toasts on every action (the money-path
  UX rule: block dismissal mid-signing, refresh panels after).
- **Onboarding empty states** — "connect wallet", "no positions yet", faucet hints on devnet.

## Wiring priority (what makes the most buttons live, fastest)
1. **Connect wallet** — unlocks everything (balances, all actions).
2. **Live Pyth prices** — ticker + markets + gauge become real (frontend-only, no chain).
3. **Supply / Withdraw** — simplest real txs (wallet-signed, no operator).
4. **Positions view + Repay** — closes the borrower loop (wallet-signed).
5. **Borrow** — last, because it needs the Operator API (dregg authorize + co-sign).
