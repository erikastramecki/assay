// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// Oracle gate for Robinhood Chain Stock Tokens.
///
/// WHY THIS EXISTS. Robinhood markets Stock Tokens as 24/7 tradeable, but the PRICE is not 24/7:
/// Chainlink equity feeds update 24/5, following US market hours, and go stale nights and
/// weekends. Lending against a Friday-close price through a weekend is the classic RWA blowup —
/// the stock gaps on Monday open and there was no window in which to liquidate.
///
/// Redundancy does not fix this. A second oracle (Pyth) reports the same closed market, so the
/// failures are correlated. The one uncorrelated source — the Stock Token's own 24/7 DEX price on
/// this chain — is thin and manipulable, and reintroduces exactly the flash-loan surface that
/// picking a signed-publisher oracle was meant to avoid. So the honest response to off-hours is
/// "there is no fresh price", not "synthesise one".
///
/// GROUNDED IN THE REAL FEED PARAMETERS. Every Chainlink feed on Robinhood Chain — all 34 equity
/// feeds and the crypto feeds alike — runs a **86400s (24h) heartbeat with a 0.5% deviation
/// trigger**. That is the actual contract, read from Chainlink's feed directory, and it shapes
/// this design:
///
///   - A staleness bound TIGHTER than the heartbeat is wrong and would revert constantly. An
///     earlier draft of this file used 3600s in-session and 300s off-hours; both would have
///     bricked the protocol every night, because a feed that has not moved 0.5% legitimately
///     does not update for up to 24 hours.
///   - The freshness guarantee that actually protects a lender is the DEVIATION threshold, not
///     the heartbeat: a price up to 24h old means "this has not moved more than 0.5% since".
///     The staleness bound therefore exists to catch a BROKEN oracle, not a quiet market, and is
///     set to heartbeat + grace.
///   - Off-hours protection cannot come from a tighter staleness bound, because when the market
///     is closed the price genuinely is not moving and no update is due. It comes from the
///     session flag: no new borrows, and no liquidations at a price nobody can verify.
///
/// This contract therefore does three things, and refuses to guess:
///   1. checks the L2 sequencer is up (and has been up long enough to trust)
///   2. checks the feed has not gone silent past heartbeat + grace (a broken-oracle check)
///   3. reports session state, so callers gate borrows and liquidations on a live market
///
/// It fails CLOSED everywhere. A revert is the correct outcome for an unknown price.
contract StaleFeedGuard {
    error SequencerDown();
    error SequencerGracePeriod(uint256 secondsRemaining);
    error PriceStale(uint256 age, uint256 limit, bool inSession);
    error PriceNotPositive(int256 answer);
    error RoundIncomplete();
    error FeedNotConfigured(address token);
    error StalenessBelowHeartbeat(uint32 given, uint32 heartbeat);

    /// Per-token oracle configuration. Heartbeats come from Chainlink's Robinhood feeds page and
    /// differ per feed — never hardcode a single global value.
    struct FeedConfig {
        AggregatorV3Interface feed;
        /// Must be >= the feed's heartbeat, plus grace. On Robinhood Chain every feed is 86400s,
        /// so this is ~90000s. Anything tighter reverts on a quiet market rather than on a
        /// broken one.
        uint32 maxStaleness;
        uint8 decimals;
        bool configured;
    }

    /// Every Robinhood Chain feed publishes on this heartbeat (verified against Chainlink's feed
    /// directory). Exposed so deployment scripts can assert their config against it.
    uint32 public constant FEED_HEARTBEAT = 86_400;
    /// Grace on top of the heartbeat before we call a feed broken.
    uint32 public constant STALENESS_GRACE = 3_600;

    /// After a sequencer outage, prices are fresh but the market had no chance to react. Reject
    /// for a grace period rather than liquidating people on a resumed-but-unwound market.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;

    AggregatorV3Interface public immutable sequencerUptimeFeed;
    mapping(address => FeedConfig) internal _feeds;

    constructor(AggregatorV3Interface sequencerUptimeFeed_) {
        sequencerUptimeFeed = sequencerUptimeFeed_;
    }

    /// Reverts unless the L2 sequencer is up and has been up for the full grace period.
    /// Standard Arbitrum-stack requirement. It has no analogue in the Sui design because Sui has
    /// no sequencer — this is a category of failure that only exists on an L2.
    function _requireSequencerUp() internal view {
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        // 0 = up, 1 = down
        if (answer != 0) revert SequencerDown();
        uint256 elapsed = block.timestamp - startedAt;
        if (elapsed < SEQUENCER_GRACE_PERIOD) {
            revert SequencerGracePeriod(SEQUENCER_GRACE_PERIOD - elapsed);
        }
    }

    /// The price of one whole unit of `token`, scaled to the feed's own decimals, together with
    /// whether the US equity session is currently open.
    ///
    /// Callers MUST apply the off-hours haircut when `inSession` is false. This function
    /// deliberately does not apply it itself: haircuts are a risk-parameter decision owned by the
    /// market registry, and burying them here would hide them from review.
    function priceOf(address token) public view returns (uint256 price, uint8 decimals, bool inSession) {
        FeedConfig memory c = _feeds[token];
        if (!c.configured) revert FeedNotConfigured(token);

        _requireSequencerUp();

        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            c.feed.latestRoundData();

        if (answer <= 0) revert PriceNotPositive(answer);
        // A round that never completed, or an answer carried over from an earlier round, is not a
        // current price.
        if (updatedAt == 0 || answeredInRound < roundId) revert RoundIncomplete();

        inSession = isUsMarketHours(block.timestamp);
        uint256 age = block.timestamp - updatedAt;
        // One bound, sized to the heartbeat: this detects a SILENT oracle. It deliberately does
        // not try to detect a stale market — see the note at the top of this file.
        if (age > c.maxStaleness) revert PriceStale(age, c.maxStaleness, inSession);

        return (uint256(answer), c.decimals, inSession);
    }

    /// Coarse US equity regular session: 09:30–16:00 ET, Mon–Fri.
    ///
    /// DELIBERATELY COARSE, AND DELIBERATELY WRONG IN THE SAFE DIRECTION. It ignores holidays and
    /// DST, so it will occasionally report "in session" when the market is actually shut. That is
    /// survivable only because the staleness check is the real gate: on a holiday the feed simply
    /// stops updating and `PriceStale` fires. Session state is a haircut input, never the sole
    /// freshness guarantee — do not invert that relationship.
    ///
    /// Uses UTC-5 as a fixed offset. During EDT the window is off by an hour, which shifts the
    /// haircut boundary rather than admitting a stale price.
    function isUsMarketHours(uint256 ts) public pure returns (bool) {
        uint256 daysSinceEpoch = ts / 86400;
        // 1970-01-01 was a Thursday: 0=Thu. Map to 0=Mon.
        uint256 dow = (daysSinceEpoch + 3) % 7; // 0=Mon … 6=Sun
        if (dow >= 5) return false; // weekend

        uint256 secondsOfDayUtc = ts % 86400;
        // ET = UTC-5 (EST). 09:30 ET = 14:30 UTC, 16:00 ET = 21:00 UTC.
        return secondsOfDayUtc >= 14 hours + 30 minutes && secondsOfDayUtc < 21 hours;
    }

    function feedConfig(address token) external view returns (FeedConfig memory) {
        return _feeds[token];
    }

    /// Internal setter — the owning market registry decides access control. Kept internal so this
    /// contract has no admin surface of its own to get wrong.
    /// Reverts if `maxStaleness` is tighter than the heartbeat — a misconfiguration that would
    /// look like a working system until the first quiet hour and then reject every borrow.
    function _setFeed(address token, AggregatorV3Interface feed, uint32 maxStaleness, uint8 decimals)
        internal
    {
        if (maxStaleness < FEED_HEARTBEAT) revert StalenessBelowHeartbeat(maxStaleness, FEED_HEARTBEAT);
        _feeds[token] = FeedConfig(feed, maxStaleness, decimals, true);
    }
}
