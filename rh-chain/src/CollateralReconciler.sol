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
    /// Raw units this pool believes it holds for `token`, summed over open positions.
    mapping(address => uint256) public recordedRaw;

    /// Raw units known to have been destroyed or otherwise lost under this pool's feet.
    mapping(address => uint256) public shortfallRaw;

    event CollateralShortfall(address indexed token, uint256 recorded, uint256 actual, uint256 shortfall);
    event ShortfallSocialised(address indexed token, uint256 amount);

    error InsufficientRecorded(address token, uint256 have, uint256 want);

    /// Reconcile the ledger against reality. MUST be called before any valuation or seizure.
    ///
    /// Returns the shortfall discovered on this call (0 in the normal case). Deliberately does not
    /// revert on shortfall: reverting would freeze repayment for every other borrower and turn a
    /// partial loss into a total one.
    function _reconcile(address token) internal returns (uint256 newShortfall) {
        uint256 recorded = recordedRaw[token];
        uint256 actual = IERC20(token).balanceOf(address(this));
        if (actual >= recorded) return 0;

        newShortfall = recorded - actual;
        recordedRaw[token] = actual;
        shortfallRaw[token] += newShortfall;
        emit CollateralShortfall(token, recorded, actual, newShortfall);
    }

    /// Economic value of `rawAmount` units, in the price feed's units.
    ///
    /// Applies `uiMultiplier()` live. This is the single most important line in the file: a pool
    /// that values raw balances is correct until the first stock split and catastrophically wrong
    /// immediately after, in whichever direction the split went.
    function _valueOf(address token, uint256 rawAmount, uint256 price, uint8 priceDecimals)
        internal
        view
        returns (uint256)
    {
        uint256 uiAmount = _uiAmount(token, rawAmount);
        return (uiAmount * price) / (10 ** priceDecimals);
    }

    /// Raw units converted to share-equivalent units via the live corporate-action multiplier.
    function _uiAmount(address token, uint256 rawAmount) internal view returns (uint256) {
        IScaledUI s = IScaledUI(token);
        uint256 mult = s.uiMultiplier();
        // DENOMINATOR is 1e18 in Robinhood's ERC20ScaledUIUpgradeable.
        return (rawAmount * mult) / 1e18;
    }

    /// Is a corporate action scheduled but not yet effective? Surfacing this lets the UI and the
    /// keeper warn before a split silently rescales every position.
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
