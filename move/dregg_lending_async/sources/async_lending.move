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
    const EAttestExpired: u64 = 0xA78;  // attestation's expiry_s has passed (audit F2.1)
    const EAttestReplay: u64 = 0xA79;   // this loan_commit was already disbursed (audit F2.2)
    const EPaused: u64 = 0xA7A;         // pool is paused; attested disburse disabled (audit F2.4)
    const EAttestWindow: u64 = 0xA7B;   // expiry_s is further out than MAX_ATTEST_WINDOW_S
    const EWrongPool: u64 = 0xC0A;      // this OperatorCap was minted for a different pool (audit R2-1)
    const EBadPubkey: u64 = 0xC0B;      // operator pubkey must be 32 bytes and not a low-order point (R2-3)
    const EBadCurve: u64 = 0xC0C;       // rate curve parameters would overflow accrual (audit R2-2)
    const EBadSeize: u64 = 0xC0D;       // liquidation would seize more than the position's collateral
    const ENotUnderwater: u64 = 0xC0E;  // liquidation attestation missing/invalid (audit F3)

    /// DOMAIN SEPARATION (audit F3). Two different things are now signed by the same operator key.
    /// Without a distinct prefix per message type, a disburse attestation and a liquidation
    /// attestation could in principle be reinterpreted as one another — the classic cross-protocol
    /// signature reuse. The tag is length-prefixed by bcs like the type names, so it cannot run
    /// into the following field.
    const DOMAIN_DISBURSE: vector<u8> = b"ASSAY_DISBURSE_V1";
    const DOMAIN_LIQUIDATE: vector<u8> = b"ASSAY_LIQUIDATE_V1";

    /// Longest life an attestation may be signed for. The operator's oracle discipline
    /// (pyth.mjs: maxStaleSecs 60) only constrains the INSTANT of signing, so the on-chain
    /// window must be short or a signature becomes an option on a stale price (audit F2).
    const MAX_ATTEST_WINDOW_S: u64 = 120;

    /// Ceiling on any single curve leg, in bps. `accrue` scales total_borrows by
    /// (1 + rate*dt/BPS/YEAR); an unbounded `rate` makes the u256->u64 downcast ABORT (Move casts
    /// abort, they don't wrap), and every state-changing entrypoint calls accrue first — so a bad
    /// curve permanently bricks deposit/withdraw/repay/liquidate/disburse. 100_000 bps = 1000% APR,
    /// far above any real curve and far below the overflow threshold. (audit R2-2)
    const MAX_RATE_BPS: u64 = 100_000;

    const INDEX_ONE: u256 = 1_000_000_000_000_000_000; // 1e18 fixed-point
    const SECS_PER_YEAR: u256 = 31_536_000;
    const BPS: u256 = 10_000;
    const BPS_U64: u64 = 10_000;

    /// Whoever holds this is the dregg operator for ONE pool (disburse + liquidate + governance).
    ///
    /// SECURITY (audit R2-1): `pool_id` binds the cap to the pool it was minted for. `init_pool` is
    /// permissionless, so without this binding anyone could mint their own cap and point it at
    /// someone else's pool — rotating its operator key, unpausing it, disbursing without an
    /// attestation, or liquidating healthy positions. The sibling `dregg_lending::lending` module
    /// already binds by pool id; this module was missing the same guard.
    public struct OperatorCap has key, store { id: UID, pool_id: ID }

    /// Every cap-gated entrypoint must call this first. A cap is authority over ONE pool.
    fun assert_cap<Stable>(cap: &OperatorCap, pool: &Pool<Stable>) {
        assert!(cap.pool_id == object::id(pool), EWrongPool);
    }

    /// An operator pubkey must be a 32-byte ed25519 key that is not a low-order point.
    ///
    /// SECURITY (audit R2-3): Sui's `ed25519_verify` is ZIP-215 (cofactored), which ACCEPTS a
    /// forged signature against a low-order public key — `[8][k]A` is the identity, so the message
    /// drops out of the equation and ANY signature verifies for ANY message. The all-zero key is
    /// the canonical case and is easy to install by accident (unset env var, truncated paste, an
    /// HSM returning null). A wrong-length key at least fails closed; a low-order key fails OPEN.
    /// Reject non-canonical y encodings wholesale. A valid ed25519 public key encodes y < p; any
    /// y_raw >= p is a second spelling of the same point. There are exactly 14 encodings of
    /// low-order points — 10 canonical, 4 non-canonical (y_raw = p or p+1, each with either sign
    /// bit). Two prior revisions of this function tried to ENUMERATE the non-canonical ones and
    /// got it wrong both times, so this rejects the whole class structurally instead. No
    /// legitimate key is affected: canonical encoding is required by the spec.
    fun is_canonical_y(pk: &vector<u8>): bool {
        let p_le = x"EDFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F";
        let mut i = 32;
        while (i > 0) {
            i = i - 1;
            // the top bit of the last byte is the x-sign flag, not part of y
            let b = if (i == 31) { *vector::borrow(pk, i) & 0x7F } else { *vector::borrow(pk, i) };
            let pb = *vector::borrow(&p_le, i);
            if (b < pb) { return true };
            if (b > pb) { return false };
        };
        false // exactly p — non-canonical
    }

    /// The 8 canonical low-order points of Curve25519 (orders 1,2,4,4,8,8,8,8) in their 10 valid
    /// canonical encodings — the extra two are the x=0 points written with the sign bit set.
    /// Derived from the curve equation, not recalled: an earlier revision substituted junk for two
    /// genuine order-8 points and left both forgeable keys accepted.
    ///
    /// SECURITY (audit R2-3): Sui's `ed25519_verify` is ZIP-215 (cofactored), which ACCEPTS a
    /// forged signature against a low-order public key — `[8][k]A` is the identity, so the message
    /// drops out of the equation and ANY signature verifies for ANY message. Easy to install by
    /// accident (unset env var, truncated paste, an HSM returning null). A wrong-length key fails
    /// closed; a low-order key fails OPEN.
    fun assert_valid_pubkey(pk: &vector<u8>) {
        assert!(pubkey_is_acceptable(pk), EBadPubkey);
    }

    /// Predicate form of `assert_valid_pubkey`, so the full rejection set can be asserted in one
    /// test instead of one #[expected_failure] test per point.
    public fun pubkey_is_acceptable(pk: &vector<u8>): bool {
        if (vector::length(pk) != 32) { return false };
        if (!is_canonical_y(pk)) { return false }; // covers all 4 non-canonical low-order forms
        let low_order = vector[
            x"0100000000000000000000000000000000000000000000000000000000000000", // order 1
            x"ECFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F", // order 2
            x"0000000000000000000000000000000000000000000000000000000000000000", // order 4
            x"0000000000000000000000000000000000000000000000000000000000000080", // order 4
            x"26E8958FC2B227B045C3F489F2EF98F0D5DFAC05D3C63339B13802886D53FC85", // order 8
            x"C7176A703D4DD84FBA3C0B760D10670F2A2053FA2C39CCC64EC7FD7792AC03FA", // order 8
            x"26E8958FC2B227B045C3F489F2EF98F0D5DFAC05D3C63339B13802886D53FC05", // order 8
            x"C7176A703D4DD84FBA3C0B760D10670F2A2053FA2C39CCC64EC7FD7792AC037A", // order 8
            x"ECFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", // order 2, sign set
            x"0100000000000000000000000000000000000000000000000000000000000080", // order 1, sign set
        ];
        let mut i = 0;
        while (i < vector::length(&low_order)) {
            if (pk == vector::borrow(&low_order, i)) { return false };
            i = i + 1;
        };
        true
    }

    /// Curve legs must be bounded or `accrue` can abort forever (audit R2-2).
    fun assert_valid_curve(base_bps: u64, slope1_bps: u64, slope2_bps: u64, kink_bps: u64, reserve_bps: u64) {
        assert!(kink_bps > 0 && kink_bps < BPS_U64 && reserve_bps <= BPS_U64, EBadKink);
        // Bound the SUM, not each leg: borrow_rate_bps returns base + slope1·U/kink (+ slope2
        // above the kink), so three legs each at the per-leg ceiling give 3x that rate. An earlier
        // revision bounded only the legs and justified the constant from the per-leg number.
        assert!(base_bps <= MAX_RATE_BPS && slope1_bps <= MAX_RATE_BPS && slope2_bps <= MAX_RATE_BPS, EBadCurve);
        assert!(base_bps + slope1_bps + slope2_bps <= MAX_RATE_BPS, EBadCurve);
    }

    /// Emitted when a loan opens — lets indexers/SDK discover shared Positions by borrower.
    public struct LoanOpened has copy, drop { position: ID, pool: ID, borrower: address, principal: u64 }

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
        // REPLAY (audit F2.2): every loan_commit that has been disbursed under an attestation.
        // Without this an attestation is a bearer instrument redeemable an unbounded number of
        // times. Mirrors `dregg_lending::lending`'s `used` nullifier table, which was already correct.
        used_commits: Table<u256, bool>,
        // PAUSE (audit F2.4): kill-switch for the attested path. There was previously no way to
        // revoke outstanding attestations after an operator-key compromise.
        paused: bool,
    }

    /// A PENDING loan: collateral locked, principal + borrow-index snapshot recorded.
    public struct Position<phantom Collateral, phantom Stable> has key {
        id: UID,
        // SECURITY (audit R3): the pool this position was opened against. Without it, `repay` and
        // `liquidate` accept ANY Pool<Stable> — so a position from a rich pool can be settled
        // against a pool the attacker controls, or collateral released from the wrong ledger.
        // Same missing-binding class as the OperatorCap fix, one level down.
        pool_id: ID,
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
            // Guard the index multiply. borrow_index is monotonic and never rebased, so at a
            // sustained max-legal rate it would overflow u256 in a few years and abort — bricking
            // every entrypoint permanently, exactly like the downcast did. Stop compounding
            // instead: interest ceases to accrue, but repay/withdraw keep working.
            let max_u256 = 115792089237316195423570985008687907853269984665640564039457584007913129639935u256;
            if (pool.borrow_index <= max_u256 / num) {
                pool.borrow_index = pool.borrow_index * num / denom;
            };
            let tb_old = pool.total_borrows;
            // SATURATE, don't abort (audit R2-2). Move's u256->u64 cast ABORTS on overflow, and
            // every state-changing entrypoint calls accrue first — so an overflowing accrual would
            // brick deposit/withdraw/repay/liquidate permanently, unrecoverably (set_rate_curve
            // itself calls accrue before applying the new curve, so even the repair tx would die).
            // assert_valid_curve makes this unreachable; saturating means a future curve bug costs
            // accounting precision instead of trapping every lender's funds forever.
            let max_u64 = 18_446_744_073_709_551_615u256;
            let tb_scaled = (tb_old as u256) * num / denom;
            pool.total_borrows = if (tb_scaled > max_u64) { 18_446_744_073_709_551_615 } else { (tb_scaled as u64) };
            let interest = pool.total_borrows - tb_old;
            // Widen to u256 before multiplying: `interest * reserve_bps` can overflow u64 on its
            // own. Dividing first would be wrong (any interest < BPS truncates the cut to zero),
            // so the whole expression is evaluated in u256 and saturated on the way back down.
            let res_add = (interest as u256) * (pool.reserve_bps as u256) / BPS;
            let res_new = (pool.total_reserves as u256) + res_add;
            pool.total_reserves = if (res_new > max_u64) { 18_446_744_073_709_551_615 } else { (res_new as u64) };
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
        assert_valid_curve(base_bps, slope1_bps, slope2_bps, kink_bps, reserve_bps);
        assert_valid_pubkey(&operator_pubkey);
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
            used_commits: table::new(ctx),
            paused: false,
        };
        let cap_obj = OperatorCap { id: object::new(ctx), pool_id: object::id(&pool) };
        (pool, cap_obj)
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
    public entry fun set_collateral_cap<Stable>(cap: &OperatorCap, pool: &mut Pool<Stable>, per_collateral_cap: u64, _ctx: &mut TxContext) {
        assert_cap(cap, pool);
        pool.per_collateral_cap = per_collateral_cap;
    }

    /// GOVERNANCE (OperatorCap-gated): retune the interest curve on a live pool without redeploying.
    /// Accrues pending interest at the OLD curve first, so past interest is settled fairly, then
    /// applies the new one. Emits `CurveUpdated`.
    public entry fun set_rate_curve<Stable>(
        cap: &OperatorCap, pool: &mut Pool<Stable>,
        base_bps: u64, slope1_bps: u64, slope2_bps: u64, kink_bps: u64, reserve_bps: u64,
        clock: &Clock, _ctx: &mut TxContext,
    ) {
        assert_cap(cap, pool);
        assert_valid_curve(base_bps, slope1_bps, slope2_bps, kink_bps, reserve_bps);
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
        // Accumulator: acc_0 = 0, folded UNCONDITIONALLY (audit F4). The old seed branch
        // (`if root == 0 { loan_commit }`) had two problems: it made batches [0, c1] and [c1]
        // accumulate to the same root — a domain-separation ambiguity — and it made a single-loan
        // batch's root exactly equal to its commit, which is the determinism the cap-reset replay
        // relied on. It also diverged from batch_accumulator::accumulator::root's documented
        // acc_0 = 0 convention, so the on-chain root could never equal the circuit's.
        pool.batch_root = sui::poseidon::poseidon_bn254(&vector[pool.batch_root, loan_commit]);
        pool.total_borrows = pool.total_borrows + debt;

        let pos = Position<Collateral, Stable> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            borrower,
            collateral: coin::into_balance(collateral),
            principal: debt,
            index_snapshot: pool.borrow_index,
            batch_id: pool.current_batch,
        };
        event::emit(LoanOpened { position: object::id(&pos), pool: object::id(pool), borrower, principal: debt });
        let loan = coin::take(&mut pool.liquidity, debt, ctx);
        (loan, pos)
    }

    /// Cap-gated disburse (operator holds the OperatorCap) — the two-party/core path.
    public fun disburse<Collateral, Stable>(
        cap: &OperatorCap,
        pool: &mut Pool<Stable>,
        collateral: Coin<Collateral>,
        debt: u64,
        borrower: address,
        loan_commit: u256,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Stable>, Position<Collateral, Stable>) {
        assert_cap(cap, pool);
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

    /// The exact byte string the operator signs. Kept as one function so the preimage has a
    /// single definition on-chain and `app/sui-sdk/src/attest.ts` mirrors this layout exactly.
    ///
    ///   bcs(borrower:address)   32
    /// ‖ bcs(debt:u64)            8
    /// ‖ bcs(coll_amt:u64)        8
    /// ‖ bcs(loan_commit:u256)   32
    /// ‖ bcs(expiry_s:u64)        8   (audit F2.1 — temporal binding)
    /// ‖ bcs(pool_id:ID)         32   (audit F2.3 — domain separation across pools)
    /// ‖ bcs(collateral_type)   ULEB-prefixed
    /// ‖ bcs(stable_type)       ULEB-prefixed  (audit F2.3)
    ///
    /// CANONICALIZATION: the two type names are length-prefixed via `bcs::to_bytes` on the
    /// ascii::String rather than raw-appended. Raw concatenation of two variable-length tails is
    /// ambiguous — ("AB","C") and ("A","BC") would produce identical bytes, letting one signature
    /// authorize a different (collateral, stable) pair. The prefix makes the parse unique.
    fun attest_msg<Collateral, Stable>(
        pool_id: ID, borrower: address, debt: u64, coll_amt: u64, loan_commit: u256, expiry_s: u64,
    ): vector<u8> {
        let mut msg = sui::bcs::to_bytes(&DOMAIN_DISBURSE);
        vector::append(&mut msg, sui::bcs::to_bytes(&borrower));
        vector::append(&mut msg, sui::bcs::to_bytes(&debt));
        vector::append(&mut msg, sui::bcs::to_bytes(&coll_amt));
        vector::append(&mut msg, sui::bcs::to_bytes(&loan_commit));
        vector::append(&mut msg, sui::bcs::to_bytes(&expiry_s));
        vector::append(&mut msg, sui::bcs::to_bytes(&pool_id));
        // SECURITY (audit CRITICAL, pre-existing and correct): bind the collateral TYPE, not just
        // the amount. Otherwise an attacker could take an attestation the operator signed for a
        // valuable collateral and present the same unit-count of a WORTHLESS coin type.
        vector::append(&mut msg, sui::bcs::to_bytes(&type_name::into_string(type_name::get<Collateral>())));
        // And bind the borrowed asset too, so a signature for a TUSDC pool cannot be spent at a
        // pool denominated in something else that happens to pin the same operator key.
        vector::append(&mut msg, sui::bcs::to_bytes(&type_name::into_string(type_name::get<Stable>())));
        msg
    }

    /// NON-CUSTODIAL disburse (the web/app path). The BORROWER sends this tx and supplies
    /// their own collateral; the operator's dregg authorization is an ed25519 `attestation`
    /// over the exact loan terms, verified in-Move against the pool's pinned operator pubkey.
    /// No OperatorCap needed → no two-party tx, no custody.
    ///
    /// The attestation is single-use and short-lived (see `attest_msg`). There is NO on-chain
    /// oracle or LTV check anywhere in this module — the attestation IS the solvency gate, which
    /// is exactly why it must be bound to a time, a pool, and a one-shot nullifier. Before the
    /// audit it was none of those: a perpetual bearer authorization redeemable at a frozen price.
    public entry fun disburse_attested<Collateral, Stable>(
        pool: &mut Pool<Stable>,
        collateral: Coin<Collateral>,
        debt: u64,
        loan_commit: u256,
        expiry_s: u64,
        attestation: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(!pool.paused, EPaused);
        let now = now_s(clock);
        // F2.1 — TEMPORAL BINDING. Without this, a borrower polls /borrow at a price peak, sits on
        // the signature, and submits it after a drawdown to receive a peak-priced loan that is
        // insolvent the moment it opens. The upper bound stops the operator (or a compromised
        // signer) from minting a de-facto perpetual attestation by naming a far-future expiry.
        assert!(now <= expiry_s, EAttestExpired);
        assert!(expiry_s <= now + MAX_ATTEST_WINDOW_S, EAttestWindow);
        // F2.2 — REPLAY. One commit, one disbursement, forever.
        assert!(!table::contains(&pool.used_commits, loan_commit), EAttestReplay);

        let borrower = ctx.sender();
        let coll_amt = coin::value(&collateral);
        let msg = attest_msg<Collateral, Stable>(
            object::id(pool), borrower, debt, coll_amt, loan_commit, expiry_s,
        );
        assert!(sui::ed25519::ed25519_verify(&attestation, &pool.operator_pubkey, &msg), EBadAttest);

        attested_disburse_body<Collateral, Stable>(pool, collateral, debt, borrower, loan_commit, clock, ctx);
    }

    /// Everything the attested path does AFTER the signature verifies: consume the nullifier, then
    /// disburse. Factored out so a test can exercise the REAL code — a valid ed25519 signature
    /// cannot be produced inside a Move test, so without this the nullifier WRITE was untestable
    /// (deleting it left the whole suite green). Shared body, so the tested path cannot drift.
    fun attested_disburse_body<Collateral, Stable>(
        pool: &mut Pool<Stable>, collateral: Coin<Collateral>, debt: u64, borrower: address,
        loan_commit: u256, clock: &Clock, ctx: &mut TxContext,
    ) {
        assert!(!table::contains(&pool.used_commits, loan_commit), EAttestReplay);
        table::add(&mut pool.used_commits, loan_commit, true);
        let (loan, pos) = disburse_inner<Collateral, Stable>(pool, collateral, debt, borrower, loan_commit, clock, ctx);
        transfer::public_transfer(loan, borrower);
        transfer::share_object(pos);
    }

    #[test_only]
    public fun attested_disburse_body_for_testing<Collateral, Stable>(
        pool: &mut Pool<Stable>, collateral: Coin<Collateral>, debt: u64, borrower: address,
        loan_commit: u256, clock: &Clock, ctx: &mut TxContext,
    ) {
        attested_disburse_body<Collateral, Stable>(pool, collateral, debt, borrower, loan_commit, clock, ctx)
    }

    /// GOVERNANCE (OperatorCap-gated): rotate the pinned operator pubkey. Rotating invalidates
    /// every outstanding attestation signed by the old key — the revocation path that did not
    /// exist before the audit (F2.4). Use together with `set_paused` on a suspected key compromise.
    public entry fun set_operator_pubkey<Stable>(
        cap: &OperatorCap, pool: &mut Pool<Stable>, operator_pubkey: vector<u8>, _ctx: &mut TxContext,
    ) {
        assert_cap(cap, pool);
        assert_valid_pubkey(&operator_pubkey);
        pool.operator_pubkey = operator_pubkey;
    }

    /// GOVERNANCE (OperatorCap-gated): pause/unpause the attested disburse path (F2.4).
    /// Deliberately does NOT block `repay` or withdrawals — a pause must never trap borrowers'
    /// collateral or lenders' funds.
    public entry fun set_paused<Stable>(
        cap: &OperatorCap, pool: &mut Pool<Stable>, paused: bool, _ctx: &mut TxContext,
    ) {
        assert_cap(cap, pool);
        pool.paused = paused;
    }

    /// Split a 32-byte big-endian value into (high 16 bytes, low 16 bytes) as u256, each < 2^128
    /// < the BN254 scalar field, so both are valid field elements. Mirrors the helper in
    /// dregg_lending::lending — the two packages are independent, so it cannot be shared.
    fun split32(b: vector<u8>): (u256, u256) {
        let mut hi: u256 = 0;
        let mut lo: u256 = 0;
        let mut i = 0;
        while (i < 16) { hi = (hi << 8) | (*vector::borrow(&b, i) as u256); i = i + 1; };
        while (i < 32) { lo = (lo << 8) | (*vector::borrow(&b, i) as u256); i = i + 1; };
        (hi, lo)
    }

    /// Has this loan_commit already been disbursed? (indexers + SDK preflight)
    public fun commit_used<Stable>(pool: &Pool<Stable>, loan_commit: u256): bool {
        table::contains(&pool.used_commits, loan_commit)
    }

    /// Is the attested disburse path currently paused?
    public fun is_paused<Stable>(pool: &Pool<Stable>): bool { pool.paused }

    /// Lets the replay test seed a consumed commit without needing a valid ed25519 signature
    /// (which cannot be produced inside a Move test). The audit flagged EAttestReplay as the
    /// least-verified guard in the F2 fix — this closes that gap with a real unit test.
    /// Force accrual state so the overflow GUARDS can be tested. They are unreachable on any
    /// legal curve (that is the point of the bounds), so without these the guards were dead code
    /// as far as the suite was concerned — reverting each one left every test green.
    #[test_only]
    public fun set_accrual_state_for_testing<Stable>(
        pool: &mut Pool<Stable>, borrow_index: u256, total_borrows: u64, last_accrual_s: u64,
    ) {
        pool.borrow_index = borrow_index;
        pool.total_borrows = total_borrows;
        pool.last_accrual_s = last_accrual_s;
    }

    #[test_only]
    public fun accrue_for_testing<Stable>(pool: &mut Pool<Stable>, now: u64) { accrue(pool, now) }

    #[test_only]
    public fun borrow_index_of<Stable>(pool: &Pool<Stable>): u256 { pool.borrow_index }

    #[test_only]
    public fun mark_commit_used_for_testing<Stable>(pool: &mut Pool<Stable>, loan_commit: u256) {
        table::add(&mut pool.used_commits, loan_commit, true);
    }

    #[test_only]
    public fun liq_attest_msg_for_testing<Collateral, Stable>(
        pool_id: ID, position_id: ID, seize_amount: u64, expiry_s: u64,
    ): vector<u8> {
        liq_attest_msg<Collateral, Stable>(pool_id, position_id, seize_amount, expiry_s)
    }

    /// Exposes the signed preimage so the cross-language byte-equality test can pin it against
    /// `app/sui-sdk/src/attest.ts`. A divergence there fails every signature closed, but silently.
    #[test_only]
    public fun attest_msg_for_testing<Collateral, Stable>(
        pool_id: ID, borrower: address, debt: u64, coll_amt: u64, loan_commit: u256, expiry_s: u64,
    ): vector<u8> {
        attest_msg<Collateral, Stable>(pool_id, borrower, debt, coll_amt, loan_commit, expiry_s)
    }

    /// Current debt = principal · index_now / index_at_borrow (after accrual).
    fun debt_now<Collateral, Stable>(pool: &Pool<Stable>, pos: &Position<Collateral, Stable>): u64 {
        // Saturate rather than abort: an aborting cast here traps the borrower's collateral
        // permanently, since repay and liquidate are the only ways out and both call this.
        let scaled = (pos.principal as u256) * pool.borrow_index / pos.index_snapshot;
        let max_u64 = 18_446_744_073_709_551_615u256;
        if (scaled > max_u64) { 18_446_744_073_709_551_615 } else { (scaled as u64) }
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
        assert!(pos.pool_id == object::id(pool), EWrongPool); // audit R3: position belongs to THIS pool
        assert!(pos.borrower == ctx.sender(), ENotBorrower);
        accrue(pool, now_s(clock));
        let owed = debt_now(pool, &pos);
        assert!(coin::value(&payment) == owed, EWrongRepay);
        pool.total_borrows = if (pool.total_borrows > owed) { pool.total_borrows - owed } else { 0 };
        release_exposure<Collateral, Stable>(pool, pos.principal);
        balance::join(&mut pool.liquidity, coin::into_balance(payment));
        let Position { id, pool_id: _, borrower: _, collateral, principal: _, index_snapshot: _, batch_id: _ } = pos;
        object::delete(id);
        coin::from_balance(collateral, ctx)
    }

    /// The bytes the operator signs to authorise ONE liquidation. Binds the exact position, the
    /// exact amount of collateral that may be seized, an expiry, the pool and both types.
    fun liq_attest_msg<Collateral, Stable>(
        pool_id: ID, position_id: ID, seize_amount: u64, expiry_s: u64,
    ): vector<u8> {
        let mut msg = sui::bcs::to_bytes(&DOMAIN_LIQUIDATE);
        vector::append(&mut msg, sui::bcs::to_bytes(&pool_id));
        vector::append(&mut msg, sui::bcs::to_bytes(&position_id));
        vector::append(&mut msg, sui::bcs::to_bytes(&seize_amount));
        vector::append(&mut msg, sui::bcs::to_bytes(&expiry_s));
        vector::append(&mut msg, sui::bcs::to_bytes(&type_name::into_string(type_name::get<Collateral>())));
        vector::append(&mut msg, sui::bcs::to_bytes(&type_name::into_string(type_name::get<Stable>())));
        msg
    }

    /// Operator-attested liquidation of an underwater PENDING position. The liquidator repays the
    /// current debt and seizes `seize_amount` of collateral; ANY SURPLUS GOES BACK TO THE BORROWER.
    ///
    /// SECURITY (audit F3, was HIGH): the doc comment used to claim this was operator-attested and
    /// underwater-only, but the body verified no attestation, read no price, and checked no health
    /// condition — the sole gate was an UNUSED `_cap` parameter, and it seized 100% of the
    /// collateral with no refund. Two separate harms: a cap holder could liquidate a perfectly
    /// HEALTHY position (pay debt_now, take all the collateral, ~1.43x on stablecoin outlaid,
    /// repeatable across every open loan), and even on the honest path a position 1bp underwater
    /// forfeited everything, contradicting the non-custodial design.
    ///
    /// Now it requires BOTH the pool's cap AND an ed25519 attestation from the operator key over
    /// (pool, position, seize_amount, expiry). Those are different keys in the real deployment —
    /// the cap sits with the deployer, the attestation key with the API — so liquidation takes two
    /// parties, and the operator must put its signature on the exact amount being taken.
    ///
    /// The health/price decision still lives off-chain (there is no on-chain oracle in this
    /// module), but it is now SIGNED, AMOUNT-BOUND and SHORT-LIVED rather than unlimited
    /// discretion. No nullifier is needed: the Position is consumed, so the attestation cannot be
    /// replayed against it.
    public fun liquidate<Collateral, Stable>(
        cap: &OperatorCap,
        pool: &mut Pool<Stable>,
        pos: Position<Collateral, Stable>,
        payment: Coin<Stable>,
        seize_amount: u64,
        expiry_s: u64,
        attestation: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<Collateral> {
        assert_cap(cap, pool);
        assert!(pos.pool_id == object::id(pool), EWrongPool); // audit R3: position belongs to THIS pool
        let now = now_s(clock);
        assert!(now <= expiry_s, EAttestExpired);
        assert!(expiry_s <= now + MAX_ATTEST_WINDOW_S, EAttestWindow);
        let msg = liq_attest_msg<Collateral, Stable>(
            object::id(pool), object::id(&pos), seize_amount, expiry_s,
        );
        assert!(sui::ed25519::ed25519_verify(&attestation, &pool.operator_pubkey, &msg), ENotUnderwater);
        liquidate_body<Collateral, Stable>(pool, pos, payment, seize_amount, now, ctx)
    }

    /// Everything liquidation does AFTER the attestation verifies. Factored out for the same
    /// reason as `attested_disburse_body`: a valid ed25519 signature cannot be produced inside a
    /// Move test, so without this the settlement accounting and the surplus refund would be
    /// untestable. Shared body, so the tested path cannot drift from the real one.
    fun liquidate_body<Collateral, Stable>(
        pool: &mut Pool<Stable>, pos: Position<Collateral, Stable>, payment: Coin<Stable>,
        seize_amount: u64, now: u64, ctx: &mut TxContext,
    ): Coin<Collateral> {
        accrue(pool, now);
        let owed = debt_now(pool, &pos);
        assert!(coin::value(&payment) == owed, EWrongRepay);
        pool.total_borrows = if (pool.total_borrows > owed) { pool.total_borrows - owed } else { 0 };
        release_exposure<Collateral, Stable>(pool, pos.principal);
        balance::join(&mut pool.liquidity, coin::into_balance(payment));

        let Position { id, pool_id: _, borrower, mut collateral, principal: _, index_snapshot: _, batch_id: _ } = pos;
        object::delete(id);
        assert!(seize_amount <= balance::value(&collateral), EBadSeize);
        let seized = balance::split(&mut collateral, seize_amount);
        // SURPLUS BACK TO THE BORROWER — the protocol takes what the debt plus the operator's
        // bonus justifies, never the whole position.
        if (balance::value(&collateral) > 0) {
            transfer::public_transfer(coin::from_balance(collateral, ctx), borrower);
        } else {
            balance::destroy_zero(collateral);
        };
        coin::from_balance(seized, ctx)
    }

    #[test_only]
    public fun liquidate_body_for_testing<Collateral, Stable>(
        pool: &mut Pool<Stable>, pos: Position<Collateral, Stable>, payment: Coin<Stable>,
        seize_amount: u64, now: u64, ctx: &mut TxContext,
    ): Coin<Collateral> {
        liquidate_body<Collateral, Stable>(pool, pos, payment, seize_amount, now, ctx)
    }

    /// Permissionless batch settle: the batch proof must verify against the on-chain
    /// Poseidon accumulator (reconciliation). On success the batch finalizes, exposure
    /// frees, a fresh batch opens.
    /// SECURITY (audit F4, was HIGH): this was permissionless and its only public input was
    /// `bcs(batch_root)`. Groth16 verification is stateless — a proof valid for root C is valid
    /// for C forever — so an attacker could scrape a settle transaction's plaintext proof and then
    /// alternate `disburse_attested` -> `settle_batch(P)` in one PTB, resetting `total_pending`
    /// every iteration. `pool.cap`, the only global limit on unproven exposure, was neutralised
    /// while reading 0 throughout, and `current_batch` advanced over batches never honestly proven.
    ///
    /// Two changes close it: the cap gate means only this pool's operator can settle at all, and
    /// the public input now binds the POOL and the BATCH INDEX, so a proof for batch N at pool A
    /// is not a proof for batch N+1, nor for pool B.
    ///
    /// NOTE: the public input format and the accumulator convention both changed, so the batch
    /// circuit must be re-proven against `bcs(pool_id) || bcs(current_batch) || bcs(batch_root)`
    /// with acc_0 = 0. Until then settlement cannot succeed — but nothing in the app calls it,
    /// and exposure is still released per-loan by repay/liquidate via `release_exposure`.
    public fun settle_batch<Stable>(cap: &OperatorCap, pool: &mut Pool<Stable>, proof: vector<u8>, _ctx: &mut TxContext) {
        assert_cap(cap, pool);
        // Four BN254 scalars, 32 bytes each — groth16 requires len % 32 == 0, and a raw 32-byte
        // object ID can exceed the field modulus, so the pool ID is split into two <2^128 limbs
        // (the same convention as dregg_lending::lending::loan_commit_of).
        let (pool_hi, pool_lo) = split32(object::id_to_bytes(&object::id(pool)));
        let mut public_input = sui::bcs::to_bytes(&pool_hi);
        vector::append(&mut public_input, sui::bcs::to_bytes(&pool_lo));
        vector::append(&mut public_input, sui::bcs::to_bytes(&(pool.current_batch as u256)));
        vector::append(&mut public_input, sui::bcs::to_bytes(&pool.batch_root));
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
    public fun batch_root_of<Stable>(p: &Pool<Stable>): u256 { p.batch_root }
    public fun current_batch_of<Stable>(p: &Pool<Stable>): u64 { p.current_batch }
    public fun collateral_borrowed_of<Collateral, Stable>(p: &Pool<Stable>): u64 {
        let ct = type_name::get<Collateral>();
        if (table::contains(&p.collateral_borrowed, ct)) { *table::borrow(&p.collateral_borrowed, ct) } else { 0 }
    }
    public fun pool_shares_of<Stable>(p: &Pool<Stable>, who: address): u64 {
        if (table::contains(&p.shares, who)) { *table::borrow(&p.shares, who) } else { 0 }
    }
    public fun position_principal<C, S>(p: &Position<C, S>): u64 { p.principal }

    /// Which pool this position belongs to — repay/liquidate abort with EWrongPool against any other.
    public fun position_pool_id<C, S>(p: &Position<C, S>): ID { p.pool_id }
}
