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

    /// The L2 sequencer uptime feed, or address(0) if none exists on this chain.
    ///
    /// UNRESOLVED AS OF DEPLOYMENT (2026-07-20). Robinhood's docs state that "Chainlink provides
    /// an L2 Sequencer Uptime Feed for this; check it before reading any price." That feed could
    /// not be found: Robinhood Chain is absent from Chainlink's canonical L2 sequencer feed list,
    /// absent from the Robinhood feed directory (55 entries, all price feeds), returns nothing on
    /// a name search, and every contract deployed by Chainlink's deployer on this chain resolves
    /// to a price feed. Their docs have already been wrong once on this chain (they described
    /// transfer restrictions the deployed token does not have), so the doc claim alone is not
    /// evidence.
    ///
    /// Setting this to address(0) SKIPS the check and accepts a real, named risk: during a
    /// sequencer outage no transaction executes, so nothing can be liquidated; on resumption a
    /// backlog runs against prices users had no chance to react to. The 24h heartbeat means
    /// staleness detection would not catch an outage for a full day, which is far too slow to
    /// substitute.
    ///
    /// Compensating controls REQUIRED when this is address(0):
    ///   - the LTV/liquidation buffer must absorb an outage-length gap (this is a second reason
    ///     the buffer is 20pp, not a thin one)
    ///   - an off-chain keeper must pause the pool on detected outage
    /// Revisit before mainnet: if a real uptime feed appears, deploy with it set.
    AggregatorV3Interface public immutable sequencerUptimeFeed;

    /// True when this deployment has no sequencer uptime feed and is running on compensating
    /// controls instead. Exposed so the UI and any monitoring can surface it rather than assume.
    bool public immutable sequencerCheckDisabled;
    mapping(address => FeedConfig) internal _feeds;

    constructor(AggregatorV3Interface sequencerUptimeFeed_) {
        sequencerUptimeFeed = sequencerUptimeFeed_;
        sequencerCheckDisabled = address(sequencerUptimeFeed_) == address(0);
    }

    /// Reverts unless the L2 sequencer is up and has been up for the full grace period.
    /// Standard Arbitrum-stack requirement. It has no analogue in the Sui design because Sui has
    /// no sequencer — this is a category of failure that only exists on an L2.
    function _requireSequencerUp() internal view {
        // No feed on this chain — see the note on `sequencerUptimeFeed`. Deliberately explicit
        // rather than a silent no-op, so this cannot be mistaken for a passing check.
        if (sequencerCheckDisabled) return;
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

        // MARKET HOLIDAYS. The calendar above knows weekends but not holidays, so on Thanksgiving
        // it reports "in session" while the feed has not published since the previous trading
        // day's close. The staleness bound cannot catch it — an 18-24h holiday gap fits inside a
        // 25h bound. So: if we believe we are in session, the feed must have published AT OR AFTER
        // today's open. On a holiday the last print is from yesterday and this correctly refuses.
        //
        // A very quiet stock that has not moved 0.5% since the open would also be refused. That is
        // the conservative direction — declining to lend on an unconfirmed price — and is accepted.
        if (inSession && updatedAt < _sessionOpenOf(block.timestamp)) {
            inSession = false;
        }

        return (uint256(answer), c.decimals, inSession);
    }

    /// US equity regular session, computed CONSERVATIVELY across both US time zones.
    ///
    /// Eastern time is UTC-5 in winter (EST) and UTC-4 in summer (EDT), so the session maps to a
    /// different UTC window depending on the date:
    ///     EST  09:30-16:00 ET  ->  14:30-21:00 UTC
    ///     EDT  09:30-16:00 ET  ->  13:30-20:00 UTC
    ///
    /// A previous version hardcoded the EST window. During EDT that reported "in session" for the
    /// hour AFTER the market closed — the unsafe direction, since it would admit new borrowing
    /// against a market that had already shut.
    ///
    /// Rather than implement the DST calendar on-chain, this returns the INTERSECTION of the two
    /// windows: 14:30-20:00 UTC. It is therefore never open when the market is shut, and gives up
    /// the first hour of an EST session and the last hour of an EDT one. Losing an hour of
    /// borrowing availability is the correct trade against ever lending into a closed market; a
    /// proper DST implementation would recover it.
    function isUsMarketHours(uint256 ts) public pure returns (bool) {
        if (!_isWeekday(ts)) return false;
        uint256 secondsOfDayUtc = ts % 86400;
        return secondsOfDayUtc >= SESSION_OPEN_UTC && secondsOfDayUtc < SESSION_CLOSE_UTC;
    }

    /// 14:30 UTC — the later of the two session opens (EST). Conservative.
    uint256 public constant SESSION_OPEN_UTC = 14 hours + 30 minutes;
    /// 20:00 UTC — the earlier of the two session closes (EDT). Conservative.
    uint256 public constant SESSION_CLOSE_UTC = 20 hours;

    function _isWeekday(uint256 ts) internal pure returns (bool) {
        // 1970-01-01 was a Thursday: shift so 0 = Monday.
        uint256 dow = ((ts / 86400) + 3) % 7;
        return dow < 5;
    }

    /// The start of today's session, in absolute time.
    function _sessionOpenOf(uint256 ts) internal pure returns (uint256) {
        return (ts / 86400) * 86400 + SESSION_OPEN_UTC;
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
