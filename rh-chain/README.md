# Assay on Robinhood Chain

Solidity port. See `../docs/SCOPE-robinhood-chain.md` for the full design rationale and the
Phase 0 findings that ground it.

```
forge soldeer install 2>/dev/null || {   # deps are NOT vendored — install them first
  forge install foundry-rs/forge-std
  forge install OpenZeppelin/openzeppelin-contracts@v5.6.1
}
forge test                          # unit tests
node phase0-verify.mjs              # re-verify live chain assumptions (no keys, no gas)
```

`lib/`, `out/` and `cache/` are gitignored: dependencies are reproduced by `forge install`
rather than vendored, so the repo does not carry thousands of third-party files.

## Conservative risk stance (v1)

Set deliberately low, to be raised as the MVP proves itself — not lowered after an incident.

| Parameter | Single-name equity | Broad ETF | Why |
|---|---|---|---|
| Max LTV | **35%** | **45%** | The borrow ceiling |
| Liquidation threshold | **55%** | **65%** | — |
| **Gap buffer** | **20pp** | **20pp** | **The number that matters** |
| Liquidation bonus | 8% | 8% | Above the usual 5%: liquidators carry stale-price risk |
| Off-hours new borrows | blocked | blocked | No fresh price means no new exposure |

**The buffer, not the LTV, is the safety margin.** The feed is blind for 60+ hours a week, so a
position can only be liquidated after the market reopens. A 20-percentage-point gap between LTV and
liquidation threshold means a position opened at max LTV survives roughly a 30% adverse move before
going underwater — which covers most weekend gaps in single-name equities, and comfortably covers
index ETFs.

Three risks stack here and none of them is hedgeable:
- collateral is a **Jersey debt token**, not equity — Robinhood counterparty risk
- `adminBurn` can destroy it, held by a **plain EOA** with no multisig or timelock
- the price is **blind nights and weekends**

## Oracle reality (grounded, not assumed)

Every Chainlink feed on Robinhood Chain — all 34 Robinhood equity feeds and the crypto feeds —
runs an **86,400s (24h) heartbeat with a 0.5% deviation trigger**. Pulled from Chainlink's feed
directory via `node script/fetch-feeds.mjs`, which fails loudly if the heartbeat ever changes.

This shaped the design, and corrected a mistake:

- A staleness bound **tighter than the heartbeat is wrong**. The first draft used 3600s in-session
  and 300s off-hours. The live AAPL feed was ~2.4 hours old when checked, quoting $326.49 — a
  perfectly healthy price that both of those bounds would have rejected. It would have bricked
  borrowing every quiet hour and every night.
- The guarantee that protects a lender is the **deviation threshold, not the heartbeat**: a price
  up to 24h old means "this has not moved 0.5% since". So the staleness bound exists to catch a
  **broken** oracle, not a quiet market, and is set to heartbeat + 1h grace (90,000s).
- **Off-hours protection cannot come from a staleness bound**, because when the market is shut the
  price genuinely is not moving and no update is due. It comes from the session flag: no new
  borrows, and no liquidation at a price nobody can verify. The LTV buffer carries the rest.

`_setFeed` rejects any `maxStaleness` below the heartbeat, so this class of misconfiguration
cannot be deployed.

## Modules

- `StaleFeedGuard` — sequencer uptime + grace period, per-feed staleness with a tighter off-hours
  bound, session reporting. Fails closed. A revert is the right answer to an unknown price.
- `CollateralReconciler` — never trusts a stored balance; detects `adminBurn` shortfall without
  reverting (reverting would freeze every other borrower); values via the live `uiMultiplier` so a
  stock split cannot misprice positions.

## Testing standard

Every guard must die under mutation. `forge test` passing is necessary, not sufficient — in the
Sui codebase four guards were deletable with a fully green suite. Before claiming a guard is
covered, delete it and watch a test fail.
