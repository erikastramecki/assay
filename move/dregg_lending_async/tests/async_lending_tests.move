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
    fun opk2(): vector<u8> { x"3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c" } // second valid ed25519 pubkey
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

        // Operator-attested liquidation. The operator prices it off-chain and signs the exact
        // seize amount; here we drive the post-signature body directly (Move cannot produce a
        // valid ed25519 signature). Seize 70 of the 100 sSPX — the other 30 must go BACK to the
        // borrower, which is the half of audit F3 that harmed borrowers even with an honest operator.
        let seized = al::liquidate_body_for_testing<SSPX, USDC>(
            &mut pool, pos, coin::mint_for_testing<USDC>(500_000_000, &mut ctx), 70_000_000_000, 0, &mut ctx);
        assert!(coin::value(&seized) == 70_000_000_000, 0);
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
        al::settle_batch<USDC>(&cap, &mut pool, bad_proof(), &mut ctx);

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
    // ---- audit R2/R3 regressions -------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = al::EAttestReplay)]
    fun disburse_attested_rejects_replayed_commit() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        // commit 42 has already been disbursed; the same attestation must never work twice
        al::mark_commit_used_for_testing(&mut pool, 42u256);
        al::disburse_attested<SSPX, USDC>(
            &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            500_000_000, 42u256, 60, FORGED, &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EWrongPool)]
    fun foreign_operator_cap_cannot_govern_another_pool() {
        let mut ctx = tx_context::dummy();
        let (mut victim, victim_cap, clk) = attest_fixture(0, &mut ctx);
        // init_pool is permissionless, so an attacker mints their OWN pool + cap for free...
        let (attacker_pool, attacker_cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1, 0, vk(), opk(), &clk, &mut ctx);
        // ...and points it at the victim pool to seize the signing key. Must abort.
        al::propose_operator_pubkey(&attacker_cap, &mut victim, x"0202020202020202020202020202020202020202020202020202020202020202", &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk);
        test_utils::destroy(victim); test_utils::destroy(victim_cap);
        test_utils::destroy(attacker_pool); test_utils::destroy(attacker_cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EBadCurve)]
    fun rate_curve_rejects_bricking_rate() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        // an absurd base rate would make accrue's u256->u64 downcast abort forever, wedging
        // every entrypoint including the repair tx. A plain operator typo reaches this.
        al::set_rate_curve(&cap, &mut pool, 18_446_744_073_709_551_615, 0, 0, 8000, 0, &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EBadPubkey)]
    fun new_pool_rejects_all_zero_pubkey() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        // 0x00*32 is a low-order point: Sui's ZIP-215 ed25519_verify accepts ANY signature against
        // it, so this key turns the protocol's only solvency gate into a no-op.
        let (pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000, 0, vk(),
            x"0000000000000000000000000000000000000000000000000000000000000000", &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EBadPubkey)]
    fun rotation_rejects_wrong_length_pubkey() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        al::propose_operator_pubkey(&cap, &mut pool, x"0202", &clk, &mut ctx); // truncated paste
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// F4 REGRESSION — settle_batch was permissionless, so anyone could scrape a proof from a
    /// settle transaction and replay it to reset `total_pending`, neutralising the only global
    /// cap on unproven exposure. A foreign cap must now be refused.
    #[test]
    #[expected_failure(abort_code = al::EWrongPool)]
    fun settle_batch_rejects_a_foreign_cap() {
        let mut ctx = tx_context::dummy();
        let (mut victim, victim_cap, clk) = attest_fixture(0, &mut ctx);
        let (attacker_pool, attacker_cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1, 0, vk(), opk(), &clk, &mut ctx);
        al::settle_batch<USDC>(&attacker_cap, &mut victim, bad_proof(), &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk);
        test_utils::destroy(victim); test_utils::destroy(victim_cap);
        test_utils::destroy(attacker_pool); test_utils::destroy(attacker_cap);
    }

    /// The accumulator must fold from acc_0 = 0 unconditionally. The old seed branch made a
    /// single-loan batch's root equal its commit — the determinism the replay relied on — and made
    /// batches [0, c1] and [c1] indistinguishable.
    #[test]
    fun batch_root_folds_from_zero_and_is_not_the_bare_commit() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        let commit = 12345u256;
        let (loan, pos) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), commit, &clk, &mut ctx);
        assert!(al::batch_root_of(&pool) != commit, 0);          // not the bare commit
        assert!(al::batch_root_of(&pool) != 0, 1);               // and actually folded
        coin::burn_for_testing(loan); test_utils::destroy(pos);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// F3 REGRESSION — liquidation used to need no attestation at all: the cap alone let a holder
    /// seize any HEALTHY position. A forged signature must now be refused.
    #[test]
    #[expected_failure(abort_code = al::EBadLiqAttest)]
    fun liquidate_rejects_forged_attestation() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        let (loan, pos) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 5u256, &clk, &mut ctx);
        let coll = al::liquidate<SSPX, USDC>(&cap, &mut pool, pos,
            coin::mint_for_testing<USDC>(100_000_000, &mut ctx), 100_000_000_000, 60, FORGED, &clk, &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); coin::burn_for_testing(coll);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// Seizing more collateral than the position holds must abort rather than silently clamp.
    #[test]
    #[expected_failure(abort_code = al::EBadSeize)]
    fun liquidate_cannot_seize_more_than_the_collateral() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        let (loan, pos) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 6u256, &clk, &mut ctx);
        let coll = al::liquidate_body_for_testing<SSPX, USDC>(
            &mut pool, pos, coin::mint_for_testing<USDC>(100_000_000, &mut ctx), 100_000_000_001, 0, &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); coin::burn_for_testing(coll);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// R5 REGRESSION (liveness) — a repaid loan must free its unproven-exposure slot. Before this,
    /// total_pending was released only by settle_batch, so cumulative lifetime volume would
    /// permanently brick borrowing at pool.cap even though every loan had been repaid.
    #[test]
    fun repaying_frees_the_unproven_exposure_slot() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        // cap of exactly one 100-unit loan: a second borrow only fits if the first freed its slot
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 100_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        let (l1, p1) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        let c1 = al::repay<SSPX, USDC>(&mut pool, p1, coin::mint_for_testing<USDC>(100_000_000, &mut ctx), &clk, &mut ctx);
        // second loan of the same size must fit — it would abort EOverCap if the slot leaked
        let (l2, p2) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 2u256, &clk, &mut ctx);
        coin::burn_for_testing(l1); coin::burn_for_testing(l2); coin::burn_for_testing(c1);
        test_utils::destroy(p2);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// R5 REGRESSION — the cap holder must not be able to rotate the signing key and use it in
    /// the same transaction. That collapsed F3's two-party requirement back into one.
    #[test]
    #[expected_failure(abort_code = al::ERotationEarly)]
    fun rotation_cannot_take_effect_immediately() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        al::propose_operator_pubkey(&cap, &mut pool, opk2(), &clk, &mut ctx);
        al::commit_operator_pubkey(&cap, &mut pool, &clk, &mut ctx); // same instant — must abort
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    fun rotation_applies_after_the_timelock() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, mut clk) = attest_fixture(0, &mut ctx);
        al::propose_operator_pubkey(&cap, &mut pool, opk2(), &clk, &mut ctx);
        clock::set_for_testing(&mut clk, 86_400_000); // a day later, in ms
        al::commit_operator_pubkey(&cap, &mut pool, &clk, &mut ctx);
        assert!(al::operator_pubkey_of(&pool) == opk2(), 0);
        let (pending, at) = al::pending_rotation(&pool);
        assert!(vector::is_empty(&pending) && at == 0, 1);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// R5 — pin the batch public input. Both of F4's headline bindings (pool id, batch index)
    /// could previously be deleted with all 33 tests still green.
    #[test]
    fun settle_public_input_binds_pool_and_batch_index() {
        let mut ctx = tx_context::dummy();
        let (mut pool_a, cap_a, clk) = attest_fixture(0, &mut ctx);
        let (mut pool_b, cap_b) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 0, vk(), opk(), &clk, &mut ctx);

        let a0 = al::settle_public_input_for_testing(&pool_a);
        assert!(vector::length(&a0) == 128, 0);            // exactly four 32-byte scalars
        // different pool, same (batch, root) -> different input  => the POOL is bound
        assert!(a0 != al::settle_public_input_for_testing(&pool_b), 1);
        // same pool, different batch index -> different input    => the BATCH INDEX is bound
        al::set_current_batch_for_testing(&mut pool_a, 7);
        let a7 = al::settle_public_input_for_testing(&pool_a);
        assert!(a0 != a7, 2);
        // and the root still matters
        al::set_current_batch_for_testing(&mut pool_a, 0);
        let (loan, pos) = al::disburse<SSPX, USDC>(&cap_a, &mut pool_a,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 9u256, &clk, &mut ctx);
        assert!(a0 != al::settle_public_input_for_testing(&pool_a), 3);

        coin::burn_for_testing(loan); test_utils::destroy(pos);
        clock::destroy_for_testing(clk);
        test_utils::destroy(pool_a); test_utils::destroy(cap_a);
        test_utils::destroy(pool_b); test_utils::destroy(cap_b);
    }

    /// R6 REGRESSION — settle_batch must NOT zero total_pending. release_exposure debits it
    /// per-loan, so a wholesale reset double-releases and pool.cap stops binding.
    #[test]
    fun settling_does_not_double_release_exposure() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 200_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        let (l1, p1) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        assert!(al::total_pending_of(&pool) == 100_000_000, 0);
        // settle would previously zero the ledger; the loan is still OPEN, so its exposure must stay
        al::force_settle_for_testing(&mut pool);
        assert!(al::total_pending_of(&pool) == 100_000_000, 1);
        // closing it releases exactly once
        let c1 = al::repay<SSPX, USDC>(&mut pool, p1, coin::mint_for_testing<USDC>(100_000_000, &mut ctx), &clk, &mut ctx);
        assert!(al::total_pending_of(&pool) == 0, 2);
        coin::burn_for_testing(l1); coin::burn_for_testing(c1);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// R6 — the global exposure cap itself had NO test: deleting the EOverCap assert left the
    /// whole suite green. This is the ledger round 5 was written to keep alive.
    #[test]
    #[expected_failure(abort_code = al::EOverCap)]
    fun global_cap_blocks_borrowing_beyond_it() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 150_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        let (l1, p1) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        // 100 + 100 > 150 cap -> must abort
        let (l2, p2) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 2u256, &clk, &mut ctx);
        // unreachable
        coin::burn_for_testing(l1); coin::burn_for_testing(l2);
        test_utils::destroy(p1); test_utils::destroy(p2);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// R6 — the per-collateral isolation release had no test either: deleting it made the
    /// isolation cap monotonic-for-life, the exact bug R5-3 fixed for total_pending.
    #[test]
    fun repaying_frees_the_per_collateral_isolation_slot() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        let (mut pool, cap) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 100_000_000, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        let (l1, p1) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        assert!(al::collateral_borrowed_of<SSPX, USDC>(&pool) == 100_000_000, 0);
        let c1 = al::repay<SSPX, USDC>(&mut pool, p1, coin::mint_for_testing<USDC>(100_000_000, &mut ctx), &clk, &mut ctx);
        assert!(al::collateral_borrowed_of<SSPX, USDC>(&pool) == 0, 1);
        // a second SSPX loan of the same size must fit again
        let (l2, p2) = al::disburse<SSPX, USDC>(&cap, &mut pool,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 100_000_000, ctx.sender(), 2u256, &clk, &mut ctx);
        coin::burn_for_testing(l1); coin::burn_for_testing(l2); coin::burn_for_testing(c1);
        test_utils::destroy(p2);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::ENoPendingKey)]
    fun commit_rotation_requires_a_pending_proposal() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        al::commit_operator_pubkey(&cap, &mut pool, &clk, &mut ctx); // nothing proposed
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    fun attest_msg_matches_typescript_byte_for_byte() {
        let expected: vector<u8> = x"1141535341595F44495342555253455F563100000000000000000000000000000000000000000000000000000000000000BB0065CD1D0000000000E87648170000002A000000000000000000000000000000000000000000000000000000000000003C0000000000000000000000000000000000000000000000000000000000000000000000000000AA5B303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303A3A6173796E635F6C656E64696E675F74657374733A3A535350585B303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303A3A6173796E635F6C656E64696E675F74657374733A3A55534443";
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

    /// Same pin for the LIQUIDATION preimage — a second message type now shares the operator key,
    /// so its layout needs the same protection against silent cross-language drift.
    #[test]
    fun liq_attest_msg_matches_typescript_byte_for_byte() {
        let expected: vector<u8> = x"1241535341595F4C49515549444154455F563100000000000000000000000000000000000000000000000000000000000000AA00000000000000000000000000000000000000000000000000000000000000CC00863BA1010000003C000000000000005B303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303A3A6173796E635F6C656E64696E675F74657374733A3A535350585B303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303A3A6173796E635F6C656E64696E675F74657374733A3A55534443";
        let actual = al::liq_attest_msg_for_testing<SSPX, USDC>(
            object::id_from_address(@0xaa), object::id_from_address(@0xcc), 7_000_000_000, 60);
        assert!(actual == expected, 0);
    }

    /// The two preimages must never collide: distinct domain tags mean a disburse attestation
    /// cannot be reinterpreted as a liquidation authorisation.
    #[test]
    fun disburse_and_liquidation_preimages_are_domain_separated() {
        let d = al::attest_msg_for_testing<SSPX, USDC>(
            object::id_from_address(@0xaa), @0xbb, 500_000_000, 100_000_000_000, 42u256, 60);
        let l = al::liq_attest_msg_for_testing<SSPX, USDC>(
            object::id_from_address(@0xaa), object::id_from_address(@0xcc), 7_000_000_000, 60);
        assert!(d != l, 0);
        // The tags differ at byte 0 (ULEB length: "ASSAY_DISBURSE_V1" is 17, "ASSAY_LIQUIDATE_V1"
        // is 18) and at byte 7 ('D' vs 'L'). Byte 1 is 'A' in both — both start "ASSAY_".
        assert!(*vector::borrow(&d, 0) != *vector::borrow(&l, 0), 1);
        assert!(*vector::borrow(&d, 7) != *vector::borrow(&l, 7), 2);
    }

    #[test]
    #[expected_failure(abort_code = al::EWrongPool)]
    fun repay_rejects_position_from_another_pool() {
        let mut ctx = tx_context::dummy();
        let (mut pool_a, cap_a, clk) = attest_fixture(0, &mut ctx);
        let (mut pool_b, cap_b) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool_b, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        // open the loan against pool B...
        let (loan, pos) = al::disburse<SSPX, USDC>(&cap_b, &mut pool_b,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 500_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        // ...then settle it against pool A. Must abort: the position belongs to B's ledger.
        let coll = al::repay<SSPX, USDC>(&mut pool_a, pos, coin::mint_for_testing<USDC>(500_000_000, &mut ctx), &clk, &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); coin::burn_for_testing(coll);
        clock::destroy_for_testing(clk);
        test_utils::destroy(pool_a); test_utils::destroy(cap_a);
        test_utils::destroy(pool_b); test_utils::destroy(cap_b);
    }

    #[test]
    #[expected_failure(abort_code = al::EWrongPool)]
    fun liquidate_rejects_position_from_another_pool() {
        let mut ctx = tx_context::dummy();
        let (mut pool_a, cap_a, clk) = attest_fixture(0, &mut ctx);
        let (mut pool_b, cap_b) = al::new_pool<USDC>(0, 0, 0, 8000, 0, 1_000_000_000_000, 0, vk(), opk(), &clk, &mut ctx);
        al::deposit(&mut pool_b, coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), &clk, &mut ctx);
        let (loan, pos) = al::disburse<SSPX, USDC>(&cap_b, &mut pool_b,
            coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx), 500_000_000, ctx.sender(), 1u256, &clk, &mut ctx);
        // pool A's own cap passes assert_cap, so only the position binding stops this
        let coll = al::liquidate<SSPX, USDC>(
            &cap_a, &mut pool_a, pos, coin::mint_for_testing<USDC>(500_000_000, &mut ctx),
            100_000_000_000, 60, FORGED, &clk, &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); coin::burn_for_testing(coll);
        clock::destroy_for_testing(clk);
        test_utils::destroy(pool_a); test_utils::destroy(cap_a);
        test_utils::destroy(pool_b); test_utils::destroy(cap_b);
    }

    /// Exercises the REAL attested-path body (post-signature), so the nullifier WRITE is covered:
    /// deleting `table::add` from `attested_disburse_body` fails this test. Verified by mutation.
    #[test]
    fun attested_disburse_records_the_commit_as_spent() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        assert!(!al::commit_used(&pool, 7u256), 0);
        al::attested_disburse_body_for_testing<SSPX, USDC>(
            &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            100_000_000, ctx.sender(), 7u256, &clk, &mut ctx);
        assert!(al::commit_used(&pool, 7u256), 1); // the nullifier must be burned
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EAttestReplay)]
    fun attested_disburse_body_rejects_a_spent_commit() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        al::attested_disburse_body_for_testing<SSPX, USDC>(
            &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            100_000_000, ctx.sender(), 7u256, &clk, &mut ctx);
        // same commit again — the second disbursement must abort
        al::attested_disburse_body_for_testing<SSPX, USDC>(
            &mut pool, coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx),
            100_000_000, ctx.sender(), 7u256, &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    #[expected_failure(abort_code = al::EBadCurve)]
    fun rate_curve_rejects_legs_that_sum_over_ceiling() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        // each leg is individually under MAX_RATE_BPS, but borrow_rate_bps SUMS them
        al::set_rate_curve(&cap, &mut pool, 90_000, 90_000, 90_000, 8000, 0, &clk, &mut ctx);
        // unreachable
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// The borrow_index guard must FREEZE compounding, not abort. Unreachable on a legal curve,
    /// so the state is forced — without this the guard was untested (reverting it left all green).
    #[test]
    fun accrue_freezes_the_index_instead_of_aborting_on_overflow() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        let near_max = 115792089237316195423570985008687907853269984665640564039457584007913129639000u256;
        al::set_accrual_state_for_testing(&mut pool, near_max, 1_000_000, 0);
        // one year at a nonzero rate would overflow the multiply; it must no-op, not abort
        al::set_rate_curve(&cap, &mut pool, 1000, 0, 0, 8000, 0, &clk, &mut ctx);
        al::accrue_for_testing(&mut pool, 31_536_000);
        assert!(al::borrow_index_of(&pool) == near_max, 0); // frozen, and we got here at all
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    /// total_borrows must saturate rather than abort, so a bad curve cannot wedge repay/withdraw.
    #[test]
    fun accrue_saturates_total_borrows_instead_of_aborting() {
        let mut ctx = tx_context::dummy();
        let (mut pool, cap, clk) = attest_fixture(0, &mut ctx);
        al::set_accrual_state_for_testing(&mut pool, 1_000_000_000_000_000_000, 18_446_744_073_709_551_000, 0);
        al::set_rate_curve(&cap, &mut pool, 100_000, 0, 0, 8000, 0, &clk, &mut ctx);
        al::accrue_for_testing(&mut pool, 31_536_000); // a full year at the max legal rate
        assert!(al::pool_borrows(&pool) == 18_446_744_073_709_551_615, 0); // saturated, not aborted
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }

    #[test]
    fun new_pool_rejects_every_low_order_pubkey() {
        let mut ctx = tx_context::dummy();
        let clk = clock::create_for_testing(&mut ctx);
        // all 8 canonical low-order points + 2 non-canonical encodings must be rejected.
        // An earlier revision substituted junk for two genuine order-8 points, leaving both
        // forgeable keys accepted — this asserts the whole set, derived not recalled.
        let keys = vector[
            x"0100000000000000000000000000000000000000000000000000000000000000",
            x"ECFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F",
            x"0000000000000000000000000000000000000000000000000000000000000000",
            x"0000000000000000000000000000000000000000000000000000000000000080",
            x"26E8958FC2B227B045C3F489F2EF98F0D5DFAC05D3C63339B13802886D53FC85",
            x"C7176A703D4DD84FBA3C0B760D10670F2A2053FA2C39CCC64EC7FD7792AC03FA",
            x"26E8958FC2B227B045C3F489F2EF98F0D5DFAC05D3C63339B13802886D53FC05",
            x"C7176A703D4DD84FBA3C0B760D10670F2A2053FA2C39CCC64EC7FD7792AC037A",
            x"ECFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
            x"0100000000000000000000000000000000000000000000000000000000000080",
            // the 4 NON-canonical encodings (y_raw = p and p+1, each sign) — two decode to the
            // identity. Enumerating these is what two earlier revisions got wrong; they are now
            // caught structurally by the y < p check, and asserted here so that cannot regress.
            x"EDFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F",
            x"EDFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
            x"EEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F",
            x"EEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
        ];
        let mut i = 0;
        while (i < vector::length(&keys)) {
            assert!(!al::pubkey_is_acceptable(vector::borrow(&keys, i)), i);
            i = i + 1;
        };
        // a real key is still accepted
        assert!(al::pubkey_is_acceptable(&opk()), 99);
        clock::destroy_for_testing(clk);
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
        // rotation is proposed, then applied only after the timelock (audit R5)
        al::propose_operator_pubkey(&cap, &mut pool, opk2(), &clk, &mut ctx);
        let (pending, at) = al::pending_rotation(&pool);
        assert!(pending == opk2() && at == 86_400, 3);
        assert!(al::operator_pubkey_of(&pool) == opk(), 4); // NOT yet in effect
        assert!(!al::commit_used(&pool, 42u256), 5);
        clock::destroy_for_testing(clk); test_utils::destroy(pool); test_utils::destroy(cap);
    }
}
