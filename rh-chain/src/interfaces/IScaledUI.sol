// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// The ERC-8056 "Scaled UI Amount" surface Robinhood Stock Tokens implement.
/// `balanceOf` is the raw amount; `balanceOfUI` is the share-equivalent after corporate actions.
interface IScaledUI {
    function uiMultiplier() external view returns (uint256);
    function balanceOfUI(address account) external view returns (uint256);
    function totalSupplyUI() external view returns (uint256);
    /// Scheduled-but-not-yet-effective multiplier, if the token exposes it.
    function newUIMultiplier() external view returns (uint256 newMultiplier, uint256 effectiveAt);
}
