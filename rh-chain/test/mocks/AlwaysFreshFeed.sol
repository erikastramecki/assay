// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// A Chainlink-shaped feed that reports a FIXED REAL PRICE at the CURRENT block time.
///
/// Only for local-fork demos. Forking pins the real feed's `updatedAt` at fork height, and the
/// 2-day parameter timelock forces the clock past it, so the genuine feed always reads as stale
/// on a fork. The price here is copied from mainnet; only the timestamp is synthetic.
contract AlwaysFreshFeed {
    int256 public immutable price;
    uint8 public constant decimals = 8;
    constructor(int256 p) { price = p; }
    function description() external pure returns (string memory) { return "AlwaysFresh (local fork only)"; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}
