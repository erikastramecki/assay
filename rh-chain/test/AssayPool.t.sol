// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AssayPool} from "../src/AssayPool.sol";
import {AssayMarkets} from "../src/AssayMarkets.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockFeed, MockStock} from "./RiskModules.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Real USDG on Robinhood Chain has SIX decimals (verified by eth_call against mainnet).
/// The first version of this mock used 18, which made a 1e12 collateral-valuation error
/// invisible to the entire suite. Mocks that differ from production hide exactly the bugs
/// production has.
contract MockUSDG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract AssayPoolTest is Test {
    AssayPool pool;
    AssayMarkets mk;
    LivenessOracle liv;
    MockFeed seq;
    MockFeed px;
    MockStock tok;
    MockUSDG usdg;

    address ADMIN;
    address KEEPER;
    address GUARDIAN;
    address LENDER;
    address ALICE;
    address LIQUIDATOR;

    uint256 constant MON_IN_SESSION = 1_753_110_000;
    uint256 constant MAX_AGE = 15 minutes;
    uint256 constant GRACE = 1 hours;

    function setUp() public {
        ADMIN = makeAddr("admin"); KEEPER = makeAddr("keeper"); GUARDIAN = makeAddr("guardian");
        LENDER = makeAddr("lender"); ALICE = makeAddr("alice"); LIQUIDATOR = makeAddr("liquidator");
        vm.warp(MON_IN_SESSION);

        seq = new MockFeed(0, 0); seq.setStartedAt(block.timestamp - 2 days);
        px = new MockFeed(200e8, 8); // $200/share
        tok = new MockStock();
        usdg = new MockUSDG();
        liv = new LivenessOracle(KEEPER, GUARDIAN, MAX_AGE, GRACE);
        mk = new AssayMarkets(AggregatorV3Interface(address(seq)), liv, ADMIN, 6); // USDG is 6dp
        // zero-rate pool: isolates the invariants under test from accrual drift
        pool = new AssayPool(usdg, mk, 0, 0, 0, 0);

        AssayMarkets.Market memory m = AssayMarkets.Market({
            enabled: true, ltvBps: 3_500, liqThresholdBps: 5_500, liqBonusBps: 800,
            collateralDecimals: 18, cap: 1_000_000e6
        });
        vm.startPrank(ADMIN);
        mk.proposeMarket(address(tok), AggregatorV3Interface(address(px)), 90_000, 8, m);
        vm.warp(block.timestamp + mk.PARAM_TIMELOCK());
        px.set(200e8, block.timestamp);
        mk.commitMarket(address(tok));
        vm.stopPrank();

        _beat(); _advanceLive(GRACE);

        usdg.mint(LENDER, 1_000_000e6);
        usdg.mint(ALICE, 100_000e6);
        usdg.mint(LIQUIDATOR, 100_000e6);
        tok.mint(ALICE, 1_000e18);

        vm.startPrank(LENDER);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(500_000e6, LENDER);
        vm.stopPrank();

        vm.startPrank(ALICE);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(LIQUIDATOR);
        usdg.approve(address(pool), type(uint256).max);
    }

    function _beat() internal { vm.prank(KEEPER); liv.heartbeat(); }
    function _advanceLive(uint256 secs) internal {
        uint256 end = block.timestamp + secs;
        while (block.timestamp + 5 minutes < end) {
            vm.warp(block.timestamp + 5 minutes); px.set(px.answer(), block.timestamp); _beat();
        }
        vm.warp(end); px.set(px.answer(), block.timestamp); _beat();
    }

    /// 10 shares at $200 = $2000 collateral; 35% LTV = $700 max.
    function _borrow(uint256 debt) internal returns (uint256 id) {
        vm.prank(ALICE);
        id = pool.borrow(address(tok), 10e18, debt);
    }

    // ---------------------------------------------------------------- basics

    function test_lenderDepositMintsShares() public view {
        assertGt(pool.balanceOf(LENDER), 0);
        assertEq(pool.totalAssets(), 500_000e6);
    }

    function test_borrowWithinLtv() public {
        uint256 id = _borrow(700e6);
        assertEq(usdg.balanceOf(ALICE), 100_700e6);
        assertEq(pool.debtOf(id), 700e6);
        assertEq(pool.marketBorrows(address(tok)), 700e6);
    }

    function test_borrowBeyondLtvReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(AssayPool.Undercollateralised.selector, 701e6, 700e6));
        pool.borrow(address(tok), 10e18, 701e6);
    }

    function test_borrowBlockedOffHours() public {
        uint256 night = (block.timestamp / 86400) * 86400 + 1 days + 3 hours;
        vm.warp(night); px.set(200e8, night);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(AssayPool.MarketClosed.selector, address(tok)));
        pool.borrow(address(tok), 10e18, 100e18);
    }

    // ---------------------------------------------------------------- F5: repay

    /// Overpaying must NOT be an error, and must not overcharge. The Sui version demanded exact
    /// equality against a debt that grows every second — a race the borrower could lose.
    function test_repayAcceptsMoreThanOwedAndChargesOnlyTheDebt() public {
        uint256 id = _borrow(700e6);
        uint256 before_ = usdg.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(id, 1_000e6); // deliberately generous
        assertEq(before_ - usdg.balanceOf(ALICE), 700e6, "must charge exactly the debt");
        assertEq(tok.balanceOf(ALICE), 1_000e18, "collateral fully returned");
        assertEq(pool.debtOf(id), 0);
    }

    function test_repayBelowOwedReverts() public {
        uint256 id = _borrow(700e6);
        vm.prank(ALICE);
        vm.expectRevert();
        pool.repay(id, 699e6);
    }

    function test_onlyBorrowerCanRepay() public {
        uint256 id = _borrow(700e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(AssayPool.NotBorrower.selector);
        pool.repay(id, 700e6);
    }

    // ---------------------------------------------------------------- R5/R6: exposure release

    /// Closing a position must free its slot — exactly once. On Sui this leaked and eventually
    /// bricked all borrowing, then a second release path made the cap stop binding entirely.
    function test_repayFreesTheMarketCapSlotExactlyOnce() public {
        uint256 id = _borrow(700e6);
        assertEq(pool.marketBorrows(address(tok)), 700e6);
        vm.prank(ALICE);
        pool.repay(id, 700e6);
        assertEq(pool.marketBorrows(address(tok)), 0, "slot must be freed");
        // and borrowing the same size again must fit
        uint256 id2 = _borrow(700e6);
        assertEq(pool.marketBorrows(address(tok)), 700e6, "must not double-count or double-free");
        assertGt(id2, id);
    }

    // ---------------------------------------------------------------- F3: liquidation

    function test_healthyPositionCannotBeLiquidated() public {
        uint256 id = _borrow(700e6);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(AssayPool.PositionHealthy.selector);
        pool.liquidate(id);
    }

    /// THE F3 CASE. An underwater position is liquidated, but the liquidator takes only the debt
    /// plus the bonus — the SURPLUS goes back to the borrower. Seizing everything punished a
    /// borrower fractionally underwater.
    function test_liquidationRefundsSurplusToBorrower() public {
        uint256 id = _borrow(700e6);
        // drop to $125: collateral $1250, threshold 55% = $687.50 < $700 debt
        px.set(125e8, block.timestamp);
        assertEq(tok.balanceOf(ALICE), 990e18); // 10 posted

        vm.prank(LIQUIDATOR);
        pool.liquidate(id);

        // debt 700 + 8% bonus = 756 of value; at $125/share that is 6.048 shares
        uint256 seized = tok.balanceOf(LIQUIDATOR);
        assertApproxEqAbs(seized, 6.048e18, 1e15, "liquidator takes debt+bonus, not everything");
        // the rest returns to Alice
        assertApproxEqAbs(tok.balanceOf(ALICE), 990e18 + (10e18 - seized), 1e15, "surplus refunded");
        assertLt(seized, 10e18, "must never be the whole position");
    }

    function test_liquidationBlockedWithoutChainLiveness() public {
        uint256 id = _borrow(700e6);
        px.set(125e8, block.timestamp);
        vm.warp(block.timestamp + 4 hours); // outage: no heartbeat possible
        px.set(125e8, block.timestamp);
        vm.prank(LIQUIDATOR);
        vm.expectRevert(abi.encodeWithSelector(AssayPool.LiquidationNotAllowed.selector, address(tok)));
        pool.liquidate(id);
    }

    // ---------------------------------------------------------------- adminBurn

    /// The issuer destroys collateral out of the live pool. The ledger must notice, and repayment
    /// must still work — returning whatever survived rather than reverting and trapping the rest.
    function test_adminBurnIsAbsorbedAndRepaymentStillWorks() public {
        uint256 id = _borrow(700e6);
        tok.adminBurn(address(pool), 4e18); // Robinhood burns 4 of Alice's 10 posted shares

        vm.prank(ALICE);
        pool.repay(id, 700e6);

        assertEq(pool.shortfallRaw(address(tok)), 4e18, "shortfall recorded");
        assertEq(tok.balanceOf(ALICE), 990e18 + 6e18, "returns what survived, does not revert");
        assertEq(pool.debtOf(id), 0, "debt still cleared");
    }

    // ---------------------------------------------------------------- accrual

    function test_interestAccruesAndLenderEarns() public {
        AssayPool p2 = new AssayPool(usdg, mk, 1_000, 0, 0, 0); // flat 10% APR
        vm.startPrank(LENDER);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(100_000e6, LENDER);
        vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max);
        usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(address(tok), 10e18, 700e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertApproxEqRel(p2.debtOf(id), 770e6, 0.01e18, "10% APR on 700");
        assertGt(p2.totalAssets(), 100_000e6, "lenders earn the interest");
    }

    /// R1-AUDIT: an adminBurn must make a position MORE liquidatable, not less. Reading the
    /// stored collateralRaw made a fully-unsecured position read as healthy — permanently
    /// unliquidatable while backing nothing.
    function test_burnedCollateralMakesPositionLiquidatableNotStuck() public {
        uint256 id = _borrow(700e6);
        tok.adminBurn(address(pool), 9e18); // 10 posted -> 1 survives, $200 backing $700
        vm.prank(LIQUIDATOR);
        pool.liquidate(id); // must NOT revert PositionHealthy
        assertEq(pool.debtOf(id), 0, "position closed");
    }

    /// R1-AUDIT: the ordering bug. Two borrowers, one burn — each loses their share, in either
    /// order. Previously whoever repaid first was made whole out of the other's collateral.
    function test_burnLossIsSharedNotAllocatedByRepaymentOrder() public {
        uint256 aliceId = _borrow(700e6);
        address BOB = makeAddr("bob");
        tok.mint(BOB, 100e18); usdg.mint(BOB, 10_000e6);
        vm.startPrank(BOB);
        tok.approve(address(pool), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        uint256 bobId = pool.borrow(address(tok), 10e18, 700e6);
        vm.stopPrank();

        tok.adminBurn(address(pool), 10e18); // 20 posted -> 10 survive

        uint256 aliceBefore = tok.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.repay(aliceId, 700e6);
        assertEq(tok.balanceOf(ALICE) - aliceBefore, 5e18, "Alice gets HER half, not all of it");

        uint256 bobBefore = tok.balanceOf(BOB);
        vm.prank(BOB);
        pool.repay(bobId, 700e6);
        assertEq(tok.balanceOf(BOB) - bobBefore, 5e18, "Bob is not left with zero");
    }

    /// R1-AUDIT: a zero-debt position could never be repaid nor liquidated — collateral trapped.
    function test_zeroDebtBorrowIsRejected() public {
        vm.prank(ALICE);
        vm.expectRevert(AssayPool.NoDebt.selector);
        pool.borrow(address(tok), 10e18, 0);
    }

    /// R1-AUDIT: interest must not accrue while the issuer's pause makes repayment impossible.
    function test_accrualSuspendsWhileCollateralIsPaused() public {
        AssayPool p2 = new AssayPool(usdg, mk, 1_000, 0, 0, 0);
        vm.startPrank(LENDER); usdg.approve(address(p2), type(uint256).max); p2.deposit(100_000e6, LENDER); vm.stopPrank();
        vm.startPrank(ALICE);
        tok.approve(address(p2), type(uint256).max); usdg.approve(address(p2), type(uint256).max);
        uint256 id = p2.borrow(address(tok), 10e18, 700e6);
        vm.stopPrank();
        address[] memory watch = new address[](1); watch[0] = address(tok);
        vm.prank(ADMIN); p2.setAccrualPauseWatch(watch);

        tok.setPaused(true);
        vm.warp(block.timestamp + 365 days);
        p2.accrue();
        assertEq(p2.debtOf(id), 700e6, "no interest while repayment is impossible");
    }

    /// R1-AUDIT: THE FIRST-DEPOSITOR INFLATION ATTACK, run as an actual attack rather than
    /// asserted as prevented. Deposit 1 wei, donate directly to inflate the share price, and the
    /// victim's deposit rounds to zero shares while the attacker redeems everything.
    ///
    /// This test exists because setting _decimalsOffset() to 0 previously left the whole suite
    /// green — the mitigation was present but nothing proved it worked.
    function test_firstDepositorInflationAttackFails() public {
        AssayPool p2 = new AssayPool(usdg, mk, 0, 0, 0, 0);
        address ATTACKER = makeAddr("attacker");
        address VICTIM = makeAddr("victim");
        usdg.mint(ATTACKER, 200_000e6);
        usdg.mint(VICTIM, 100_000e6);

        vm.startPrank(ATTACKER);
        usdg.approve(address(p2), type(uint256).max);
        p2.deposit(1, ATTACKER);                    // 1. one wei
        usdg.transfer(address(p2), 100_000e6);      // 2. donate to inflate share price
        vm.stopPrank();

        vm.startPrank(VICTIM);
        usdg.approve(address(p2), type(uint256).max);
        uint256 victimShares = p2.deposit(100_000e6, VICTIM);  // 3. must NOT round to zero
        vm.stopPrank();
        assertGt(victimShares, 0, "victim must receive shares");

        // 4. attacker redeems everything they hold and must not profit at the victim's expense
        vm.startPrank(ATTACKER);
        uint256 got = p2.redeem(p2.balanceOf(ATTACKER), ATTACKER, ATTACKER);
        vm.stopPrank();
        assertLe(got, 100_000e6 + 1, "attacker must not extract the victim's deposit");

        // and the victim can still get materially all of their money back
        vm.startPrank(VICTIM);
        uint256 back = p2.redeem(victimShares, VICTIM, VICTIM);
        vm.stopPrank();
        assertGe(back, 99_000e6, "victim recovers substantially all of their deposit");
    }

    function test_curveSumIsBounded() public {
        vm.expectRevert(AssayPool.BadCurve.selector);
        new AssayPool(usdg, mk, 90_000, 90_000, 90_000, 0); // legs individually ok, sum is not
    }

    function test_withdrawBeyondCashReverts() public {
        _borrow(700e6);
        vm.prank(LENDER);
        vm.expectRevert();
        pool.withdraw(500_000e6, LENDER, LENDER);
    }
}
