// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AssayPool} from "../src/AssayPool.sol";
import {AssayMarkets} from "../src/AssayMarkets.sol";
import {LivenessOracle} from "../src/LivenessOracle.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// Deploys the stack to Robinhood Chain and wires one market.
///
///   forge script script/Deploy.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
///   forge script script/Deploy.s.sol --rpc-url rh_mainnet --broadcast --private-key $PK
///
/// EVERY ADDRESS AND DECIMAL IS READ FROM THE CHAIN, NOT TRUSTED FROM CONFIG. The worst bug this
/// codebase has had was a decimals mismatch that made every LTV limit 1e12 too permissive, and it
/// survived because a value was assumed rather than checked. `collateralDecimals` and the feed's
/// decimals are therefore queried from the live contracts and asserted here, so a fat-fingered
/// config cannot reach a deployed market.
contract Deploy is Script {
    // Robinhood Chain mainnet (4663). On testnet (46630) pass overrides via env.
    address constant USDG_MAINNET = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant AAPL_MAINNET = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_FEED_MAINNET = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    function run() external {
        address usdg = vm.envOr("USDG", USDG_MAINNET);
        address stock = vm.envOr("STOCK", AAPL_MAINNET);
        address feed = vm.envOr("FEED", AAPL_FEED_MAINNET);
        address admin = vm.envOr("ADMIN", msg.sender);
        address keeper = vm.envOr("KEEPER", msg.sender);
        address guardian = vm.envOr("GUARDIAN", msg.sender);
        // No Chainlink L2 sequencer uptime feed could be located for this chain; address(0) means
        // the check is skipped and LivenessOracle carries the risk instead. See the scope doc.
        address sequencer = vm.envOr("SEQUENCER_FEED", address(0));

        // --- read the truth off-chain-of-config ---
        uint8 assetDec = IERC20Metadata(usdg).decimals();
        uint8 stockDec = IERC20Metadata(stock).decimals();
        uint8 feedDec = AggregatorV3Interface(feed).decimals();
        console.log("USDG decimals ", assetDec);
        console.log("stock decimals", stockDec);
        console.log("feed decimals ", feedDec);
        require(assetDec > 0 && assetDec <= 36, "bad asset decimals");
        require(stockDec > 0 && stockDec <= 36, "bad stock decimals");
        require(feedDec > 0 && feedDec <= 36, "bad feed decimals");

        // The feed must be live and positive before anything is wired to it.
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        require(answer > 0, "feed answer not positive");
        require(updatedAt > 0, "feed never updated");
        console.log("feed answer   ", uint256(answer));

        vm.startBroadcast();

        // 15-minute liveness bound, 10-minute gap trigger, 1-hour post-outage grace.
        LivenessOracle liveness = new LivenessOracle(keeper, guardian, 15 minutes, 1 hours, 10 minutes);
        AssayMarkets markets =
            new AssayMarkets(AggregatorV3Interface(sequencer), liveness, admin, assetDec);
        // Zero-rate to start: the MVP is proving the loan path, not the interest curve.
        AssayPool pool = new AssayPool(IERC20(usdg), markets, 0, 0, 0, 0);

        // Conservative v1 parameters — 35% LTV against a 55% liquidation threshold is the 20pp
        // gap that has to absorb a weekend the position cannot be liquidated into.
        AssayMarkets.Market memory m = AssayMarkets.Market({
            enabled: true,
            ltvBps: 3_500,
            liqThresholdBps: 5_500,
            liqBonusBps: 800,
            collateralDecimals: stockDec, // read from the token, never typed by hand
            cap: uint128(vm.envOr("MARKET_CAP", uint256(10_000)) * (10 ** assetDec))
        });
        markets.proposeMarket(stock, AggregatorV3Interface(feed), 90_000, feedDec, m);

        vm.stopBroadcast();

        console.log("liveness  ", address(liveness));
        console.log("markets   ", address(markets));
        console.log("pool      ", address(pool));
        console.log("");
        console.log("Market PROPOSED, not live. Two things remain:");
        console.log("  1. wait out the 2-day timelock, then markets.commitMarket(stock)");
        console.log("  2. start the keeper:  LIVENESS_ORACLE=<liveness> node keeper/liveness-keeper.mjs");
        console.log("     liquidations stay disabled until it has been beating for the grace period");
    }
}
