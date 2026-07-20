// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Chainlink's standard feed interface. Robinhood Chain Stock Token feeds and the L2 sequencer
/// uptime feed both expose exactly this — reading a stock price is identical to reading any
/// other Chainlink feed.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
