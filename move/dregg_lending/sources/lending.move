/// Proof-gated RWA-collateralized lending on Sui (RWA marketplace, Phase 0).
///
/// A borrower locks a tokenized RWA (`Collateral`, e.g. sSPX) and borrows a
/// stablecoin (`Stable`) from a lender `Pool` — the disbursement happens ONLY if a
/// dregg proof verifies on-chain (`dregg_verifier::verifier::verify`), i.e. dregg
/// authorized the borrow under its LTV/caveat policy. `repay` returns the stable
/// and reclaims the collateral. Built on the same proof gate as `settlement.move`.
module dregg_lending::lending {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use dregg_verifier::verifier;

    const EBadProof: u64 = 0xBAD;
    const EWrongRepay: u64 = 0xBAE;
    const EWrongPool: u64 = 0xBAF;
    const EReplay: u64 = 0xBB0;
    const ETermsMismatch: u64 = 0xBB1; // proof's public input does not commit to THESE loan terms

    /// Lender liquidity. `vk` is the PINNED dregg verifying key — the proof gate is
    /// only meaningful against a trusted vk fixed by the lender, never a caller-
    /// supplied one (audit CRITICAL #2). `used` is the consumed-nullifier set: a
    /// proof's `payment_id` may authorize AT MOST ONE borrow (audit CRITICAL #1 —
    /// closes replay + mempool proof-theft; a stolen proof drains nothing twice).
    public struct Pool<phantom Stable> has key, store {
        id: UID,
        liquidity: Balance<Stable>,
        vk: vector<u8>,
        used: Table<vector<u8>, bool>,
    }

    /// An open loan: collateral locked, debt owed, bound to the borrower AND the
    /// originating pool (audit CRITICAL #3 — repay must return to the same pool).
    public struct Position<phantom Collateral, phantom Stable> has key, store {
        id: UID,
        borrower: address,
        pool_id: ID,
        collateral: Balance<Collateral>,
        debt: u64,
    }

    /// A lender creates a pool seeded with `funds`, pinning the trusted `vk`.
    public fun create_pool<Stable>(funds: Coin<Stable>, vk: vector<u8>, ctx: &mut TxContext): Pool<Stable> {
        Pool { id: object::new(ctx), liquidity: coin::into_balance(funds), vk, used: table::new(ctx) }
    }

    /// Lock `collateral` and, iff the dregg proof verifies against the POOL's pinned
    /// vk AND commits to exactly these terms, disburse `debt`.
    ///
    /// SECURITY (audit F1, was CRITICAL): the proof gate alone proves NOTHING about the loan.
    /// Groth16 verification only says "this proof is valid for this public input under this vk" —
    /// it says nothing about `debt` or `collateral`, which used to be free caller-supplied values.
    /// Any holder of one valid (payment_id, proof) — including an honest borrower issued a proof
    /// for a small loan — could call this with `debt = pool_liquidity(pool)` and
    /// `collateral = coin::zero()` and empty the pool, then replay the same pair against every
    /// other pool pinning the same vk (`used` is per-pool). Proven by PoC against this package.
    ///
    /// The fix is the binding that `loan_commit_of` has always computed and nothing ever called:
    /// the proof's public input must EQUAL the commitment over the ACTUAL pool, sender, debt,
    /// collateral amount, LTV and nonce. That closes the amount-unbinding, the collateral
    /// substitution, the sender swap and the cross-pool replay in one assert.
    ///
    /// NOTE: this makes the module unable to originate until a re-proven fixture whose public
    /// input IS `loan_commit_of(...)` lands (perloan-prep/RUNBOOK-terms-binding.md — blocked on
    /// the 25->26 claim-lane circuit change upstream). That is deliberate: a lending function
    /// that can be drained must not originate loans. It starts working the moment the fixture does.
    public fun borrow<Collateral, Stable>(
        pool: &mut Pool<Stable>,
        collateral: Coin<Collateral>,
        debt: u64,
        ltv_bps: u64,
        nonce: u64,
        payment_id: vector<u8>,
        proof: vector<u8>,
        ctx: &mut TxContext,
    ): (Coin<Stable>, Position<Collateral, Stable>) {
        // TERMS BINDING (audit F1): the proof must be FOR this loan, not merely valid.
        let expected = loan_commit_of(
            object::id(pool), ctx.sender(), debt, coin::value(&collateral), ltv_bps, nonce,
        );
        assert!(payment_id == sui::bcs::to_bytes(&expected), ETermsMismatch);
        // single-use: a given proof (its payment_id) can authorize at most one borrow.
        assert!(!table::contains(&pool.used, payment_id), EReplay);
        assert!(verifier::verify(pool.vk, payment_id, proof), EBadProof);
        table::add(&mut pool.used, payment_id, true);
        let loan = coin::take(&mut pool.liquidity, debt, ctx);
        let pos = Position {
            id: object::new(ctx),
            borrower: ctx.sender(),
            pool_id: object::id(pool),
            collateral: coin::into_balance(collateral),
            debt,
        };
        (loan, pos)
    }

    /// Repay exactly `debt` to the SAME pool the loan came from, reclaim collateral.
    public fun repay<Collateral, Stable>(
        pool: &mut Pool<Stable>,
        pos: Position<Collateral, Stable>,
        payment: Coin<Stable>,
        ctx: &mut TxContext,
    ): Coin<Collateral> {
        let Position { id, borrower: _, pool_id, collateral, debt } = pos;
        assert!(pool_id == object::id(pool), EWrongPool);
        assert!(coin::value(&payment) == debt, EWrongRepay);
        balance::join(&mut pool.liquidity, coin::into_balance(payment));
        object::delete(id);
        coin::from_balance(collateral, ctx)
    }

    // ---- economic-terms binding (audit CRITICAL #1, remaining half) ----
    //
    // The proof gate is only sound if the proof's public input BINDS the loan's
    // economic terms — otherwise a valid proof for one loan authorizes any `debt`
    // (attacker sets debt = pool balance). The binding: the dregg borrow turn commits
    // {pool, borrower, debt, collateral, LTV, nonce} into its state → the STARK claim
    // → the Groth16 public input == `loan_commit_of(...)` below. On-chain, `borrow`
    // reconstructs that commitment from the ACTUAL amounts/accounts and requires the
    // proof's `payment_id == loan_commit_of(...)`. Same Poseidon on both sides:
    // `sui::poseidon` is circomlib/iden3 Poseidon-BN254, matched bit-exact by the
    // in-circuit gadget (rwa-marketplace/circuit/poseidon/). 32-byte ID/address are
    // split into two <128-bit limbs so every input is a valid BN254 field element.
    //
    // WIRED INTO `borrow` as of the F1 fix — the assert compares the proof's public input
    // against this commitment over the actual terms. A re-proven fixture (public ==
    // loan_commit_of) is still required before the module can originate; see
    // perloan-prep/RUNBOOK-terms-binding.md.
    public fun loan_commit_of(
        pool_id: ID, borrower: address, debt: u64, collateral: u64, ltv_bps: u64, nonce: u64,
    ): u256 {
        let (ph, pl) = split32(object::id_to_bytes(&pool_id));
        let (bh, bl) = split32(sui::address::to_bytes(borrower));
        sui::poseidon::poseidon_bn254(&vector[
            ph, pl, bh, bl,
            (debt as u256), (collateral as u256), (ltv_bps as u256), (nonce as u256),
        ])
    }

    /// Split a 32-byte big-endian value into (high 16 bytes, low 16 bytes) as u256,
    /// each < 2^128 < the BN254 scalar field, so both are valid Poseidon inputs.
    fun split32(b: vector<u8>): (u256, u256) {
        let mut hi: u256 = 0;
        let mut lo: u256 = 0;
        let mut i = 0;
        while (i < 16) { hi = (hi << 8) | (*std::vector::borrow(&b, i) as u256); i = i + 1; };
        while (i < 32) { lo = (lo << 8) | (*std::vector::borrow(&b, i) as u256); i = i + 1; };
        (hi, lo)
    }

    /// Seed a consumed nullifier so the replay guard can be tested without a valid proof
    /// (which cannot exist until the re-proven fixture lands).
    #[test_only]
    public fun mark_payment_id_used_for_testing<Stable>(pool: &mut Pool<Stable>, payment_id: vector<u8>) {
        table::add(&mut pool.used, payment_id, true);
    }

    /// The exact bytes `borrow` expects as `payment_id` for these terms.
    public fun expected_payment_id(
        pool_id: ID, borrower: address, debt: u64, collateral: u64, ltv_bps: u64, nonce: u64,
    ): vector<u8> {
        sui::bcs::to_bytes(&loan_commit_of(pool_id, borrower, debt, collateral, ltv_bps, nonce))
    }

    public fun pool_liquidity<Stable>(p: &Pool<Stable>): u64 { balance::value(&p.liquidity) }
    public fun position_debt<Collateral, Stable>(p: &Position<Collateral, Stable>): u64 { p.debt }

    // ---- entry wrappers (for live on-chain calls / PTBs) ----

    /// Lender: create + share a pool seeded with `funds`, pinning the trusted `vk`.
    public entry fun create_pool_entry<Stable>(funds: Coin<Stable>, vk: vector<u8>, ctx: &mut TxContext) {
        transfer::share_object(create_pool(funds, vk, ctx));
    }

    /// Borrow: lock collateral, disburse the loan to the sender (iff the proof
    /// verifies against the pool's pinned vk), and hand the Position to the sender.
    public entry fun borrow_entry<Collateral, Stable>(
        pool: &mut Pool<Stable>,
        collateral: Coin<Collateral>,
        debt: u64,
        ltv_bps: u64,
        nonce: u64,
        payment_id: vector<u8>,
        proof: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let (loan, pos) = borrow<Collateral, Stable>(pool, collateral, debt, ltv_bps, nonce, payment_id, proof, ctx);
        transfer::public_transfer(loan, ctx.sender());
        transfer::transfer(pos, ctx.sender());
    }

    /// Repay `payment` (exactly the debt) and receive the collateral back.
    public entry fun repay_entry<Collateral, Stable>(
        pool: &mut Pool<Stable>,
        pos: Position<Collateral, Stable>,
        payment: Coin<Stable>,
        ctx: &mut TxContext,
    ) {
        let collateral = repay<Collateral, Stable>(pool, pos, payment, ctx);
        transfer::public_transfer(collateral, ctx.sender());
    }
}
