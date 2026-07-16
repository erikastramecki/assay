#[test_only]
module dregg_lending::lending_tests {
    use sui::coin::{Self};
    use sui::test_utils;
    use sui::tx_context;
    use dregg_lending::lending;

    public struct SSPX has drop {} // mock tokenized RWA collateral
    public struct USDC has drop {} // mock stablecoin

    fun vk(): vector<u8> { x"69e7200243aa8b1093f16f1777c76de9df40458567cc6487561191e6da88862fe7461089b8e1e893dbb6dcd0751f46f17dcb6c67b254452a73077e62f24d7b06564645d5c599cf2b58690e5928b35ab877668e7a294a59f384600721880d2f91177b4406233bb6ac18b00a464a6a172f46e372ed52eece52bb79715b9b7a3525fc0ef93ed5e8a4ffa6aea08e2165812a0b2c1d09f2a5f291260d272d91481d184ea0cd81caf22ff9a18829c6170ed1df7074e3474e3a46db8bb0c31f4d0cf323a964a02e2b03c60ed8f8378a2849c0de414c4bfc78c7f946edc34dc574865392020000000000000029e081d40e40464674776b29d7194af21c317a8086c7ac480c02d25a4e14dc12974a40c9ef2b27b473ed23793e9748129780f3fa52bfc5ef6add2d690e402725" }
    fun publics(): vector<u8> { x"4fb4218c9df27a136e1eccd008ec6067d584f3799f5127c5d378f4b2306ee81d" }
    fun proof(): vector<u8> { x"bb171caeadbbc98aba5d2ef831676b1997a520b948296e7340ce6e2b1f64bf0e6cc6dfc3e82b5cbee3c09644533b07bb05d3fede6af6d05749f4e2d5824cfc17b0332ad583c14825518f20fb7b2ed5d89d885e1270ddd523291ee5f3a402e8a6d18f918c8358101dc140269a47a0657ce9ac1ca12af8b750b711a4db06e5b927" }

    #[test]
    fun borrow_then_repay() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        let collateral = coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx);

        // BORROW 50 USDC against 100 sSPX, gated on the real dregg proof (pool's pinned vk)
        let (loan, pos) = lending::borrow<SSPX, USDC>(&mut pool, collateral, 50_000_000, publics(), proof(), &mut ctx);
        assert!(coin::value(&loan) == 50_000_000, 1);
        assert!(lending::pool_liquidity(&pool) == 950_000_000, 2);
        assert!(lending::position_debt(&pos) == 50_000_000, 3);

        // REPAY 50 USDC, reclaim 100 sSPX
        let collateral_back = lending::repay<SSPX, USDC>(&mut pool, pos, loan, &mut ctx);
        assert!(coin::value(&collateral_back) == 100_000_000_000, 4);
        assert!(lending::pool_liquidity(&pool) == 1_000_000_000, 5);

        coin::burn_for_testing(collateral_back);
        test_utils::destroy(pool);
    }

    #[test]
    fun loan_commit_binds_every_term() {
        let pool = object::id_from_address(@0xA11CE);
        let pool2 = object::id_from_address(@0xB0B);
        let alice = @0xA11CE;
        let bob = @0xB0B;

        let base = lending::loan_commit_of(pool, alice, 50_000_000, 100_000_000_000, 5000, 7);
        // deterministic
        assert!(base == lending::loan_commit_of(pool, alice, 50_000_000, 100_000_000_000, 5000, 7), 0);
        // every economic term is bound — flipping any one changes the commitment
        assert!(base != lending::loan_commit_of(pool2, alice, 50_000_000, 100_000_000_000, 5000, 7), 1); // pool
        assert!(base != lending::loan_commit_of(pool, bob,   50_000_000, 100_000_000_000, 5000, 7), 2); // borrower
        assert!(base != lending::loan_commit_of(pool, alice, 50_000_001, 100_000_000_000, 5000, 7), 3); // debt
        assert!(base != lending::loan_commit_of(pool, alice, 50_000_000,  99_999_999_999, 5000, 7), 4); // collateral
        assert!(base != lending::loan_commit_of(pool, alice, 50_000_000, 100_000_000_000, 5001, 7), 5); // LTV
        assert!(base != lending::loan_commit_of(pool, alice, 50_000_000, 100_000_000_000, 5000, 8), 6); // nonce
    }

    #[test]
    #[expected_failure(abort_code = lending::EReplay)]
    fun borrow_rejects_replay() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);

        // first borrow consumes payment_id (the proof's nullifier)
        let c1 = coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx);
        let (loan1, pos1) = lending::borrow<SSPX, USDC>(&mut pool, c1, 50_000_000, publics(), proof(), &mut ctx);

        // second borrow reusing the SAME proof/payment_id must abort EReplay
        let c2 = coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx);
        let (loan2, pos2) = lending::borrow<SSPX, USDC>(&mut pool, c2, 50_000_000, publics(), proof(), &mut ctx);

        // unreachable
        coin::burn_for_testing(loan1); coin::burn_for_testing(loan2);
        test_utils::destroy(pos1); test_utils::destroy(pos2);
        test_utils::destroy(pool);
    }

    #[test]
    #[expected_failure(abort_code = lending::EBadProof)]
    fun borrow_rejects_bad_proof() {
        let mut ctx = tx_context::dummy();
        let mut pool = lending::create_pool<USDC>(coin::mint_for_testing<USDC>(1_000_000_000, &mut ctx), vk(), &mut ctx);
        let collateral = coin::mint_for_testing<SSPX>(100_000_000_000, &mut ctx);
        let bad = x"bb171caeadbbc98aba5d2ef831676b1997a520b948296e7340ce6e2b1f64bf0e6cc6dfc3e82b5cbee3c09644533b07bb05d3fede6af6d05749f4e2d5824cfc17b0332ad583c14825518f20fb7b2ed5d89d885e1270ddd523291ee5f3a402e8a6d18f918c8358101dc140269a47a0657ce9ac1ca12af8b750b711a4db06e5b926";
        let (loan, pos) = lending::borrow<SSPX, USDC>(&mut pool, collateral, 50_000_000, publics(), bad, &mut ctx);
        // unreachable — borrow aborts
        coin::burn_for_testing(loan);
        test_utils::destroy(pos);
        test_utils::destroy(pool);
    }
}
