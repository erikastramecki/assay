# RUNBOOK — economic-terms binding (closes audit CRITICAL #1, the loan_commit exposure)

> ⚠️ **SCOPE CORRECTION (2026-07-14).** This is NOT a one-shot re-prove. Reading the real
> settlement circuit: the Groth16 public statement is the **25 claim lanes**
> (`genesis_root[8] ++ final_root[8] ++ num_turns ++ chain_digest[8]`) — all roots/counts,
> STARK-attested via `ExposeClaimAir`. The **raw loan terms are never exposed** (only baked
> inside `final_root`, a BabyBear digest you cannot invert on-chain). So binding `debt` to
> the disbursement requires a **dregg-core change**: add a raw `loan_commit` lane to
> `ExposeClaimAir` (bus-bound like the roots), bump the gnark claim count 25→26, re-derive
> the apex VK identity — THEN the re-prove + the on-chain assert. This is v2 hardening; the
> async launch path (honest-operator + exposure-cap + in-kernel LTV/oracle) is sound without
> it. Design the dregg-core change properly before any box spend. The material below (goal,
> on-chain reconstruction, gadget) is still correct — it's the *circuit-side* step that's
> bigger than first written.

**Goal.** Make the Groth16 public input equal `loan_commit_of(pool_id, borrower, debt,
collateral, ltv_bps, nonce)` (the same Poseidon the Sui `lending::loan_commit_of`
computes on-chain), so a proof authorizes **exactly one loan's terms** — not any `debt`.

Everything up to the re-prove is done:

- ✅ On-chain reconstruction `lending::loan_commit_of` + `split32` — TESTED (determinism +
  every-term-sensitivity), `move/dregg_lending`.
- ✅ In-circuit circomlib-Poseidon-BN254 gadget bit-exact w/ `sui::poseidon`
  (`rwa-marketplace/circuit/poseidon/`, validated last Hetzner run).
- ✅ Nullifier + vk-pin + pool_id already shipped (this branch) — reduce but do NOT close
  the drain; the binding below is what closes it.

## The change (circuit side)

1. **dregg turn commits the terms.** In the borrow turn (`dregg/sdk/examples/dregg_borrow.rs`
   + `the_chain` make_turn), commit these cells into the position state so they flow into
   `final_root`:
   - `pool_id` (2 limbs, hi/lo 16-byte split — MATCH `split32`)
   - `borrower` (2 limbs, same split)
   - `debt`, `collateral`, `ltv_bps`, `nonce` (one field each)
   Order MUST be `[pool_hi, pool_lo, borr_hi, borr_lo, debt, collateral, ltv_bps, nonce]`
   — identical to `loan_commit_of`'s Poseidon input vector.

2. **Circuit exposes `poseidon(terms)` as the public input.** Replace the current public
   input (Poseidon-fold of the 25 claim lanes) with `PoseidonBn254(api, [the 8 term limbs])`
   using the validated gadget. The witness assigns the same via iden3 native Poseidon.
   (The claim-lane fold stays INSIDE the circuit binding final_root ↔ terms; only the
   exposed public input changes to poseidon(terms).)

3. **Prove on Hetzner** (CCX33, ~fold 23min + gnark setup 14min + prove 30s; see
   box-setup.sh). Emit `proof_terms.json` + `public_terms.hex`.

## The change (on-chain side — one-line flip, already written)

In `lending::borrow`, after the vk-verify + nullifier, add:
```move
assert!(payment_id == bcs::to_bytes(&loan_commit_of(object::id(pool), ctx.sender(), debt,
        coin::value(&collateral), ltv_bps, nonce)), EBadBinding);
```
(pass `ltv_bps` + `nonce` as borrow args; add `EBadBinding`). Then update
`lending_tests` `borrow_then_repay` to use `proof_terms` + `public_terms` and pass the
matching terms. Same flip in Solana `dregg_lending` (sync) + fold `loan_commit_of` into the
async accumulator so the batch proof binds terms too (closes CRITICAL #5).

## Verify (falsification)

Re-prove with debt=D → on-chain `borrow(debt=D)` PASSES; `borrow(debt=D+1)` with the same
proof ABORTS `EBadBinding` (public input no longer matches reconstructed commit). That's the
pool-drain closed: the disbursed amount is welded to the proof.

**Until this runs, the sync `lending.move` must NOT hold real money.** The async model's
`MAX_UNPROVEN_EXPOSURE` cap is the compensating control (bounds worst-case loss); keep it
tight. Report this state to Erik.
