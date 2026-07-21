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
All four mediums are now **fixed** — detail below. Nothing in `rh-chain/` is deployed to any
network, so none of this was ever live exposure.

### MEDIUM — the session calendar was an hour wrong half the year (fixed)
`isUsMarketHours` hardcoded the EST mapping (14:30-21:00 UTC). During EDT that reported
"in session" for the hour AFTER the close — the unsafe direction, admitting borrowing into a shut
market. **Fix:** the window is now the INTERSECTION of the EST and EDT mappings, 14:30-20:00 UTC,
so it is never open when the market is shut. It gives up an hour of availability; a full DST
implementation would recover it.

The existing boundary test asserted 20:59 UTC was in-session, which is only true under EST — the
test **enshrined the bug it should have caught**. Rewritten.

### MEDIUM — market holidays read as in-session (fixed)
The calendar knows weekends, not holidays. On Thanksgiving the clock says in-session while the feed
has not printed since the previous close, and an 18-24h holiday gap fits inside the 25h staleness
bound, so staleness could not catch it. A source comment claimed it did. **Fix:** if the clock says
in-session, the feed must have printed at or after **today's** open; otherwise the session is
treated as closed. A very quiet stock is also refused, which is the conservative direction.

### MEDIUM — short outages slipped past the liveness gate (fixed)
`LivenessOracle` used `maxHeartbeatAge` as both the liveness bound and the gap detector, so an
outage shorter than it was invisible: the heartbeat never went stale, no gap was recorded, and
liquidations resumed in the first block back — the exact restart-liquidation the contract exists to
prevent, at a smaller scale. **Fix:** a separate, tighter `gapThreshold`, validated to be below the
liveness bound.

### MEDIUM — surviving guard mutations (PARTIALLY fixed; the claim made here was wrong)
A sweep found 13 guards deletable with a green suite, and twelve were given tests. Two of those
were not missing tests but **bare `expectRevert()` calls**, which match any revert including the
one that would happen anyway.

**Round 2 disproved the coverage claim by a factor of 50.** An independent sweep of 139 mutations
— deletions, comparison inversions, operand swaps and constant changes across all seven source
files — found **50 survivors** on the same green suite.

The cause was a bug in the measurement tool, not merely its narrowness: the sweep matched only
`if (…) revert` and `require(…)`, so it was structurally blind to the **early-return** guard form
(`if (x == 0) return 0;`), which is used throughout. Two survivors fall inside the sweep's own
stated scope. **A claim about coverage was published on the output of a tool that had never been
tested.**

Corrected status: 12 guards gained tests; roughly 50 mutations survive; the constants the README
names as the controls (`MIN_RISK_GAP_BPS`, `PARAM_TIMELOCK`) can be halved with the suite green.

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
