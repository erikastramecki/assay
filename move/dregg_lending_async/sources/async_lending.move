/// Async RWA lending on Sui — the twin of the Solana `dregg_lending_async` v1.
///
/// Borrows are INSTANT: the operator (holding `OperatorCap`) disburses on a dregg
/// kernel authorization (money moves now), opening a PENDING `Position` and folding
/// the loan's commit into a rolling Poseidon batch accumulator. A single BATCH PROOF
/// later verifies on-chain against that accumulator (`settle_batch`). A funded lender
/// `Pool` accrues interest via a borrow-index so lenders earn yield; `repay` returns
/// principal+interest and releases collateral; `liquidate` (operator-attested, works
/// on a PENDING position) unwinds an underwater loan. Mirrors the Solana program's
/// accounting one-for-one, in Sui's object/capability idiom.
module dregg_lending_async::async_lending {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::type_name::{Self, TypeName};
    use dregg_verifier::verifier;

    const EOverCap: u64 = 0xCA9;
    const EBadProof: u64 = 0xBAD;
    const EWrongRepay: u64 = 0xBAE;
    const EInsuffCash: u64 = 0xE1;
    const EMath: u64 = 0xE0;
    const EBadAttest: u64 = 0xA77; // operator attestation failed ed25519 verify
    const ENotBorrower: u64 = 0xB0B; // repay must be sent by the position's borrower
    const EBadKink: u64 = 0xC17;     // kink utilization must be in (0, 10000) bps
    const EOverCollateralCap: u64 = 0xC01; // this collateral's borrows would exceed its isolation cap

    const INDEX_ONE: u256 = 1_000_000_000_000_000_000; // 1e18 fixed-point
    const SECS_PER_YEAR: u256 = 31_536_000;
    const BPS: u256 = 10_000;
    const BPS_U64: u64 = 10_000;

    /// Whoever holds this is the dregg operator (disburse + liquidate attestation).
    public struct OperatorCap has key, store { id: UID }

    /// Emitted when a loan opens — lets indexers/SDK discover shared Positions by borrower.
    public struct LoanOpened has copy, drop { position: ID, borrower: address, principal: u64 }

    /// Emitted when governance retunes the interest curve (audit trail for rate changes).
    public struct CurveUpdated has copy, drop { pool: ID, base_bps: u64, slope1_bps: u64, slope2_bps: u64, kink_bps: u64, reserve_bps: u64 }

    /// Lender pool + async batch state (single stable asset).
    public struct Pool<phantom Stable> has key {
        id: UID,
        liquidity: Balance<Stable>,         // idle cash
        total_shares: u64,
        total_borrows: u64,                 // outstanding principal, interest-inclusive
        total_reserves: u64,                // protocol's accrued cut (not part of lenders' claim)
        borrow_index: u256,                 // 1e18 fixed-point, monotonic
        // utilization-based ("kinked") interest curve, all in bps. borrow APR rises with utilization
        // U = borrows/(cash+borrows): base + slope1·U/kink below the kink, then a steep slope2 above.
        base_bps: u64,
        slope1_bps: u64,
        slope2_bps: u64,
        kink_bps: u64,                      // target utilization (0,10000)
        reserve_bps: u64,                   // protocol's cut of interest → total_reserves
        last_accrual_s: u64,
        shares: Table<address, u64>,        // lender → shares
        cap: u64,                           // max unproven exposure
        total_pending: u64,                 // money out but unproven (this batch)
        current_batch: u64,
        last_settled: u64,
        batch_root: u256,                   // Poseidon accumulator (the batch public input)
        vk: vector<u8>,                     // pinned dregg verifying key
        operator_pubkey: vector<u8>,        // pinned operator ed25519 pubkey (attests dregg auth)
        // ISOLATION: principal borrowed per collateral type + a per-collateral cap, so a single
        // (possibly manipulated) collateral can never draw more than its cap from the shared pool.
        collateral_borrowed: Table<TypeName, u64>,
        per_collateral_cap: u64,            // 0 = unlimited
    }

    /// A PENDING loan: collateral locked, principal + borrow-index snapshot recorded.
    public struct Position<phantom Collateral, phantom Stable> has key {
        id: UID,
        borrower: address,
        collateral: Balance<Collateral>,
        principal: u64,
        index_snapshot: u256,
        batch_id: u64,
    }

    fun now_s(clock: &Clock): u64 { clock::timestamp_ms(clock) / 1000 }

    /// Current utilization in bps: U = total_borrows / (cash + total_borrows).
    public fun utilization_bps<Stable>(pool: &Pool<Stable>): u64 {
        let assets = (balance::value(&pool.liquidity) as u128) + (pool.total_borrows as u128);
        if (assets == 0) { 0 } else { ((pool.total_borrows as u128) * (BPS_U64 as u128) / assets as u64) }
    }

    /// Current borrow APR in bps from the kinked curve (rises with utilization).
    public fun borrow_rate_bps<Stable>(pool: &Pool<Stable>): u64 {
        let u = utilization_bps(pool);
        if (u <= pool.kink_bps) {
            pool.base_bps + pool.slope1_bps * u / pool.kink_bps
        } else {
            let excess = u - pool.kink_bps;
            let span = BPS_U64 - pool.kink_bps; // kink < 10000 enforced at init
            pool.base_bps + pool.slope1_bps + pool.slope2_bps * excess / span
        }
    }

    /// Fold time-based interest into borrow_index + total_borrows at the CURRENT utilization-based
    /// rate (simple compounding per call), and skim the reserve cut. Must run before any share/borrow
    /// math so total_assets is current.
    fun accrue<Stable>(pool: &mut Pool<Stable>, now: u64) {
        let last = pool.last_accrual_s;
        if (now > last && pool.total_borrows > 0) {
            let rate = borrow_rate_bps(pool); // dynamic: depends on utilization at this instant
            let dt = ((now - last) as u256);
            let denom = BPS * SECS_PER_YEAR;
            let num = denom + (rate as u256) * dt;
            pool.borrow_index = pool.borrow_index * num / denom;
            let tb_old = pool.total_borrows;
            pool.total_borrows = (((tb_old as u256) * num / denom) as u64);
            let interest = pool.total_borrows - tb_old;
            pool.total_reserves = pool.total_reserves + interest * pool.reserve_bps / BPS_U64;
        };
        pool.last_accrual_s = now;
    }

    /// Lenders' claim on the pool = cash + outstanding borrows − the protocol reserve.
    fun total_assets<Stable>(pool: &Pool<Stable>): u256 {
        let claim = (balance::value(&pool.liquidity) as u256) + (pool.total_borrows as u256);
        let res = (pool.total_reserves as u256);
        if (claim > res) { claim - res } else { 0 }
    }

    /// Build an empty pool + its OperatorCap (core; caller decides sharing). The interest curve is
    /// (base, slope1, slope2, kink, reserve) in bps — see `borrow_rate_bps`.
    public fun new_pool<Stable>(
        base_bps: u64, slope1_bps: u64, slope2_bps: u64, kink_bps: u64, reserve_bps: u64,
        cap: u64, per_collateral_cap: u64, vk: vector<u8>, operator_pubkey: vector<u8>, clock: &Clock, ctx: &mut TxContext,
    ): (Pool<Stable>, OperatorCap) {
        assert!(kink_bps > 0 && kink_bps < BPS_U64 && reserve_bps <= BPS_U64, EBadKink);
        let pool = Pool<Stable> {
            id: object::new(ctx),
            liquidity: balance::zero<Stable>(),
            total_shares: 0,
            total_borrows: 0,
            total_reserves: 0,
            borrow_index: INDEX_ONE,
            base_bps, slope1_bps, slope2_bps, kink_bps, reserve_bps,
            last_accrual_s: now_s(clock),
            shares: table::new(ctx),
            cap,
            total_pending: 0,
            current_batch: 0,
            last_settled: 0,
            batch_root: 0,
            vk,
            operator_pubkey,
            collateral_borrowed: table::new(ctx),
            per_collateral_cap,
        };
        (pool, OperatorCap { id: object::new(ctx) })
    }

    /// Create + share an empty pool, minting the OperatorCap to the sender.
    public entry fun init_pool<Stable>(
        base_bps: u64, slope1_bps: u64, slope2_bps: u64, kink_bps: u64, reserve_bps: u64,
        cap: u64, per_collateral_cap: u64, vk: vector<u8>, operator_pubkey: vector<u8>, clock: &Clock, ctx: &mut TxContext,
    ) {
        let (pool, cap_obj) = new_pool<Stable>(base_bps, slope1_bps, slope2_bps, kink_bps, reserve_bps, cap, per_collateral_cap, vk, operator_pubkey, clock, ctx);
        transfer::share_object(pool);
        transfer::public_transfer(cap_obj, ctx.sender());
    }

    /// GOVERNANCE (OperatorCap-gated): set the per-collateral isolation cap on a live pool.
    public entry fun set_collateral_cap<Stable>(_cap: &OperatorCap, pool: &mut Pool<Stable>, per_collateral_cap: u64, _ctx: &mut TxContext) {
        pool.per_collateral_cap = per_collateral_cap;
    }

    /// GOVERNANCE (OperatorCap-gated): retune the interest curve on a live pool without redeploying.
    /// Accrues pending interest at the OLD curve first, so past interest is settled fairly, then
    /// applies the new one. Emits `CurveUpdated`.
    public entry fun set_rate_curve<Stable>(
        _cap: &OperatorCap, pool: &mut Pool<Stable>,
        base_bps: u64, slope1_bps: u64, slope2_bps: u64, kink_bps: u64, reserve_bps: u64,
        clock: &Clock, _ctx: &mut TxContext,
    ) {
        assert!(kink_bps > 0 && kink_bps < BPS_U64 && reserve_bps <= BPS_U64, EBadKink);
        accrue(pool, now_s(clock)); // settle interest accrued under the old curve before switching
        pool.base_bps = base_bps;
        pool.slope1_bps = slope1_bps;
        pool.slope2_bps = slope2_bps;
        pool.kink_bps = kink_bps;
        pool.reserve_bps = reserve_bps;
        event::emit(CurveUpdated { pool: object::id(pool), base_bps, slope1_bps, slope2_bps, kink_bps, reserve_bps });
    }

    /// Lender deposits stable → receives shares proportional to total assets.
    public fun deposit<Stable>(pool: &mut Pool<Stable>, funds: Coin<Stable>, clock: &Clock, ctx: &mut TxContext) {
        let amount = coin::value(&funds);
        assert!(amount > 0, EMath);
        accrue(pool, now_s(clock));
        let ts = (pool.total_shares as u256);
        let assets = total_assets(pool);
        let minted = if (ts == 0 || assets == 0) { (amount as u256) } else { (amount as u256) * ts / assets };
        assert!(minted > 0, EMath);
        balance::join(&mut pool.liquidity, coin::into_balance(funds));
        pool.total_shares = pool.total_shares + (minted as u64);
        let who = ctx.sender();
        if (table::contains(&pool.shares, who)) {
            let cur = table::borrow_mut(&mut pool.shares, who);
            *cur = *cur + (minted as u64);
        } else {
            table::add(&mut pool.shares, who, (minted as u64));
        };
    }

    /// Lender burns shares → receives the proportional claim on total assets (from cash).
    public fun withdraw<Stable>(pool: &mut Pool<Stable>, shares: u64, clock: &Clock, ctx: &mut TxContext): Coin<Stable> {
        accrue(pool, now_s(clock));
        let ts = (pool.total_shares as u256);
        assert!(ts > 0, EMath);
        let amount = ((shares as u256) * total_assets(pool) / ts) as u64;
        assert!((amount as u256) <= (balance::value(&pool.liquidity) as u256), EInsuffCash);
        let who = ctx.sender();
        let cur = table::borrow_mut(&mut pool.shares, who);
        assert!(*cur >= shares, EMath);
        *cur = *cur - shares;
        pool.total_shares = pool.total_shares - shares;
        coin::take(&mut pool.liquidity, amount, ctx)
    }

    /// Operator disburses a loan (INSTANT, PENDING): lock collateral, take the loan
    /// coin, snapshot the borrow index, fold the commit into the accumulator. Core —
    /// returns the loan + the open Position (caller pays out / shares).
    /// Core disburse accounting (no auth) — accrue, cap-check, fold the commit, lock
    /// collateral, snapshot the index, take the loan. Both auth paths funnel here.
    fun disburse_inner<Collateral, Stable>(
        pool: &mut Pool<Stable>,
        collateral: Coin<Collateral>,
        debt: u64,
        borrower: address,
        loan_commit: u256,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Stable>, Position<Collateral, Stable>) {
        accrue(pool, now_s(clock));
        let total_pending = pool.total_pending + debt;
        assert!(total_pending <= pool.cap, EOverCap);
        pool.total_pending = total_pending;
        // ISOLATION: bump this collateral's borrowed-principal + enforce its per-collateral cap
        let ct = type_name::get<Collateral>();
        let prev = if (table::contains(&pool.collateral_borrowed, ct)) { *table::borrow(&pool.collateral_borrowed, ct) } else { 0 };
        let next = prev + debt;
        assert!(pool.per_collateral_cap == 0 || next <= pool.per_collateral_cap, EOverCollateralCap);
        if (table::contains(&pool.collateral_borrowed, ct)) { *table::borrow_mut(&mut pool.collateral_borrowed, ct) = next; }
        else { table::add(&mut pool.collateral_borrowed, ct, next); };
        // accumulator: acc_0 = 0 seeds with the first commit; later fold-in
        pool.batch_root = if (pool.batch_root == 0) { loan_commit }
            else { sui::poseidon::poseidon_bn254(&vector[pool.batch_root, loan_commit]) };
        pool.total_borrows = pool.total_borrows + debt;

        let pos = Position<Collateral, Stable> {
            id: object::new(ctx),
            borrower,
            collateral: coin::into_balance(collateral),
            principal: debt,
            index_snapshot: pool.borrow_index,
            batch_id: pool.current_batch,
        };
        event::emit(LoanOpened { position: object::id(&pos), borrower, principal: debt });
        let loan = coin::take(&mut pool.liquidity, debt, ctx);
        (loan, pos)
    }

    /// Cap-gated disburse (operator holds the OperatorCap) — the two-party/core path.
    public fun disburse<Collateral, Stable>(
        _cap: &OperatorCap,
        pool: &mut Pool<Stable>,
        collateral: Coin<Collateral>,
        debt: u64,
        borrower: address,
        loan_commit: u256,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Stable>, Position<Collateral, Stable>) {
        disburse_inner<Collateral, Stable>(pool, collateral, debt, borrower, loan_commit, clock, ctx)
    }

    /// Operator disburse (on-chain PTB): pays the loan to `borrower` + shares the Position.
    public entry fun disburse_entry<Collateral, Stable>(
        cap: &OperatorCap, pool: &mut Pool<Stable>, collateral: Coin<Collateral>, debt: u64,
        borrower: address, loan_commit: u256, clock: &Clock, ctx: &mut TxContext,
    ) {
        let (loan, pos) = disburse<Collateral, Stable>(cap, pool, collateral, debt, borrower, loan_commit, clock, ctx);
        transfer::public_transfer(loan, borrower);
        transfer::share_object(pos);
    }

    /// NON-CUSTODIAL disburse (the web/app path). The BORROWER sends this tx and supplies
    /// their own collateral; the operator's dregg authorization is an ed25519 `attestation`
    /// over the exact loan terms, verified in-Move against the pool's pinned operator pubkey.
    /// No OperatorCap needed → no two-party tx, no custody. The signed message is:
    ///   bcs(borrower:address) ‖ bcs(debt:u64) ‖ bcs(collateral_amount:u64) ‖ bcs(loan_commit:u256)
    /// so a signature can only ever disburse the terms the operator actually approved.
    public entry fun disburse_attested<Collateral, Stable>(
        pool: &mut Pool<Stable>,
        collateral: Coin<Collateral>,
        debt: u64,
        loan_commit: u256,
        attestation: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let borrower = ctx.sender();
        let coll_amt = coin::value(&collateral);
        let mut msg = sui::bcs::to_bytes(&borrower);
        vector::append(&mut msg, sui::bcs::to_bytes(&debt));
        vector::append(&mut msg, sui::bcs::to_bytes(&coll_amt));
        vector::append(&mut msg, sui::bcs::to_bytes(&loan_commit));
        // SECURITY (audit CRITICAL): bind the collateral TYPE, not just the amount. Otherwise an
        // attacker could take an attestation the operator signed for a valuable collateral and
        // present the same unit-count of a WORTHLESS coin type — borrowing against junk. The
        // operator signs the exact collateral type; the contract reconstructs it from the type param.
        vector::append(&mut msg, type_name::into_string(type_name::get<Collateral>()).into_bytes());
        assert!(sui::ed25519::ed25519_verify(&attestation, &pool.operator_pubkey, &msg), EBadAttest);
        let (loan, pos) = disburse_inner<Collateral, Stable>(pool, collateral, debt, borrower, loan_commit, clock, ctx);
        transfer::public_transfer(loan, borrower);
        transfer::share_object(pos);
    }

    /// Current debt = principal · index_now / index_at_borrow (after accrual).
    fun debt_now<Collateral, Stable>(pool: &Pool<Stable>, pos: &Position<Collateral, Stable>): u64 {
        (((pos.principal as u256) * pool.borrow_index / pos.index_snapshot) as u64)
    }

    /// Release a closed loan's principal from its collateral's isolation bucket.
    fun release_exposure<Collateral, Stable>(pool: &mut Pool<Stable>, principal: u64) {
        let ct = type_name::get<Collateral>();
        if (table::contains(&pool.collateral_borrowed, ct)) {
            let cur = *table::borrow(&pool.collateral_borrowed, ct);
            *table::borrow_mut(&mut pool.collateral_borrowed, ct) = if (cur > principal) { cur - principal } else { 0 };
        };
    }

    /// Borrower repays principal+interest, reclaims collateral, closes the position.
    /// SECURITY: only the position's borrower may repay — repay returns the (over)collateral to
    /// the caller, so without this an attacker could pay a small debt and seize a larger collateral.
    public fun repay<Collateral, Stable>(
        pool: &mut Pool<Stable>, pos: Position<Collateral, Stable>, payment: Coin<Stable>, clock: &Clock, ctx: &mut TxContext,
    ): Coin<Collateral> {
        assert!(pos.borrower == ctx.sender(), ENotBorrower);
        accrue(pool, now_s(clock));
        let owed = debt_now(pool, &pos);
        assert!(coin::value(&payment) == owed, EWrongRepay);
        pool.total_borrows = if (pool.total_borrows > owed) { pool.total_borrows - owed } else { 0 };
        release_exposure<Collateral, Stable>(pool, pos.principal);
        balance::join(&mut pool.liquidity, coin::into_balance(payment));
        let Position { id, borrower: _, collateral, principal: _, index_snapshot: _, batch_id: _ } = pos;
        object::delete(id);
        coin::from_balance(collateral, ctx)
    }

    /// Operator-attested liquidation of an underwater PENDING position (dregg's
    /// `dregg_liquidate` kernel admits it only when underwater). The liquidator (sender)
    /// repays the current debt into the pool and seizes the collateral. Async-aware —
    /// does NOT wait for batch settle.
    public fun liquidate<Collateral, Stable>(
        _cap: &OperatorCap,
        pool: &mut Pool<Stable>, pos: Position<Collateral, Stable>, payment: Coin<Stable>, clock: &Clock, ctx: &mut TxContext,
    ): Coin<Collateral> {
        accrue(pool, now_s(clock));
        let owed = debt_now(pool, &pos);
        assert!(coin::value(&payment) == owed, EWrongRepay);
        pool.total_borrows = if (pool.total_borrows > owed) { pool.total_borrows - owed } else { 0 };
        release_exposure<Collateral, Stable>(pool, pos.principal);
        balance::join(&mut pool.liquidity, coin::into_balance(payment));
        let Position { id, borrower: _, collateral, principal: _, index_snapshot: _, batch_id: _ } = pos;
        object::delete(id);
        coin::from_balance(collateral, ctx)
    }

    /// Permissionless batch settle: the batch proof must verify against the on-chain
    /// Poseidon accumulator (reconciliation). On success the batch finalizes, exposure
    /// frees, a fresh batch opens.
    public fun settle_batch<Stable>(pool: &mut Pool<Stable>, proof: vector<u8>, _ctx: &mut TxContext) {
        let public_input = sui::bcs::to_bytes(&pool.batch_root);
        assert!(verifier::verify(pool.vk, public_input, proof), EBadProof);
        pool.last_settled = pool.current_batch;
        pool.current_batch = pool.current_batch + 1;
        pool.batch_root = 0;
        pool.total_pending = 0;
    }

    // ---- views (tests / indexers) ----
    public fun pool_cash<Stable>(p: &Pool<Stable>): u64 { balance::value(&p.liquidity) }
    public fun pool_borrows<Stable>(p: &Pool<Stable>): u64 { p.total_borrows }
    public fun pool_reserves<Stable>(p: &Pool<Stable>): u64 { p.total_reserves }
    public fun per_collateral_cap<Stable>(p: &Pool<Stable>): u64 { p.per_collateral_cap }
    public fun collateral_borrowed_of<Collateral, Stable>(p: &Pool<Stable>): u64 {
        let ct = type_name::get<Collateral>();
        if (table::contains(&p.collateral_borrowed, ct)) { *table::borrow(&p.collateral_borrowed, ct) } else { 0 }
    }
    public fun pool_shares_of<Stable>(p: &Pool<Stable>, who: address): u64 {
        if (table::contains(&p.shares, who)) { *table::borrow(&p.shares, who) } else { 0 }
    }
    public fun position_principal<C, S>(p: &Position<C, S>): u64 { p.principal }
}
