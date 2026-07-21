// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// Chainlink feed addresses on Robinhood Chain (chainId 4663), pulled from Chainlink's feed
/// directory rather than transcribed from a docs page. Every feed is 86400s heartbeat with a
/// 0.5% deviation trigger — see StaleFeedGuard for why that shapes the staleness bound.
///
/// Regenerate: node script/fetch-feeds.mjs
library RobinhoodFeeds {
    address internal constant AAPL_USD = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0; // dec=8 heartbeat=86400s dev=0.5%
    address internal constant TSLA_USD = 0x4A1166a659A55625345e9515b32adECea5547C38; // dec=8 heartbeat=86400s dev=0.5%
    address internal constant NVDA_USD = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15; // dec=8 heartbeat=86400s dev=0.5%
    address internal constant MSFT_USD = 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E; // dec=8 heartbeat=86400s dev=0.5%
    address internal constant GOOGL_USD = 0xF6f373a037c30F0e5010d854385cA89185AE638b; // dec=8 heartbeat=86400s dev=0.5%
    address internal constant AMZN_USD = 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C; // dec=8 heartbeat=86400s dev=0.5%
    address internal constant META_USD = 0x7C38C00C30BEe9378381E7B6135d7283356D71b1; // dec=8 heartbeat=86400s dev=0.5%
    address internal constant SPY_USD = 0x319724394D3A0e3669269846abE664Cd621f9f6A; // dec=8 heartbeat=86400s dev=0.5%
    address internal constant QQQ_USD = 0x80901d846d5D7B030F26B480776EE3b29374C2ae; // dec=8 heartbeat=86400s dev=0.5%

    uint32 internal constant HEARTBEAT = 86_400;
    uint32 internal constant RECOMMENDED_MAX_STALENESS = 90_000; // heartbeat + 1h grace
}
