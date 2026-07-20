#[test_only]
module dregg_lending_async::async_lending_tests {
    use sui::coin::{Self};
    use sui::clock;
    use sui::test_utils;
    use sui::tx_context;
    use dregg_lending_async::async_lending as al;

    public struct USDC has drop {}
    public struct SSPX has drop {}
    public struct WETH has drop {} // a second collateral type, for isolation tests

    const YEAR_MS: u64 = 31_536_000_000;

    fun vk(): vector<u8> { x"69e7200243aa8b1093f16f1777c76de9df40458567cc6487561191e6da88862fe7461089b8e1e893dbb6dcd0751f46f17dcb6c67b254452a73077e62f24d7b06564645d5c599cf2b58690e5928b35ab877668e7a294a59f384600721880d2f91177b4406233bb6ac18b00a464a6a172f46e372ed52eece52bb79715b9b7a3525fc0ef93ed5e8a4ffa6aea08e2165812a0b2c1d09f2a5f291260d272d91481d184ea0cd81caf22ff9a18829c6170ed1df7074e3474e3a46db8bb0c31f4d0cf323a964a02e2b03c60ed8f8378a2849c0de414c4bfc78c7f946edc34dc574865392020000000000000029e081d40e40464674776b29d7194af21c317a8086c7ac480c02d25a4e14dc12974a40c9ef2b27b473ed23793e9748129780f3fa52bfc5ef6add2d690e402725" }
    // 32-byte operator ed25519 pubkey (RFC-8032 test vector; NON-degenerate so verify is honest —
    // an all-zero key hits the ed25519 identity edge case. Positive attest path proven on-chain in the harness)
    fun opk(): vector<u8> { x"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a" }
    fun bad_proof(): vector<u8> { x"bb171caeadbbc98aba5d2ef831676b1997a520b948296e7340ce6e2b1f64bf0e6cc6dfc3e82b5cbee3c09644533b07bb05d3fede6af6d05749f4e2d5824cfc17b0332ad583c14825518f20fb7b2ed5d89d885e1270ddd523291ee5f3a402e8a6d18f918c8358101dc140269a47a0657ce9ac1ca12af8b750b711a4db06e5b927" }

    #[test]
    fun money_market_lifecycle() {
        let mut ctx = tx_context::dummy();
        let mut clk = clock::create_for_testing(&mut ctx);
        // curve: base 0, slope1 1600, kink 80% → at U=50% the borrow APR is 1600·5000/8000 = 1000 bps (10%)
        let (mut pool, cap) = al::new_pool<USDC>(0, 1600, 30000, 8000, 0, 1_000_000_000_000, 0, vk(), opk(), &clk, &mut ctx);

        // LP deposits 1000 USDC → 1000 shares (first deposit)
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        assert!(al::pool_shares_of(&pool, ctx.sender()) == 1_000_000_000, 0);
        assert!(al::pool_cash(&pool) == 1_000_000_000, 1);

        // operator disburses 500 to the borrower (= tx sender here), locking 100 collateral
        let (loan, pos) = al::disburse<SSPX, USDC>(
            &cap, &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            500_000_000, ctx.sender(), 12345u256, &clk, &mut ctx);
        assert!(coin::value(&loan) == 500_000_000, 2);
        assert!(al::pool_borrows(&pool) == 500_000_000, 3);
        assert!(al::pool_cash(&pool) == 500_000_000, 4);

        // one year passes → 10% interest accrues
        clock::increment_for_testing(&mut clk, YEAR_MS);

        // borrower repays principal + interest = 550, reclaims collateral
        let coll = al::repay<SSPX, USDC>(&mut pool, pos, coin::mint_for_testing<USDC>(550_000_000, &mut ctx), &clk, &mut ctx);
        assert!(coin::value(&coll) == 100_000_000_000, 5);
        assert!(al::pool_borrows(&pool) == 0, 6);
        assert!(al::pool_cash(&pool) == 1_050_000_000, 7); // 1000 − 500 + 550

        // LP withdraws all shares → 1050 (earned the 50 interest)
        let out = al::withdraw(&mut pool, 1_000_000_000, &clk, &mut ctx);
        assert!(coin::value(&out) == 1_050_000_000, 8);

        coin::burn_for_testing(loan);
        coin::burn_for_testing(coll);
        coin::burn_for_testing(out);
        clock::destroy_for_testing(clk);
        test_utils::destroy(pool);
        test_utils::destroy(cap);
    }

    #[test]
    fun dynamic_rate_and_reserve() {
        let mut ctx = tx_context::dummy();
        let mut clk = clock::create_for_testing(&mut ctx);
        // base 0, slope1 2000 (20% APR at the kink), slope2 30000, kink 80%, reserve 10%
        let (mut pool, cap) = al::new_pool<USDC>(0, 2000, 30000, 8000, 1000, 1_000_000_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        // borrow 800 → utilization = 800/1000 = 80% (exactly the kink) → borrow APR = 20%
        let (loan, pos) = al::disburse<SSPX, USDC>(&cap, &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            800_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        assert!(al::utilization_bps(&pool) == 8000, 0);
        assert!(al::borrow_rate_bps(&pool) == 2000, 1);
        // one year → 20% interest on 800 = 160; reserve skims 10% of 160 = 16 (lenders get the other 144)
        clock::increment_for_testing(&mut clk, YEAR_MS);
        let coll = al::repay<SSPX, USDC>(&mut pool, pos, coin::mint_for_testing<USDC>(960_000_000, &mut ctx), &clk, &mut ctx);
        assert!(al::pool_borrows(&pool) == 0, 2);
        assert!(al::pool_reserves(&pool) == 16_000_000, 3);
        // lender deposited 1000, earned 144 (net of reserve) → 1144 on full withdraw
        let out = al::withdraw(&mut pool, 1_000_000_000, &clk, &mut ctx);
        assert!(coin::value(&out) == 1_144_000_000, 4);
        coin::burn_for_testing(loan); coin::burn_for_testing(coll); coin::burn_for_testing(out);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    fun collateral_isolation_separate_buckets() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        // per-collateral cap = 300 principal, zero rate
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 300_000_000, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        // 300 against SSPX (at its cap) + 300 against WETH (separate bucket) both OK
        let (l1, p1) = al::disburse<SSPX, USDC>(&cap, &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 300_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        let (l2, p2) = al::disburse<WETH, USDC>(&cap, &mut pool, coin::mint_for_testing<WETH>(100_000_000_000, &mut ctx), 300_000_000, ctx.sender(), 2u256, &clk, &mut ctx);
        assert!(al::collateral_borrowed_of<SSPX, USDC>(&pool) == 300_000_000, 0);
        assert!(al::collateral_borrowed_of<WETH, USDC>(&pool) == 300_000_000, 1);
        coin::burn_for_testing(l1); coin::burn_for_testing(l2); test_utils::destroy(p1); test_utils::destroy(p2);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EOverCollateralCap)]
    fun per_collateral_cap_enforced() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 300_000_000, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        let (l1, p1) = al::disburse<SSPX, USDC>(&cap, &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 200_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        // second SSPX loan of 200 → 400 total > 300 cap → MUST abort
        let (l2, p2) = al::disburse<SSPX, USDC>(&cap, &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 200_000_000, ctx.sender(), 2u256, &clk, &mut ctx);
        coin::burn_for_testing(l1); coin::burn_for_testing(l2); test_utils::destroy(p1); test_utils::destroy(p2);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    fun governance_retunes_curve() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        let (mut pool, cap) = al::new_pool<USDC>(0, 1400, 30000, 8000, 1000, 1_000_000_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        let (loan, pos) = al::disburse<SSPX, USDC>(&cap, &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            800_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        assert!(al::borrow_rate_bps(&pool) == 1400, 0); // 14% at the 80% kink (slope1=1400)
        // governance bumps slope1 1400→2000 → 20% borrow at the same utilization (no redeploy)
        al::set_rate_curve(&cap, &mut pool, 0, 2000, 30000, 8000, 1000, &clk, &mut ctx);
        assert!(al::borrow_rate_bps(&pool) == 2000, 1);
        coin::burn_for_testing(loan); test_utils::destroy(pos);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    fun liquidate_seizes_collateral() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        let (loan, pos) = al::disburse<SSPX, USDC>(
            &cap, &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            500_000_000, @0xB0B, 7u256, &clk, &mut ctx);

        // operator-attested liquidation (underwater per dregg_liquidate, off-chain):
        // liquidator repays 500, seizes the collateral.
        let seized = al::liquidate<SSPX, USDC>(&cap, &mut pool, pos, coin::mint_for_testing<USDC>(500_000_000, &mut ctx), &clk, &mut ctx);
        assert!(coin::value(&seized) == 100_000_000_000, 0);
        assert!(al::pool_borrows(&pool) == 0, 1);
        assert!(al::pool_cash(&pool) == 1_000_000_000, 2); // 1000 − 500 + 500

        coin::burn_for_testing(loan);
        coin::burn_for_testing(seized);
        clock::destroy_for_testing(clk);
        test_utils::destroy(pool);
        test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EBadProof)]
    fun settle_rejects_bad_proof() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        let (loan, pos) = al::disburse<SSPX, USDC>(
            &cap, &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            500_000_000, @0xB0B, 42u256, &clk, &mut ctx);
        // a proof that does not reconcile with the accumulator must abort
        al::settle_batch<USDC>(&mut pool, bad_proof(), &mut ctx);

        // unreachable
        coin::burn_for_testing(loan);
        test_utils::destroy(pos);
        clock::destroy_for_testing(clk);
        test_utils::destroy(pool);
        test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::ENotBorrower)]
    fun repay_rejects_non_borrower() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        // position owned by @0xB0B, but the tx sender (dummy ctx = @0x0) is NOT the borrower
        let (loan, pos) = al::disburse<SSPX, USDC>(
            &cap, &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            500_000_000, @0xB0B, 7u256, &clk, &mut ctx);
        // an attacker paying the small debt must NOT be able to seize the larger collateral
        let stolen = al::repay<SSPX, USDC>(&mut pool, pos, coin::mint_for_testing<USDC>(500_000_000, &mut ctx), &clk, &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); coin::burn_for_testing(stolen);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    // ---- attested-disburse guards (audit F2) ----------------------------------------------
    // A valid ed25519 signature can't be produced inside a Move test, so each guard is proven by
    // showing it aborts with ITS OWN code while carrying a forged signature — i.e. it rejects
    // before `ed25519_verify` would. The positive path is exercised on-chain in the harness.

    const FORGED: vector<u8> = x"01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101";

    /// Pool + funded liquidity + a clock parked at `now_ms`.
    fun attest_fixture(now_ms: u64, ctx: &mut TxContext): (al::Pool<USDC>, al::OperatorCap, clock::Clock) {
        let mut clk = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clk, now_ms);
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 0, vk(), opk(), &clk, ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, ctx), &clk, ctx);
        (pool, cap, clk)
    }

    #[test]
    #[expected_failure(abort_code = al::EBadAttest)]
    fun disburse_attested_rejects_forged_attestation() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        // a forged 64-byte ed25519 signature must NOT authorize a non-custodial disburse
        al::disburse_attested<SSPX, USDC>(
            &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            500_000_000, 42u256, 60, FORGED, &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EAttestExpired)]
    fun disburse_attested_rejects_expired_attestation() {
        let mut ctx = tx_context::dummy();
        // clock at t=1000s, attestation expired at t=900s. This is the stale-price attack: hold a
        // peak-priced signature through a drawdown, then redeem it. Must abort BEFORE verify.
        let (mut pool, cap, clk) = attest_fixture(1_000_000, &mut ctx);
        al::disburse_attested<SSPX, USDC>(
            &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            500_000_000, 42u256, 900, FORGED, &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EAttestWindow)]
    fun disburse_attested_rejects_overlong_window() {
        let mut ctx = tx_context::dummy();
        // t=0, expiry a year out — a de-facto perpetual bearer authorization. Capped at 120s.
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        al::disburse_attested<SSPX, USDC>(
            &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            500_000_000, 42u256, 31_536_000, FORGED, &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EPaused)]
    fun disburse_attested_rejects_when_paused() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        al::set_paused(&cap, &mut pool, true, &mut ctx); // key-compromise kill switch
        al::disburse_attested<SSPX, USDC>(
            &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            500_000_000, 42u256, 60, FORGED, &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// CROSS-LANGUAGE PIN (audit F2). The operator signs in TypeScript; the contract verifies in
    /// Move. If the two preimages diverge by a single byte every signature fails verify — closed,
    /// but silently, and it would look like a key problem rather than an encoding problem.
    /// The expected bytes below were emitted by `app/sui-sdk/src/attest.ts::attestationMessage`
    /// for these exact inputs. If this test fails, the two layouts have drifted apart — fix the
    /// mismatch, do NOT re-baseline this constant to whatever Move currently produces.
    #[test]
    fun attest_msg_matches_typescript_byte_for_byte() {
        let expected: vector<u8> = x"00000000000000000000000000000000000000000000000000000000000000bb0065cd1d0000000000e87648170000002a000000000000000000000000000000000000000000000000000000000000003c0000000000000000000000000000000000000000000000000000000000000000000000000000aa5b303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303a3a6173796e635f6c656e64696e675f74657374733a3a535350585b303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303a3a6173796e635f6c656e64696e675f74657374733a3a55534443";
        let actual = al::attest_msg_for_testing<SSPX, USDC>(
            object::id_from_address(@0xaa), // pool
            @0xbb,                          // borrower
            500_000_000,                    // debt
            100_000_000_000,                // coll_amt
            42u256,                         // loan_commit
            60,                             // expiry_s
        );
        assert!(actual == expected, 0);
    }

    #[test]
    fun pause_and_rotate_are_cap_gated_and_observable() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        assert!(!al::is_paused(&pool), 0);
        al::set_paused(&cap, &mut pool, true, &mut ctx);
        assert!(al::is_paused(&pool), 1);
        al::set_paused(&cap, &mut pool, false, &mut ctx);
        assert!(!al::is_paused(&pool), 2);
        // rotation invalidates every outstanding attestation signed by the old key
        al::set_operator_pubkey(&cap, &mut pool, x"0202020202020202020202020202020202020202020202020202020202020202", &mut ctx);
        assert!(!al::commit_used(&pool, 42u256), 3); // nothing disbursed yet
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }
}
