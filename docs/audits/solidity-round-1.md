# Solidity port — adversarial audit round 1

**Target:** `rh-chain/` (AssayPool, AssayMarkets, StaleFeedGuard, LivenessOracle,
CollateralReconciler) · **Date:** 2026-07-20 · **Result:** 19 confirmed, 5 refuted · **Not clean.**

Three auditors, two verifiers per finding, PoCs executed against the real contracts.

---

## The finding that matters most

> Move's resource model makes collateral a non-fungible owned object, so a position *physically
> cannot* be paid out of another position's asset. Solidity commingles ERC-20 balances, and the
> port translated `min(position, pool_balance)` literally.

The Move predecessor went through six audit rounds. **Every invariant those rounds produced was
carried across — and the invariants Move enforced for free were not.** The type system had been
doing safety work the port did not know it was relying on. That single observation explains two of
the four criticals.

---

## Fixed (full detail — fixes committed in `05a59cb`)

### CRITICAL — collateral valued in the wrong decimals, 1e12 over-borrow
`AssayMarkets.collateralValue` divided out only the *feed* decimals and returned a
collateral-scaled number, which was then compared against a 6-decimal USDG debt. Every LTV limit
was 1e12 too permissive: a $2,000 AAPL position could drain the entire lender pool, and the
resulting position was not even liquidatable because `isUnderwater` made the same comparison.

Verified on mainnet: USDG `6`, AAPL Stock Token `18`, Chainlink feed `8`.

**Why no test caught it:** the suite's `MockUSDG` used 18 decimals. A mock that differs from
production hides exactly the bugs production has.

**Fix:** normalise to the borrow asset — `value = uiAmount × price × 10^assetDec / (10^collDec ×
10^feedDec)`; `collateralDecimals` is now a required, validated market parameter; the mock is 6.

### CRITICAL — `adminBurn` loss allocated by repayment order
`recordedRaw` was per-**token** while positions are per-**borrower**, and the code clamped a
per-borrower entitlement against the pooled balance. Alice and Bob each post 10 units; Robinhood
burns 10; **whoever repays first recovers all 10 — including the other's** — and the second
recovers nothing despite paying their debt in full.

The shortfall machinery meant to prevent this was inert: `shortfallRaw` written and never read,
`ShortfallSocialised` declared and never emitted, all three `_reconcile` call sites discarding the
return value. The contract's own comments described a policy the code did not implement.

**Fix:** `_effectiveCollateral` scales each position by `surviving / nominal`, socialising the loss
pro-rata. Alice and Bob each get 5, in either order.

### HIGH — first-depositor share inflation
Hand-rolled 4626 maths with no virtual offset, no dead shares, no minimum-shares floor, and a
donatable `totalAssets()`. Deposit 1 wei, donate to inflate the share price, and the victim's
deposit rounds to **zero shares** while the attacker redeems everything.

**Fix:** OpenZeppelin `ERC4626` with `_decimalsOffset() = 6`. The attack is now written out as an
attack in the test suite, not asserted as prevented — see the mutation note below for why that
distinction mattered.

### HIGH — `adminBurn` made an unsecured position permanently unliquidatable
The health check read the stored `collateralRaw`, never decremented on a burn, so a position
backing nothing read as healthy and could never be liquidated. **Fix:** health and seizure both use
the surviving balance.

### HIGH — `borrow(debt = 0)` trapped collateral forever
No exit path: `repay` reverts `NoDebt`, and `isUnderwater` is false at zero debt so liquidation
also refuses. **Fix:** zero debt rejected at origination.

### HIGH — pause-aware accrual was documented and never implemented
The scope doc names it a requirement; `grep -rn 'paused' src/` returned only comments. A Robinhood
token pause blocks transfers, so a borrower cannot repay — and interest kept compounding across a
window in which repayment was impossible, on the issuer's pause rather than theirs. **Fix:**
accrual suspends while a watched collateral token is paused.

---

## Open (placeholder — detail publishes when fixed)

| # | Severity | Surface | Status |
|---|---|---|---|
| 1 | medium | `StaleFeedGuard` — session calendar, DST | open |
| 2 | medium | `StaleFeedGuard` — session calendar, market holidays | open |
| 3 | medium | `LivenessOracle` — short-outage coverage | open |
| 4 | medium | test coverage — surviving guard mutations | open |
| 5 | low | misc. hygiene, dead declarations | open |

Nothing in `rh-chain/` is deployed to any network, so these are pre-deployment defects rather than
live exposure.

---

## The uncomfortable part: mutation testing

Before this audit the author reported *"63 tests, all guards mutation-verified."* **That was
false.** The guards mutated were the ones tests had already been written for — which is circular,
and can only confirm what was already thought of. The audit mutated all 65 and **18 survived a
fully green suite**, including a ported audit invariant (the per-market exposure cap) and an admin
check.

It repeated during the fixes: of six, five caught their mutation immediately and the ERC4626
inflation protection did **not** — the mitigation was present and nothing proved it worked.

The rule that came out of it: **a guard is not covered until you have deleted it and watched a test
fail.** Anything else is an assumption wearing a test's clothes.

---

## Refuted (recorded so they are not re-litigated)

- **Multiplier changing between health check and seizure** — impossible; `block.timestamp` is fixed
  within a transaction, so both reads see the same value.
- **`1e18` denominator for `uiMultiplier` assumes 18-decimal tokens** — it does not; the constant
  belongs to `ERC20ScaledUIUpgradeable` and is independent of token decimals.
- **Forward-split mispricing** — handled correctly; only the reverse-split direction is exposed, and
  via feed lag rather than the multiplier.
- **Fee-on-transfer / non-standard `balanceOf`** — mechanically real if Robinhood upgrades the
  shared beacon, but not attacker-triggerable.
- **Dead/duplicated valuation helpers** — accurate observation, no reachable defect.

## Not covered

No fork testing against real Stock Tokens; no gas/DoS analysis; no formal verification; the keeper
service and deploy scripts were out of scope.
