// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";

contract LivenessOracleTest is Test {
    LivenessOracle o;
    address KEEPER;
    address GUARDIAN;

    uint256 constant MAX_AGE = 15 minutes;
    uint256 constant GRACE = 1 hours;

    function setUp() public {
        KEEPER = makeAddr("keeper");
        GUARDIAN = makeAddr("guardian");
        vm.warp(1_753_110_000);
        o = new LivenessOracle(KEEPER, GUARDIAN, MAX_AGE, GRACE);
    }

    function _beat() internal {
        vm.prank(KEEPER);
        o.heartbeat();
    }

    /// A fresh deployment has not proven anything. It must start CLOSED.
    function test_startsClosed() public view {
        assertFalse(o.liquidationsAllowed());
        assertEq(o.lastHeartbeat(), 0);
    }

    /// "Never beat" and "beat, but stale" are different states, and the first must be closed on
    /// its own terms. Near genesis the staleness check alone would NOT catch it — block.timestamp
    /// minus a zero lastHeartbeat is small — so without the explicit zero check the oracle would
    /// read as OPEN on a fresh chain. Found by mutation: deleting that check passed every other test.
    function test_neverBeatIsClosedEvenAtLowTimestamps() public {
        LivenessOracle fresh = new LivenessOracle(KEEPER, GUARDIAN, MAX_AGE, GRACE);
        vm.warp(60); // 60s after genesis: younger than maxHeartbeatAge
        assertEq(fresh.lastHeartbeat(), 0);
        assertFalse(fresh.liquidationsAllowed(), "must be closed because it has NEVER beat");
    }

    /// Even the first heartbeat serves the grace period — being alive now is not evidence that
    /// borrowers have had a chance to act.
    function test_firstHeartbeatStartsGraceNotOpen() public {
        _beat();
        assertFalse(o.liquidationsAllowed(), "first beat must not open immediately");
        _advanceLive(GRACE);
        assertTrue(o.liquidationsAllowed());
    }

    /// Advance `secs` the way a live keeper would: beating every 5 minutes throughout, so the
    /// heartbeat stays fresh. Warping without beating models an OUTAGE, not the passage of time —
    /// conflating the two is what made the first draft of these tests wrong.
    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes);
            _beat();
        }
        vm.warp(end);
        _beat();
    }

    function _bringOnline() internal {
        _beat();
        _advanceLive(GRACE);
        assertTrue(o.liquidationsAllowed());
    }

    function test_steadyHeartbeatKeepsItOpen() public {
        _bringOnline();
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 5 minutes);
            _beat();
            assertTrue(o.liquidationsAllowed(), "steady beats must not trip the gap logic");
        }
    }

    /// THE CORE CASE. The chain halts, so the keeper cannot post. Liquidations must be disabled
    /// ALREADY when it comes back — with no transaction needed at the critical moment, and
    /// therefore nothing for a liquidation bot to front-run.
    function test_outageDisablesLiquidationsWithoutAnyTransaction() public {
        _bringOnline();
        // chain halts for 4 hours: no heartbeat is possible
        vm.warp(block.timestamp + 4 hours);
        assertFalse(o.liquidationsAllowed(), "must be closed on restart with NO tx sent");
    }

    /// And coming back online does not immediately re-open — the borrower gets the grace window.
    function test_restartStartsGraceRatherThanReopening() public {
        _bringOnline();
        vm.warp(block.timestamp + 4 hours); // outage
        _beat(); // keeper's first post-outage beat
        assertFalse(o.liquidationsAllowed(), "restart must not re-open instantly");

        _advanceLive(GRACE - 5 minutes);
        assertFalse(o.liquidationsAllowed(), "still inside grace");
        _advanceLive(5 minutes);
        assertTrue(o.liquidationsAllowed(), "open after grace");
    }

    /// Keeper failure is indistinguishable from chain failure, and must be treated identically.
    function test_keeperFailureIsTreatedAsAnOutage() public {
        _bringOnline();
        vm.warp(block.timestamp + MAX_AGE + 1); // keeper simply stopped
        assertFalse(o.liquidationsAllowed());
    }

    function test_onlyKeeperCanBeat() public {
        vm.expectRevert(LivenessOracle.NotKeeper.selector);
        o.heartbeat();
    }

    function test_guardianRotatesKeeper() public {
        address k2 = makeAddr("keeper2");
        vm.prank(GUARDIAN);
        o.setKeeper(k2);
        assertEq(o.keeper(), k2);
        vm.prank(k2);
        o.heartbeat(); // new keeper works
    }

    function test_nonGuardianCannotRotateKeeper() public {
        vm.prank(KEEPER);
        vm.expectRevert(LivenessOracle.NotGuardian.selector);
        o.setKeeper(makeAddr("keeper2"));
    }

    function test_countdownIsVisibleToTheUi() public {
        _bringOnline();
        vm.warp(block.timestamp + 4 hours); // outage
        _beat();
        assertEq(o.secondsUntilLiquidationsAllowed(), GRACE);
        _advanceLive(20 minutes);
        assertEq(o.secondsUntilLiquidationsAllowed(), GRACE - 20 minutes);
    }

    function test_zeroAddressRejected() public {
        vm.expectRevert(LivenessOracle.ZeroAddress.selector);
        new LivenessOracle(address(0), GUARDIAN, MAX_AGE, GRACE);
        vm.expectRevert(LivenessOracle.ZeroAddress.selector);
        new LivenessOracle(KEEPER, address(0), MAX_AGE, GRACE);
    }
}
