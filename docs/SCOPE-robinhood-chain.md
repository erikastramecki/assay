# Scope — Assay on Robinhood Chain

Target MVP: a user signs in via their own MCP, an AI agent buys stock on Robinhood, the Stock
Token lands in their self-custody wallet, and they borrow against it in Assay.

All contract facts below were read from the **deployed, verified source** on
`robinhoodchain.blockscout.com`, not from documentation — the docs contradicted themselves and
several widely-cited third-party write-ups are wrong about transfer restrictions.

---

## 0. The finding that reframes the port

`AAPL • Robinhood Token` (`0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9`) is an eip1967 beacon proxy
to a verified `Stock` implementation (`0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2`):

```solidity
contract Stock is IStock, AccessControlled, OraclePausable, ERC20ScaledUIUpgradeable

function transfer(address to, uint256 value) public override
    onlyNotPaused onlyNotBlocked(to) onlyNotBlocked(_msgSender())

modifier onlyNotBlocked(address account) {
    if (IAccessControlsRegistry(ACCESS_CONTROLLED_REGISTRY).isBlocked(account)) revert Blocked(account);
    _;
}
```

`isBlocked` is a **deny-list, not an allow-list**. Any address — including an arbitrary
third-party lending pool — can receive and hold Stock Tokens today. No KYC gate, no whitelist, no
integration agreement at the contract layer.

**And Robinhood Chain has on-chain Chainlink price feeds for every Stock Token**, using the same
`AggregatorV3Interface` / `latestRoundData()` as any crypto feed.

That second fact is the important one. On Sui there is no on-chain oracle, so the operator signs
prices off-chain and the contract verifies an ed25519 attestation. Essentially every mechanism
hardened across audit rounds F2–R6 — expiry windows, nullifiers, pool binding, domain separation,
the two-key liquidation dance, `MAX_ATTEST_WINDOW_S`, the whole cross-language byte-pinning
apparatus — exists **to compensate for the absence of an on-chain price**.

**The port is therefore a simplification, not a translation.** Roughly 60% of the Sui contract's
complexity does not need to exist on Robinhood Chain.

---

## 1. What carries over, what disappears

### Carries over — the invariants the audits actually bought

These are design conclusions, not code. They transfer directly to Solidity:

| Invariant | Origin |
|---|---|
| Authorisation must bind the **loan's actual terms** — debt, collateral amount **and type** | F1, R5-1 |
| Liquidation needs a **real health check** and must **refund surplus** to the borrower | F3 |
| Every capability must be **bound to the pool it governs** | R2-1 |
| Position objects must be **bound to their pool** | R3 |
| Exposure ledgers must **release on close**, exactly once, with no double-release path | R5-3, R6-B1 |
| Rate parameters must be **bounded**; overflow must saturate, never trap funds | R2-2 |
| Privilege changes need a **timelock**, so rotate-and-use is not atomic | R5-2 |
| Guards need **mutation tests** — four guards in this codebase were deletable with a green suite | R4, R6 |

### Disappears — machinery that only existed for the missing oracle

- The entire ed25519 attestation path (`attest_msg`, `disburse_attested`, expiry, window, nullifier)
- Domain separation between message types (only needed because two things were signed)
- Cross-language byte-pinning between TS and Move
- The operator's role as *price authority*
- Two-party liquidation, the rotation timelock, `pending_pubkey` state
- `pause` as a key-compromise kill switch

Liquidation becomes **permissionless with an on-chain health check** — which is what F3 was
reaching for and could not achieve without an oracle.

### The ZK/dregg layer

`settle_batch`, the Poseidon accumulator, and `loan_commit_of` were the "provably safe"
differentiator. **This is the one real decision to make.** With on-chain LTV enforcement, the
proof is no longer load-bearing for solvency — the contract can enforce the invariant directly.
Options:

1. **Drop it for v1 on this chain.** Simplest, honest, ships fastest. The safety story becomes
   "the contract enforces LTV against a Chainlink feed" — the same as Aave, which is a weaker
   claim than "provably safe" but is *true today*, unlike the current claim.
2. **Keep it as an additional attestation** over the dregg kernel's decision, layered on top of
   on-chain enforcement. Preserves the differentiator; costs the circuit work that is already
   blocking `dregg_lending` origination.

Recommendation: **ship v1 without it, keep the hook.** The circuit work is upstream-blocked and
should not gate a working product.

---

## 2. What is NEW and Robinhood-specific

These have no analogue in the Sui design and are the real engineering risk.

### 2.1 `adminBurn` — collateral can be destroyed in place

```solidity
function adminBurn(address from, uint256 amount) public override onlyRole(ADMIN_BURNER_ROLE) {
    _burn(from, amount);
}
```

Note what is **absent**: no `onlyNotPaused`, no `onlyNotBlocked`. Robinhood can burn Stock Tokens
out of **any** address, including a live lending pool, unconditionally.

An open loan can become instantly unsecured with **nothing left to liquidate**.

Design consequences:
- **Never trust a stored collateral figure.** Read `balanceOf(pool)` and reconcile against the sum
  of recorded positions on every state-changing call.
- Add an explicit **shortfall path**: when actual < recorded, the deficit is socialised to lenders
  or absorbed by reserves — decided in code, not discovered in production.
- This risk must be **disclosed in the UI and priced into LTV**. It is not a bug to fix; it is a
  property of the collateral.

### 2.2 `uiMultiplier` — corporate actions rescale the position mid-loan

```solidity
function balanceOfUI(address a) public view returns (uint256) {
    return Math.mulDiv(balanceOf(a), uiMultiplier(), DENOMINATOR);
}
function _updateUIMultiplier(uint256 newMultiplier, uint256 effectiveAt_) internal { ... }
```

`balanceOf()` is the raw amount and is **stable**; `balanceOfUI()` is the share-equivalent and
**changes on splits and other corporate actions**. The multiplier can be **scheduled** with a
future `effectiveAt`, so it changes **without any transaction touching the pool**.

- Collateral must be valued as **`balanceOfUI × price`**, never `balanceOf × price`. Pricing the
  raw balance misprices every position by the split ratio the moment a split lands — wrongly
  liquidating healthy loans or silently under-collateralising others.
- Health checks must re-read `uiMultiplier()` every time; caching it is a bug with a delayed fuse.
- Add a **scheduled-multiplier alert** so a pending corporate action is visible before it fires.

### 2.3 Global pause traps repay and liquidate

`paused()` returns token-level **OR** registry-level pause. When Robinhood pauses, `transfer` and
`transferFrom` revert — so **borrowers cannot repay and liquidators cannot seize**, while interest
keeps accruing.

- Accrual must be **suspended while the collateral token is paused**, or borrowers are charged for
  a window in which they were structurally unable to repay.
- Liquidation eligibility should be evaluated on **unpaused time**, not wall-clock.

### 2.4 Beacon proxy — the token is upgradeable

All Stock Tokens share one implementation behind a beacon. Transfer semantics, the multiplier
mechanism, and the burn powers can all change for every token simultaneously. Assume the interface
is stable; assume the **policy is not**.

### 2.5 Collateral is a Jersey debt token, not equity

Stock Tokens are **tokenised debt securities** issued by Robinhood Assets (Jersey) Limited, giving
economic exposure with **no legal or beneficial right in the underlying share**. Collateral quality
is Robinhood-Jersey counterparty risk. This belongs in risk parameters and in plain language in the
UI — especially alongside any safety claim.

---

## 3. Contract surface (v1)

Solidity, Robinhood Chain (Arbitrum Orbit, EVM). Borrow asset: **USDG**
(`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`).

```
AssayPool.sol          ERC-4626-style lender vault, USDG deposits, share accounting
                       borrow-index accrual (port the Sui curve, keep the R2-2 bounds
                       and saturating math — that logic was correct and is chain-agnostic)

AssayMarkets.sol       per-collateral registry: Stock Token address, Chainlink feed,
                       ltvBps, liqThresholdBps, liqBonusBps, per-collateral cap
                       (the isolation cap from the Sui design, which held up in audit)

AssayBorrow.sol        openPosition: pull collateral, read latestRoundData + uiMultiplier,
                       enforce LTV on-chain, disburse USDG
                       repay: >= owed with change returned (fixes known-open F5 by
                       construction — do NOT port the exact-equality bug)

AssayLiquidate.sol     permissionless. health = balanceOfUI x price x liqThreshold / debt
                       seize only debt x (1 + bonus), REFUND SURPLUS (F3)
                       reconcile balanceOf before seizing (adminBurn shortfall path)

AssayGuard.sol         oracle staleness + sequencer-uptime checks, pause-aware accrual,
                       shortfall accounting, timelocked admin (R5-2)
```

**Reuse rather than re-derive:** OpenZeppelin for ERC-20/4626/AccessControl/TimelockController,
and Chainlink's `AggregatorV3Interface`. The audit findings that were about *hand-rolled*
primitives (low-order pubkey validation, BCS byte pinning, limb splitting) vanish entirely —
that whole class of bug came from writing crypto by hand.

**Oracle discipline to port from `operator/pyth.mjs`** — that layer was repeatedly confirmed sound:
staleness bounds, confidence-interval rejection, fail-closed on error, market-hours awareness. On
an L2 also check **sequencer uptime** before trusting a feed; this is the standard Arbitrum
L2 gotcha and is not in the Sui design because it could not be.

---

## 4. The agent / MCP flow

The half that is **available today** and is the actual product hook:

```
1. User connects their own MCP client to Robinhood's Trading MCP
   -> "connect a third-party AI agent to a dedicated Robinhood account"
   -> agent places the equity order under the user's own credentials.
      Assay never holds the account. No custody, no licensing exposure.

2. Robinhood settles the position as a Stock Token in the user's
   self-custody Robinhood Wallet on Robinhood Chain.

3. Assay dApp (or an Assay MCP tool) reads the wallet, prices via Chainlink,
   quotes a borrow.

4. User approves + openPosition in one tx. USDG lands in their wallet.
   Collateral sits in AssayPool, on the same chain, no bridge.
```

Assay is **never** a custodian at any step, which preserves the non-custodial property that the
custody alternative would have destroyed.

**Worth building: an Assay MCP server.** If the user already drives Robinhood through MCP, exposing
`assay.quote`, `assay.borrow`, `assay.health`, `assay.repay` as MCP tools makes the whole flow one
conversation. That is a genuine differentiator and is small next to the contract work.

**Verify before relying on it:** Trading MCP availability by jurisdiction, whether agent trading
covers the equities that become Stock Tokens, and the settlement path/latency from order fill to
token in wallet.

---

## 5. Phasing

| Phase | Work | Gate |
|---|---|---|
| **0 — Spike** (days) | Deploy a trivial receiver on RH Chain, transfer a Stock Token in, read `latestRoundData` + `uiMultiplier`. Proves the deny-list finding empirically. | Nothing moves until this passes |
| **1 — Core** (2–3 wks) | AssayPool + Markets + Borrow + Liquidate, on-chain LTV, surplus refund, `balanceOfUI` pricing, sequencer check | Full test suite incl. **mutation tests on every guard** |
| **2 — RH hazards** (1 wk) | `adminBurn` reconciliation + shortfall path, pause-aware accrual, scheduled-multiplier handling | Fork tests against real Stock Tokens |
| **3 — Agent** (1–2 wks) | Assay MCP server, dApp borrow flow, Robinhood Wallet integration | End-to-end on testnet |
| **4 — Audit** | Fresh adversarial rounds on the Solidity | All-clean round before mainnet |
| **5 — Hybrid** (optional) | Sui pools for non-Robinhood RWA; shared markets/risk config. **CCIP** already moves Stock Tokens cross-chain — evaluate, do not assume Sui is a supported lane. | — |

---

## 6. Open questions

1. **Sequencer uptime feed** — does Chainlink publish one for Robinhood Chain? Without it, an L2
   outage means stale prices are trusted. Blocks Phase 1 liquidation safety.
2. **Feed heartbeats and deviation thresholds** per Stock Token — sets the staleness bound and
   therefore the safe LTV.
3. **Off-hours behaviour** — do equity feeds update when US markets are closed, or go stale
   nightly? Determines whether 24/7 borrowing is safe or needs a wider haircut off-hours.
4. **Has `adminBurn` ever been used?** Check historical `Transfer`-to-zero events from admin roles.
   Frequency changes whether this is theoretical or operational.
5. **Who holds `ADMIN_BURNER_ROLE` / `TOKEN_PAUSER_ROLE`?** Read the registry. An EOA and a
   timelocked multisig are very different risk profiles.
6. **Trading MCP jurisdiction coverage** vs Stock Token availability (120+ countries, varies).

---

## 7. What this does to the existing Sui work

Not wasted, but be honest about what transfers:

- **The Move implementation does not port.** ~2,000 lines stay on Sui.
- **The design does.** Section 1's invariant table is the actual output of six audit rounds, and
  every item on it was learned by finding a real hole.
- **The audit method ports completely** — adversarial rounds with independent verification, and
  mutation-testing every guard. That method caught four guards in this repo that were deletable
  with a fully green suite, and three false claims in commit messages. Use it from day one on the
  Solidity rather than bolting it on at the end.
- **The Sui deployment remains valid** for non-Robinhood RWA collateral, if the hybrid is pursued.
