#[test_only]
module dregg_lending::lending_tests {
    use sui::coin::{Self};
    use sui::test_utils;
    use sui::tx_context;
    use dregg_lending::lending;

    public struct SSPX has drop {} // mock tokenized RWA collateral
    public struct USDC has drop {} // mock stablecoin

    /// Poseidon-BN254 over [pool_hi, pool_lo, borr_hi, borr_lo, debt, collateral, ltv_bps,
    /// nonce, type_hi, type_lo] for (pool=0xA11CE, borrower=0xB0B, debt=50_000_000,
    /// collateral=100_000_000_000, ltv=5000, nonce=7, Collateral=SSPX). The circuit must match.
    const GOLDEN_LOAN_COMMIT: u256 = 7368272942283350516062460903538446643014622013886231286321180872080501377023;

    fun vk(): vector<u8> { x"69e7200243aa8b1093f16f1777c76de9df40458567cc6487561191e6da88862fe7461089b8e1e893dbb6dcd0751f46f17dcb6c67b254452a73077e62f24d7b06564645d5c599cf2b58690e5928b35ab877668e7a294a59f384600721880d2f91177b4406233bb6ac18b00a464a6a172f46e372ed52eece52bb79715b9b7a3525fc0ef93ed5e8a4ffa6aea08e2165812a0b2c1d09f2a5f291260d272d91481d184ea0cd81caf22ff9a18829c6170ed1df7074e3474e3a46db8bb0c31f4d0cf323a964a02e2b03c60ed8f8378a2849c0de414c4bfc78c7f946edc34dc574865392020000000000000029e081d40e40464674776b29d7194af21c317a8086c7ac480c02d25a4e14dc12974a40c9ef2b27b473ed23793e9748129780f3fa52bfc5ef6add2d690e402725" }
    fun publics(): vector<u8> { x"4fb4218c9df27a136e1eccd008ec6067d584f3799f5127c5d378f4b2306ee81d" }
    fun proof(): vector<u8> { x"bb171caeadbbc98aba5d2ef831676b1997a520b948296e7340ce6e2b1f64bf0e6cc6dfc3e82b5cbee3c09644533b07bb05d3fede6af6d05749f4e2d5824cfc17b0332ad583c14825518f20fb7b2ed5d89d885e1270ddd523291ee5f3a402e8a6d18f918c8358101dc140269a47a0657ce9ac1ca12af8b750b711a4db06e5b927" }

    /// F1 REGRESSION — the drain. Before the terms binding, ANY holder of one valid
    /// (payment_id, proof) could set `debt` to the pool's whole balance and pass
    /// `coin::zero()` as collateral. This is that exact attack, with the repo's own real
    /// fixture, and it must now abort ETermsMismatch.
    #[test]
    #[expected_failure(abort_code = lending::ETermsMismatch)]
    fun borrow_rejects_unbound_debt_and_zero_collateral() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        let drain = lending::pool_liquidity(&pool);
        let (loan, pos) = lending::borrow<SSPX, USDC>(
            &mut pool, coin::zero<SSPX>(&mut ctx), drain, 5000, 7, publics(), proof(), &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); test_utils::destroy(pos); test_utils::destroy(pool);
    }

    /// The honest path is ALSO gated until a re-proven fixture lands: the shipped proof's public
    /// input is not `loan_commit_of(...)`, so origination is disabled rather than drainable.
    /// When the fixture arrives this test flips to a passing borrow_then_repay.
    #[test]
    #[expected_failure(abort_code = lending::ETermsMismatch)]
    fun borrow_is_gated_until_the_reproven_fixture_lands() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        let collateral = coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx);
        let (loan, pos) = lending::borrow<SSPX, USDC>(
            &mut pool, collateral, 50_000_000, 5000, 7, publics(), proof(), &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); test_utils::destroy(pos); test_utils::destroy(pool);
    }

    /// A payment_id that DOES bind these terms gets past the binding — proving the assert is a
    /// real equality check and not an unconditional reject — and then fails on the proof itself.
    #[test]
    #[expected_failure(abort_code = lending::EBadProof)]
    fun correctly_bound_terms_reach_the_proof_check() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        let collateral = coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx);
        let pid = lending::expected_payment_id<SSPX>(
            object::id(&pool), ctx.sender(), 50_000_000, 100_000_000_000, 5000, 7);
        let (loan, pos) = lending::borrow<SSPX, USDC>(
            &mut pool, collateral, 50_000_000, 5000, 7, pid, proof(), &mut ctx);
        // unreachable — binding passes, Groth16 verification fails
        coin::burn_for_testing(loan); test_utils::destroy(pos); test_utils::destroy(pool);
    }

    /// The binding must read the ACTUAL collateral coin, not a constant. Commit to 100 sSPX,
    /// then hand over 50 — must abort. (A mutation hardcoding the amount survived without this.)
    #[test]
    #[expected_failure(abort_code = lending::ETermsMismatch)]
    fun borrow_binds_the_actual_collateral_amount() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        let pid = lending::expected_payment_id<SSPX>(
            object::id(&pool), ctx.sender(), 50_000_000, 100_000_000_000, 5000, 7);
        let short = coin::mint_for_testing<SSPX>(50_000_000_000, &mut ctx); // half of what was committed
        let (loan, pos) = lending::borrow<SSPX, USDC>(
            &mut pool, short, 50_000_000, 5000, 7, pid, proof(), &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); test_utils::destroy(pos); test_utils::destroy(pool);
    }

    /// Likewise the debt: commit to 50 USDC, request 900 — must abort. This is the drain in its
    /// purest form, with an otherwise perfectly-formed commitment.
    #[test]
    #[expected_failure(abort_code = lending::ETermsMismatch)]
    fun borrow_binds_the_actual_debt() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        let pid = lending::expected_payment_id<SSPX>(
            object::id(&pool), ctx.sender(), 50_000_000, 100_000_000_000, 5000, 7);
        let collateral = coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx);
        let (loan, pos) = lending::borrow<SSPX, USDC>(
            &mut pool, collateral, 900_000_000, 5000, 7, pid, proof(), &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); test_utils::destroy(pos); test_utils::destroy(pool);
    }

    public struct JUNK has drop {} // a worthless coin the attacker publishes themselves

    /// R5 REGRESSION — the collateral TYPE must be bound, not just the unit count. A proof issued
    /// for 100e9 units of sSPX must NOT be redeemable with 100e9 units of a worthless coin.
    #[test]
    #[expected_failure(abort_code = lending::ETermsMismatch)]
    fun borrow_rejects_substituted_collateral_type() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        // commitment issued for SSPX collateral...
        let pid = lending::expected_payment_id<SSPX>(
            object::id(&pool), ctx.sender(), 50_000_000, 100_000_000_000, 5000, 7);
        // ...redeemed with the same unit count of a junk coin. Must abort.
        let junk = coin::mint_for_testing<JUNK>(100_000_000_000, &mut ctx);
        let (loan, pos) = lending::borrow<JUNK, USDC>(
            &mut pool, junk, 50_000_000, 5000, 7, pid, proof(), &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); test_utils::destroy(pos); test_utils::destroy(pool);
    }

    #[test]
    fun loan_commit_binds_the_collateral_type() {
        let pool = object::id_from_address(@0xA11CE);
        let a = lending::loan_commit_of<SSPX>(pool, @0xA11CE, 50_000_000, 100_000_000_000, 5000, 7);
        let b = lending::loan_commit_of<JUNK>(pool, @0xA11CE, 50_000_000, 100_000_000_000, 5000, 7);
        assert!(a != b, 0); // same terms, different collateral type -> different commitment
    }

    /// GOLDEN VECTOR (audit R6). Every other test here is a difference test, so a REORDER of the
    /// Poseidon preimage — or swapping blake2b256 for another digest — survived the whole suite.
    /// The circuit must reproduce this exact value; pinning it makes an accidental change to the
    /// preimage impossible to land silently. If this fails, the on-chain preimage moved: fix the
    /// preimage or regenerate the circuit, do NOT re-baseline the constant.
    #[test]
    fun loan_commit_of_is_pinned_to_a_golden_vector() {
        let v = lending::loan_commit_of<SSPX>(
            object::id_from_address(@0xA11CE), @0xB0B, 50_000_000, 100_000_000_000, 5000, 7);
        assert!(v == GOLDEN_LOAN_COMMIT, 0);
    }

    #[test]
    fun loan_commit_binds_every_term() {
        let pool = object::id_from_address(@0xA11CE);
        let pool2 = object::id_from_address(@0xB0B);
        let alice = @0xA11CE;
        let bob = @0xB0B;

        let base = lending::loan_commit_of<SSPX>(pool, alice, 50_000_000, 100_000_000_000, 5000, 7);
        // deterministic
        assert!(base == lending::loan_commit_of<SSPX>(pool, alice, 50_000_000, 100_000_000_000, 5000, 7), 0);
        // every economic term is bound — flipping any one changes the commitment
        assert!(base != lending::loan_commit_of<SSPX>(pool2, alice, 50_000_000, 100_000_000_000, 5000, 7), 1); // pool
        assert!(base != lending::loan_commit_of<SSPX>(pool, bob,   50_000_000, 100_000_000_000, 5000, 7), 2); // borrower
        assert!(base != lending::loan_commit_of<SSPX>(pool, alice, 50_000_001, 100_000_000_000, 5000, 7), 3); // debt
        assert!(base != lending::loan_commit_of<SSPX>(pool, alice, 50_000_000,  99_999_999_999, 5000, 7), 4); // collateral
        assert!(base != lending::loan_commit_of<SSPX>(pool, alice, 50_000_000, 100_000_000_000, 5001, 7), 5); // LTV
        assert!(base != lending::loan_commit_of<SSPX>(pool, alice, 50_000_000, 100_000_000_000, 5000, 8), 6); // nonce
    }

    #[test]
    #[expected_failure(abort_code = lending::EReplay)]
    fun borrow_rejects_replay() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        let c = coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx);
        let pid = lending::expected_payment_id<SSPX>(
            object::id(&pool), ctx.sender(), 50_000_000, 100_000_000_000, 5000, 7);
        // a valid first borrow cannot be constructed without the re-proven fixture, so seed the
        // consumed nullifier directly; the second attempt must still be refused as a replay
        lending::mark_payment_id_used_for_testing(&mut pool, pid);
        let (loan, pos) = lending::borrow<SSPX, USDC>(
            &mut pool, c, 50_000_000, 5000, 7, pid, proof(), &mut ctx);
        // unreachable
        coin::burn_for_testing(loan); test_utils::destroy(pos); test_utils::destroy(pool);
    }

    #[test]
    #[expected_failure(abort_code = lending::EBadProof)]
    fun borrow_rejects_bad_proof() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        let collateral = coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx);
        let bad = x"bb171caeadbbc98aba5d2ef831676b1997a520b948296e7340ce6e2b1f64bf0e6cc6dfc3e82b5cbee3c09644533b07bb05d3fede6af6d05749f4e2d5824cfc17b0332ad583c14825518f20fb7b2ed5d89d885e1270ddd523291ee5f3a402e8a6d18f918c8358101dc140269a47a0657ce9ac1ca12af8b750b711a4db06e5b926";
        let pid = lending::expected_payment_id<SSPX>(
            object::id(&pool), ctx.sender(), 50_000_000, 100_000_000_000, 5000, 7);
        let (loan, pos) = lending::borrow<SSPX, USDC>(&mut pool, collateral, 50_000_000, 5000, 7, pid, bad, &mut ctx);
        // unreachable — borrow aborts
        coin::burn_for_testing(loan);
        test_utils::destroy(pos);
        test_utils::destroy(pool);
    }
}
