# Per-loan proof — next-session runbook (staged offline so the box run is quick)

**Goal:** a Groth16 proof whose public input binds a specific loan's amount, verified on-chain (Sui + Solana), plus the falsification (a proof rejects a different loan's public input). See DESIGN-rwa-marketplace.md for the math.

**Why this is now a short run, not archaeology:** we learned the exact alignment.
- **Emitter:** Erik's FORK `erikastramecki/dregg` main (`8ef3294`) — it *builds* (upstream `b458309` needs a newer plonky3; `8a232352` circuit crates don't build from a fresh clone). Its only flaw: it writes a **version-1** fixture; the vanilla gnark loader wants **version-4**.
- **plonky3-recursion:** `be52a51` (pairs with the fork emitter — it built loan A's fixture).
- **gnark:** the vanilla-patched `/tmp/gnark-tip/chain/gnark` (rsync from THIS Mac — that rsync is allowed; the plonky3 rsync was blocked, so plonky3 is git-cloned instead).

## The port (the whole reason last run stalled)
The v4 fixture = the v1 fixture **+ 4 things**. Teach the fork's `export_real_shrink_fri_fixture` (in `circuit-prove/src/apex_shrink_gnark_export.rs`) to add:
1. `version: 4` (currently 1)
2. `table_publics: Vec<Vec<u32>>` — each STARK table's public values
3. `claim_instance: usize` = `NUM_PRIMITIVE_TABLES + proof.non_primitives.position(op_type=="expose_claim")`
4. `apex_preprocessed_commit: Vec<u32>` = `publics[claim_instance][SETTLEMENT_CLAIM_LANES(25)..]`

`RealShrinkFriFixture` struct also needs those 3 fields added. **The exact upstream code is in this dir:** `v4_struct.rs` (the struct) and `v4_export_fn.rs` (the full v4 function, 564 lines — the fork's signature is identical, so this is a drop-in reference). Simplest: replace the fork's struct + function with these; fix any helper refs that don't resolve (the FRI helpers `bb_u32`/`ef_coords`/`obs_bb_slice` are shared, so most will).

## Loan binding (already proven to work)
In `circuit-prove/tests/apex_shrink_gnark_fixture.rs`, `the_chain()` is patched to `make_turn(debt, …)` where `debt` = `DREGG_LOAN_DEBT` env. `balance = debt` is committed into `final_root` → the 25-lane claim → the MiMC public input. (This edit generated loan A's real fixture last run — it works.)

## Steps
1. Provision CCX33 (fsn1, ubuntu-24.04) + 64G swap. (Hetzner API; ~€0.02/hr.)
2. `bash box-setup.sh` (this dir) — swap, rust, go, clone fork@8ef3294, clone plonky3@be52a51, build emitter.
3. From THIS Mac: `rsync -az /tmp/gnark-tip/chain/gnark/ root@IP:/root/dregg/chain/gnark/`.
4. Apply the port (v4 struct+fn) + confirm the `the_chain` loan edit. Rebuild emitter.
5. `DREGG_LOAN_DEBT=2000 cargo test -p dregg-circuit-prove --release --test apex_shrink_gnark_fixture -- --ignored --nocapture` (~27 min fold+shrink → version-4 fixture bound to debt=2000).
6. `cd chain/gnark && DREGG_SUI_PROVE=1 go test -run TestSuiVanillaProve -timeout 180m` (~14 min → dregg-vanilla-proof.json = proof_A + publics_A).
7. Pull proof_A back; `onchain-solana/converter` → Sui + Solana bytes.
8. Verify: Sui devnet verifier (pkg 0x1ef4…/or republish) + Solana localnet verifier → PASS.
9. **Falsification:** re-run steps 5–7 with `DREGG_LOAN_DEBT=3000` → publics_B; show proof_A verifies vs publics_A but **fails** vs publics_B, and publics_A ≠ publics_B. That's the on-chain per-loan binding, demonstrated.
10. Delete server + scrub token.

Est. box time: ~1.5–2 hr, mostly unattended compute.
