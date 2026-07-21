// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StaleFeedGuard} from "../src/StaleFeedGuard.sol";
import {CollateralReconciler} from "../src/CollateralReconciler.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------- mocks

contract MockFeed is AggregatorV3Interface {
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;
    uint8 public dec;

    constructor(int256 a, uint8 d) { answer = a; dec = d; updatedAt = block.timestamp; startedAt = block.timestamp; }
    function set(int256 a, uint256 u) external { answer = a; updatedAt = u; }
    function setRounds(uint80 r, uint80 air) external { roundId = r; answeredInRound = air; }
    function setStartedAt(uint256 s) external { startedAt = s; }
    function decimals() external view returns (uint8) { return dec; }
    function description() external pure returns (string memory) { return "mock"; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// Mirrors Robinhood's Stock Token surface: raw balances plus a corporate-action multiplier,
/// and an adminBurn that destroys tokens from any holder with no pause or block check.
contract MockStock is ERC20 {
    uint256 public uiMultiplier = 1e18;
    uint256 internal _newMult;
    uint256 internal _effectiveAt;

    constructor() ERC20("Apple Robinhood Token", "AAPL") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function adminBurn(address from, uint256 amt) external { _burn(from, amt); }
    function setMultiplier(uint256 m) external { uiMultiplier = m; }
    function schedule(uint256 m, uint256 at) external { _newMult = m; _effectiveAt = at; }
    function newUIMultiplier() external view returns (uint256, uint256) { return (_newMult, _effectiveAt); }
    function balanceOfUI(address a) external view returns (uint256) { return balanceOf(a) * uiMultiplier / 1e18; }
    function totalSupplyUI() external view returns (uint256) { return totalSupply() * uiMultiplier / 1e18; }
}

contract GuardHarness is StaleFeedGuard {
    constructor(AggregatorV3Interface s) StaleFeedGuard(s) {}
    function setFeed(address t, AggregatorV3Interface f, uint32 maxStale, uint8 d) external {
        _setFeed(t, f, maxStale, d);
    }
}

contract ReconcilerHarness is CollateralReconciler {
    function reconcile(address t) external returns (uint256) { return _reconcile(t); }
    function credit(address t, uint256 a) external { _creditCollateral(t, a); }
    function debit(address t, uint256 a) external { _debitCollateral(t, a); }
    function valueOf(address t, uint256 raw, uint256 p, uint8 d) external view returns (uint256) {
        return _valueOf(t, raw, p, d);
    }
}

// ---------------------------------------------------------------- tests

contract StaleFeedGuardTest is Test {
    GuardHarness g;
    MockFeed seq;
    MockFeed px;
    address constant TOK = address(0xAA);

    // 2025-07-21 15:00 UTC = a MONDAY, 11:00 ET — inside the US equity session.
    // (Verified against the calendar; the contract's (days+3)%7 mapping agrees.)
    uint256 constant MON_IN_SESSION = 1_753_110_000;

    function setUp() public {
        vm.warp(MON_IN_SESSION);
        seq = new MockFeed(0, 0);            // 0 = sequencer up
        seq.setStartedAt(block.timestamp - 2 days); // well past the grace period
        px = new MockFeed(200e8, 8);
        g = new GuardHarness(seq);
        // heartbeat + grace, matching the real 86400s Robinhood Chain feeds
        g.setFeed(TOK, px, 90_000, 8);
    }

    function test_freshPriceInSession() public view {
        (uint256 p, uint8 d, bool inSession) = g.priceOf(TOK);
        assertEq(p, 200e8);
        assertEq(d, 8);
        assertTrue(inSession);
    }

    /// The core protection: a Friday-close price must NOT be usable on Sunday.
    function test_weekendStalePriceIsRejected() public {
        uint256 fridayClose = MON_IN_SESSION + 4 days; // Mon + 4 = Friday
        px.set(200e8, fridayClose);
        uint256 sunday = fridayClose + 2 days; // > heartbeat + grace, so the feed reads as silent
        vm.warp(sunday);
        assertFalse(g.isUsMarketHours(sunday), "fixture must actually be a weekend");
        vm.expectRevert();
        g.priceOf(TOK);
    }

    /// A quiet market must NOT revert. Every Robinhood Chain feed is 86400s/0.5%, so a price
    /// that is hours old simply means the stock has not moved 0.5%. An earlier draft used a
    /// 300s off-hours bound, which would have rejected every borrow overnight.
    function test_quietMarketDoesNotRevert() public {
        uint256 night = (MON_IN_SESSION / 86400) * 86400 + 3 hours;
        px.set(200e8, night - 6 hours); // 6h old: normal for a 24h heartbeat
        vm.warp(night);
        assertFalse(g.isUsMarketHours(night), "fixture is off-hours");
        (uint256 p,, bool inSession) = g.priceOf(TOK);
        assertEq(p, 200e8);
        assertFalse(inSession, "must report off-hours so callers can gate borrows");
    }

    /// But a SILENT oracle — past heartbeat + grace — is a broken oracle and must revert.
    function test_silentOracleBeyondHeartbeatReverts() public {
        uint256 t = MON_IN_SESSION;
        px.set(200e8, t - 90_001);
        vm.warp(t);
        vm.expectRevert();
        g.priceOf(TOK);
    }

    /// Configuring a bound tighter than the heartbeat is a misconfiguration that would look fine
    /// until the first quiet hour. Reject it at config time.
    function test_stalenessBelowHeartbeatIsRejected() public {
        MockFeed f2 = new MockFeed(100e8, 8);
        vm.expectRevert(
            abi.encodeWithSelector(StaleFeedGuard.StalenessBelowHeartbeat.selector, uint32(3600), uint32(86_400))
        );
        g.setFeed(address(0xCC), f2, 3600, 8);
    }

    function test_sequencerDownRejects() public {
        seq.set(1, block.timestamp); // 1 = down
        vm.expectRevert(StaleFeedGuard.SequencerDown.selector);
        g.priceOf(TOK);
    }

    /// A price can be fresh while the market has had no chance to react to a resumed sequencer.
    function test_sequencerGracePeriodRejects() public {
        seq.setStartedAt(block.timestamp - 60); // came back 60s ago
        vm.expectRevert();
        g.priceOf(TOK);
    }

    function test_nonPositiveAnswerRejects() public {
        px.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(StaleFeedGuard.PriceNotPositive.selector, int256(0)));
        g.priceOf(TOK);
    }

    function test_carriedOverRoundRejects() public {
        px.setRounds(5, 4); // answeredInRound < roundId
        vm.expectRevert(StaleFeedGuard.RoundIncomplete.selector);
        g.priceOf(TOK);
    }

    function test_unconfiguredFeedRejects() public {
        vm.expectRevert(abi.encodeWithSelector(StaleFeedGuard.FeedNotConfigured.selector, address(0xBB)));
        g.priceOf(address(0xBB));
    }

    function test_marketHoursBoundaries() public view {
        uint256 day = (MON_IN_SESSION / 86400) * 86400;
        assertFalse(g.isUsMarketHours(day + 14 hours + 29 minutes)); // 09:29 ET
        assertTrue(g.isUsMarketHours(day + 14 hours + 30 minutes));  // 09:30 ET open
        assertTrue(g.isUsMarketHours(day + 20 hours + 59 minutes));  // 15:59 ET
        assertFalse(g.isUsMarketHours(day + 21 hours));              // 16:00 ET close
    }

    function test_weekendIsNeverInSession() public view {
        uint256 day = (MON_IN_SESSION / 86400) * 86400;
        // Monday + 5 = Saturday, +6 = Sunday. Midday both days, when a naive
        // hour-of-day check would wrongly report "in session".
        assertFalse(g.isUsMarketHours(day + 5 days + 16 hours), "Saturday");
        assertFalse(g.isUsMarketHours(day + 6 days + 16 hours), "Sunday");
        // and the weekdays around them ARE in session, so the test is not vacuous
        assertTrue(g.isUsMarketHours(day + 4 days + 16 hours), "Friday");
        assertTrue(g.isUsMarketHours(day + 7 days + 16 hours), "next Monday");
    }
}

contract CollateralReconcilerTest is Test {
    ReconcilerHarness r;
    MockStock tok;

    function setUp() public {
        r = new ReconcilerHarness();
        tok = new MockStock();
        tok.mint(address(r), 100e18);
        r.credit(address(tok), 100e18);
    }

    function test_noShortfallWhenBalancesAgree() public {
        assertEq(r.reconcile(address(tok)), 0);
        assertEq(r.recordedRaw(address(tok)), 100e18);
    }

    /// THE adminBurn CASE. Robinhood destroys collateral out of the live pool; the ledger must
    /// notice, record the loss, and NOT revert — reverting would freeze every other borrower.
    function test_adminBurnIsDetectedAndRecorded() public {
        tok.adminBurn(address(r), 30e18);
        uint256 s = r.reconcile(address(tok));
        assertEq(s, 30e18, "shortfall must equal the burned amount");
        assertEq(r.recordedRaw(address(tok)), 70e18, "ledger must follow reality down");
        assertEq(r.shortfallRaw(address(tok)), 30e18);
        // and it must be idempotent — a second reconcile finds nothing new
        assertEq(r.reconcile(address(tok)), 0);
    }

    function test_totalBurnDoesNotRevert() public {
        tok.adminBurn(address(r), 100e18);
        assertEq(r.reconcile(address(tok)), 100e18);
        assertEq(r.recordedRaw(address(tok)), 0);
    }

    /// THE CORPORATE-ACTION CASE. A 4:1 split quadruples the share-equivalent amount. Valuing the
    /// RAW balance would understate the position by 4x and liquidate a healthy loan.
    function test_valuationFollowsTheCorporateActionMultiplier() public {
        uint256 before_ = r.valueOf(address(tok), 100e18, 200e8, 8);
        assertEq(before_, 100e18 * 200); // 100 shares @ $200

        tok.setMultiplier(4e18); // 4:1 split
        uint256 after_ = r.valueOf(address(tok), 100e18, 50e8, 8); // price adjusts to $50
        assertEq(after_, 400e18 * 50, "must value 400 share-equivalents, not 100");
        assertEq(before_, after_, "economic value is unchanged by a split");
    }

    function test_pendingMultiplierIsVisibleBeforeItFires() public {
        tok.schedule(4e18, block.timestamp + 7 days);
        (uint256 m, uint256 at) = r.pendingMultiplier(address(tok));
        assertEq(m, 4e18);
        assertEq(at, block.timestamp + 7 days);
    }

    function test_debitBeyondRecordedReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(CollateralReconciler.InsufficientRecorded.selector, address(tok), 100e18, 101e18)
        );
        r.debit(address(tok), 101e18);
    }
}
