// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AssayMarkets} from "./AssayMarkets.sol";
import {CollateralReconciler} from "./CollateralReconciler.sol";

/// Lending pool: USDG in from lenders, Stock Tokens in as collateral, USDG out as loans.
///
/// The accrual and share maths are ported from the Sui implementation, which is the one part of
/// that codebase six adversarial audit rounds never landed a confirmed finding against. The
/// audit-derived invariants are carried over deliberately, each marked with the finding that
/// taught it — they were learned by finding real holes, not by reasoning ahead of time:
///
///   F5  repay accepts >= owed and RETURNS THE CHANGE. The Sui version demanded exact equality
///       against a debt that grows every second, which made repayment a race the borrower could
///       lose. Do not reintroduce it.
///   F3  liquidation seizes only what the debt plus bonus justifies and REFUNDS THE SURPLUS.
///       Seizing 100% punished a borrower 1bp underwater.
///   R3  positions are bound to their pool; there is exactly one pool per deployment here, so the
///       binding is structural rather than a stored id.
///   R5  exposure is released on close, exactly once. On Sui this leaked and bricked borrowing.
///   R6  and it is released in ONE place, because two release paths double-released.
///   R2  rate parameters are bounded and the maths saturates rather than trapping funds.
///
/// Shares are an ERC-20 so lenders can hold and transfer their claim.
contract AssayPool is ERC4626, ReentrancyGuard, CollateralReconciler {
    using SafeERC20 for IERC20;

    error MarketClosed(address token);
    error LiquidationNotAllowed(address token);
    error NotBorrower();
    error NoDebt();
    error Undercollateralised(uint256 requested, uint256 max);
    error PositionHealthy();
    error ExceedsMarketCap(uint256 would, uint256 cap);
    error InsufficientLiquidity(uint256 want, uint256 have);
    error BadCurve();

    event Borrowed(uint256 indexed id, address indexed borrower, address indexed token, uint256 collateral, uint256 debt);
    event Repaid(uint256 indexed id, uint256 paid, uint256 collateralReturned);
    event Liquidated(uint256 indexed id, address liquidator, uint256 repaid, uint256 seized, uint256 refunded);

    struct Position {
        address borrower;
        address token;
        uint256 collateralRaw;
        uint256 principal;
        uint256 indexSnapshot;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    /// Ceiling on the SUM of curve legs. borrow_rate returns base + slope1 + slope2 at the top of
    /// the curve, so bounding the legs individually would permit 3x this (the R2-2 lesson).
    uint256 public constant MAX_RATE_BPS = 100_000; // 1000% APR

    AssayMarkets public immutable markets;

    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public borrowIndex = WAD;
    uint256 public lastAccrual;

    uint256 public baseBps;
    uint256 public slope1Bps;
    uint256 public slope2Bps;
    uint256 public kinkBps = 8_000;
    uint256 public reserveBps;

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) public positions;
    /// Borrowed principal per collateral token, against AssayMarkets' per-market cap.
    mapping(address => uint256) public marketBorrows;

    constructor(IERC20 asset_, AssayMarkets markets_, uint256 base_, uint256 s1_, uint256 s2_, uint256 reserve_)
        ERC20("Assay Pool Share", "aUSDG")
        ERC4626(IERC20(address(asset_)))
    {
        if (base_ + s1_ + s2_ > MAX_RATE_BPS || reserve_ > BPS) revert BadCurve();
        markets = markets_;
        baseBps = base_;
        slope1Bps = s1_;
        slope2Bps = s2_;
        reserveBps = reserve_;
        lastAccrual = block.timestamp;
    }

    // ---------------------------------------------------------------- accrual

    function utilizationBps() public view returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 denom = cash + totalBorrows;
        if (denom == 0) return 0;
        return (totalBorrows * BPS) / denom;
    }

    function borrowRateBps() public view returns (uint256) {
        uint256 u = utilizationBps();
        if (u <= kinkBps) return baseBps + (slope1Bps * u) / kinkBps;
        uint256 excess = u - kinkBps;
        uint256 span = BPS - kinkBps;
        return baseBps + slope1Bps + (slope2Bps * excess) / span;
    }

    /// Interest accrual. Saturates rather than reverting: an aborting cast here would freeze
    /// repayment and withdrawal for everyone, turning an accounting problem into a total loss
    /// (the R2-2 lesson, carried over).
    ///
    /// PAUSE-AWARE. A Robinhood token pause blocks transfers, so a borrower physically cannot
    /// repay. Charging interest across that window bills them for time in which repayment was
    /// impossible — and it is the issuer's pause, not theirs. `accrueFor` skips paused intervals.
    function accrue() public {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0 || totalBorrows == 0) {
            lastAccrual = block.timestamp;
            return;
        }
        // Any paused collateral market suspends the clock: repayment is impossible pool-wide
        // while the borrow asset or a collateral token cannot move.
        if (_anyCollateralPaused()) {
            lastAccrual = block.timestamp;
            return;
        }
        uint256 rate = borrowRateBps();
        uint256 denom = BPS * SECONDS_PER_YEAR;
        uint256 num = denom + rate * dt;

        // Guard the index multiply: borrowIndex is monotonic and never rebased, so at a sustained
        // maximum rate it would eventually overflow. Stop compounding rather than trap funds.
        if (borrowIndex <= type(uint256).max / num) {
            borrowIndex = (borrowIndex * num) / denom;
        }
        uint256 prev = totalBorrows;
        uint256 scaled = (prev * num) / denom;
        totalBorrows = scaled;
        uint256 interest = scaled - prev;
        totalReserves += (interest * reserveBps) / BPS;
        lastAccrual = block.timestamp;
    }

    /// Tokens whose pause state suspends accrual. Kept as an explicit list rather than scanning
    /// every position, so the cost is bounded and the operator controls the set.
    address[] public accrualPauseWatch;

    function setAccrualPauseWatch(address[] calldata tokens) external {
        if (msg.sender != markets.admin()) revert NotBorrower();
        accrualPauseWatch = tokens;
    }

    function _anyCollateralPaused() internal view returns (bool) {
        uint256 n = accrualPauseWatch.length;
        for (uint256 i = 0; i < n; i++) {
            (bool ok, bytes memory ret) =
                accrualPauseWatch[i].staticcall(abi.encodeWithSignature("paused()"));
            if (ok && ret.length >= 32 && abi.decode(ret, (bool))) return true;
        }
        return false;
    }

    function debtOf(uint256 id) public view returns (uint256) {
        Position memory p = positions[id];
        if (p.principal == 0) return 0;
        return (p.principal * borrowIndex) / p.indexSnapshot;
    }

    // ---------------------------------------------------------------- lenders

    /// Lenders' claim: cash + outstanding borrows − the protocol's accrued cut.
    function totalAssets() public view override returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 gross = cash + totalBorrows;
        return gross > totalReserves ? gross - totalReserves : 0;
    }

    /// Virtual-share offset: the standard ERC-4626 inflation-attack mitigation.
    ///
    /// The hand-rolled version this replaced had none, and was exploitable exactly as the
    /// textbook describes: deposit 1 wei, donate directly to the pool to inflate the share price,
    /// and the next depositor's shares round to ZERO while the attacker redeems everything.
    /// Confirmed by PoC before this rewrite. OZ's offset makes the donation cost grow by 10^6 per
    /// unit of rounding stolen, which is what removes the attack rather than merely narrowing it.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// Accrue before any share-price-sensitive operation, so deposits and withdrawals price
    /// against current debt rather than a stale index.
    function _deposit(address caller, address receiver, uint256 assets_, uint256 shares)
        internal
        override
        nonReentrant
    {
        accrue();
        super._deposit(caller, receiver, assets_, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets_, uint256 shares)
        internal
        override
        nonReentrant
    {
        accrue();
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        if (assets_ > cash) revert InsufficientLiquidity(assets_, cash);
        super._withdraw(caller, receiver, owner_, assets_, shares);
    }

    // ---------------------------------------------------------------- borrowers

    function borrow(address token, uint256 collateralRaw, uint256 debt)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (!markets.canBorrow(token)) revert MarketClosed(token);
        accrue();

        IERC20(token).safeTransferFrom(msg.sender, address(this), collateralRaw);
        _creditCollateral(token, collateralRaw);
        // Reconcile AFTER pulling: if the issuer burned tokens out of this pool, find out before
        // lending against a balance that no longer exists (the adminBurn hazard).
        _reconcile(token);

        // A zero-debt position can never be repaid (repay reverts NoDebt) nor liquidated
        // (isUnderwater is false at zero), so its collateral would be trapped forever.
        if (debt == 0) revert NoDebt();
        uint256 max = markets.maxBorrow(token, collateralRaw);
        if (debt > max) revert Undercollateralised(debt, max);

        uint256 would = marketBorrows[token] + debt;
        uint256 cap = markets.market(token).cap;
        if (would > cap) revert ExceedsMarketCap(would, cap);

        uint256 cash = IERC20(asset()).balanceOf(address(this));
        if (debt > cash) revert InsufficientLiquidity(debt, cash);

        marketBorrows[token] = would;
        totalBorrows += debt;
        id = nextPositionId++;
        positions[id] = Position(msg.sender, token, collateralRaw, debt, borrowIndex);
        IERC20(asset()).safeTransfer(msg.sender, debt);
        emit Borrowed(id, msg.sender, token, collateralRaw, debt);
    }

    /// Repay. Accepts `amount >= owed` and refunds the difference.
    ///
    /// Deliberately NOT exact-equality (F5). Debt grows every second, so demanding an exact figure
    /// makes repayment a race between the borrower's transaction and the clock — one they can lose
    /// through no fault of their own.
    function repay(uint256 id, uint256 amount) external nonReentrant {
        accrue();
        Position memory p = positions[id];
        if (p.borrower != msg.sender) revert NotBorrower();
        uint256 owed = debtOf(id);
        if (owed == 0) revert NoDebt();
        if (amount < owed) revert Undercollateralised(amount, owed);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), owed);
        // Reconcile BEFORE closing. _closePosition debits recordedRaw, so reconciling afterwards
        // compares a zeroed ledger against the surviving balance and silently reports no
        // shortfall — the adminBurn would vanish from the accounting entirely.
        _reconcile(p.token);
        // Pro-rata against what survives, computed BEFORE the ledger is debited (the nominal
        // total is the denominator). This is what stops one borrower being made whole out of
        // another's collateral after an adminBurn.
        uint256 give = _effectiveCollateral(p.token, p.collateralRaw);
        _closePosition(id, p, owed);
        IERC20(p.token).safeTransfer(p.borrower, give);
        emit Repaid(id, owed, give);
    }

    /// Liquidate an underwater position. Permissionless — the on-chain price and the liveness
    /// gate decide legitimacy, not a privileged role.
    ///
    /// Seizes only what the debt plus the market's bonus justifies and REFUNDS THE SURPLUS to the
    /// borrower (F3). Taking the whole position punished a borrower 1bp underwater.
    function liquidate(uint256 id) external nonReentrant {
        Position memory p = positions[id];
        if (p.principal == 0) revert NoDebt();
        if (!markets.canLiquidate(p.token)) revert LiquidationNotAllowed(p.token);
        accrue();

        _reconcile(p.token);
        // Health must be judged on collateral that STILL EXISTS. Using the stored figure made a
        // position whose collateral had been burned away read as healthy — permanently
        // unliquidatable while fully unsecured.
        uint256 effective = _effectiveCollateral(p.token, p.collateralRaw);
        uint256 owed = debtOf(id);
        if (!markets.isUnderwater(p.token, effective, owed)) revert PositionHealthy();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), owed);
        _releaseDebt(p, owed);

        // Seize debt + bonus, valued at the live price, and never more than the position holds.
        uint256 bonusBps = markets.market(p.token).liqBonusBps;
        uint256 target = (owed * (BPS + bonusBps)) / BPS;
        uint256 seize = _rawWorth(p.token, target);
        uint256 available = effective;
        if (seize > available) seize = available;

        uint256 refund = available - seize;
        _closePositionTail(id, p);
        IERC20(p.token).safeTransfer(msg.sender, seize);
        if (refund > 0) IERC20(p.token).safeTransfer(p.borrower, refund);
        emit Liquidated(id, msg.sender, owed, seize, refund);
    }

    /// Raw collateral units worth `value` in borrow-asset terms, at the live price and multiplier.
    function _rawWorth(address token, uint256 value) internal view returns (uint256) {
        (uint256 unitValue,) = markets.collateralValue(token, WAD);
        if (unitValue == 0) return 0;
        return (value * WAD) / unitValue;
    }

    /// The ONE place a position's exposure is released (R5/R6). Two release paths on Sui
    /// double-released and made the cap stop binding; there is exactly one here by construction.
    function _closePosition(uint256 id, Position memory p, uint256 owed) internal {
        _releaseDebt(p, owed);
        _closePositionTail(id, p);
    }

    /// Debt-side release. Separated so liquidate can settle the debt, compute the seizure against
    /// the still-intact ledger, and only then retire the position.
    function _releaseDebt(Position memory p, uint256 owed) internal {
        totalBorrows = totalBorrows > owed ? totalBorrows - owed : 0;
        uint256 mb = marketBorrows[p.token];
        marketBorrows[p.token] = mb > p.principal ? mb - p.principal : 0;
    }

    /// Collateral-side release. The ONE place a position leaves the books (R5/R6).
    function _closePositionTail(uint256 id, Position memory p) internal {
        _debitCollateral(p.token, p.collateralRaw);
        delete positions[id];
    }
}
