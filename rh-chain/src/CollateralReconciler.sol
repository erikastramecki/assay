// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IScaledUI} from "./interfaces/IScaledUI.sol";

/// Collateral accounting for a token whose issuer can destroy or rescale it underneath you.
///
/// WHY THIS EXISTS. Two properties of Robinhood Stock Tokens, both read from the deployed
/// contract rather than from documentation:
///
///   1. `adminBurn(from, amount)` under ADMIN_BURNER_ROLE destroys tokens from ANY address with
///      no pause check and no block check. Verified on-chain: that role is held by a plain EOA,
///      with no multisig and no timelock anywhere in the stack. Collateral can therefore vanish
///      from a live pool, leaving a loan unsecured with nothing to liquidate.
///
///   2. `balanceOf()` is the raw amount and is stable; `balanceOfUI()` is the share-equivalent and
///      changes on corporate actions via `uiMultiplier()`. The multiplier can be SCHEDULED with a
///      future `effectiveAt`, so a position's economic size changes with no transaction touching
///      this pool.
///
/// Consequences, which together are the whole point of this contract:
///   - A stored collateral figure is a claim about the past. Never price against it.
///   - Value is `balanceOfUI x price`, never `balanceOf x price`. Pricing the raw balance
///     misprices every position by the split ratio the instant a split lands.
///   - The multiplier must be re-read on every valuation. Caching it is a bug with a delayed fuse.
///   - When actual < recorded, the shortfall is REAL and must be handled explicitly. Reverting
///     would trap every borrower's remaining collateral; silently ignoring it would let the pool
///     lend against tokens that no longer exist.
abstract contract CollateralReconciler {
    /// NOMINAL raw units this pool holds for `token`: the sum of open positions' posted
    /// collateral. Deliberately NOT reduced when the issuer burns — that would destroy the
    /// denominator the pro-rata share is computed from.
    mapping(address => uint256) public recordedRaw;

    /// Cumulative raw units destroyed under this pool's feet, for reporting.
    mapping(address => uint256) public shortfallRaw;

    event CollateralShortfall(address indexed token, uint256 recorded, uint256 actual, uint256 shortfall);

    error InsufficientRecorded(address token, uint256 have, uint256 want);

    /// A position's ACTUAL entitlement, pro-rata against what survives.
    ///
    /// THIS IS THE FIX FOR THE adminBurn ORDERING BUG. `recordedRaw` is per-TOKEN while positions
    /// are per-BORROWER, so an earlier version clamped a per-borrower entitlement against the
    /// pooled balance: Alice and Bob each post 10, Robinhood burns 10, and whoever repaid FIRST
    /// recovered all 10 — including the other's — while the second recovered nothing. Scaling by
    /// (surviving / nominal) socialises the loss across every holder of that token, which is the
    /// policy this contract always claimed to implement and previously did not.
    ///
    /// Alice and Bob each get 5, in either order.
    function _effectiveCollateral(address token, uint256 nominalRaw) internal view returns (uint256) {
        uint256 nominal = recordedRaw[token];
        if (nominal == 0) return 0;
        uint256 actual = IERC20(token).balanceOf(address(this));
        if (actual >= nominal) return nominalRaw; // nothing lost
        return (nominalRaw * actual) / nominal;
    }

    /// Record any newly-discovered shortfall. Reporting only — it must NOT adjust `recordedRaw`,
    /// because the nominal total is what `_effectiveCollateral` divides by.
    function _reconcile(address token) internal returns (uint256 newShortfall) {
        uint256 nominal = recordedRaw[token];
        uint256 actual = IERC20(token).balanceOf(address(this));
        if (actual >= nominal) return 0;
        uint256 total = nominal - actual;
        uint256 known = shortfallRaw[token];
        if (total <= known) return 0;
        newShortfall = total - known;
        shortfallRaw[token] = total;
        emit CollateralShortfall(token, nominal, actual, total);
    }

    /// Economic value of `rawAmount`, priced via the live corporate-action multiplier.
    function _uiAmount(address token, uint256 rawAmount) internal view returns (uint256) {
        return (rawAmount * IScaledUI(token).uiMultiplier()) / 1e18;
    }

    /// Is a corporate action scheduled but not yet effective? Lets the UI and keeper warn before
    /// a split silently rescales every position.
    function pendingMultiplier(address token) external view returns (uint256 newMultiplier, uint256 effectiveAt) {
        try IScaledUI(token).newUIMultiplier() returns (uint256 m, uint256 at) {
            return (m, at);
        } catch {
            return (0, 0);
        }
    }

    function _creditCollateral(address token, uint256 rawAmount) internal {
        recordedRaw[token] += rawAmount;
    }

    function _debitCollateral(address token, uint256 rawAmount) internal {
        uint256 have = recordedRaw[token];
        if (have < rawAmount) revert InsufficientRecorded(token, have, rawAmount);
        recordedRaw[token] = have - rawAmount;
    }
}
