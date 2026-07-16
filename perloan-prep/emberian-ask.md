# Message to emberian (dregg) — build question + contribution goodwill

_Draft for the dregg Discord or a discussion issue. Honest + humble: it's a
question (we may be missing a build step), not a bug report._

---

Hey — building on dregg and wanted to ask a build question, plus flag two contributions.

**What we're doing:** we put dregg's settlement proof on-chain on **Sui** (native `sui::groth16`) and **Solana** (native `alt_bn128`) — a real `SettlementCircuit` proof verified on Sui mainnet, and the same vanilla proof verifying on Solana (~79k CU). Now we're trying to make the proof's public input bind **application state** (a specific payment/loan's amount) rather than a fixed digest — i.e. regenerate the shrink fixture from a turn whose committed state carries that value.

**The question:** what's the intended way to **build `dregg-circuit-prove` / regenerate `chain/gnark/fixtures/apex_shrink_fri_real.json`** from a fresh clone? On a clean checkout of `main`, `cargo test -p dregg-circuit-prove --release --test apex_shrink_gnark_fixture` fails with **undeclared deps** — `rayon`, `num_bigint`, `wgpu` are `use`d across `circuit/src/*` and `circuit-prove/src/gpu_backend.rs` but aren't in those crates' manifests. Since `apex_shrink_fri_real.json` is **committed**, I suspect the emitter path just isn't exercised from a fresh clone — is there a vendored setup / feature / `just` recipe we're missing? (This is adjacent to #39/#40 "fresh checkout fails.")

**Two contributions, ready when useful:**
1. **Sui on-chain verification + settlement backend** — the `SettlementCircuitSui` vanilla-ization (rangecheck→bit-decomposition drops the gnark commitment; 25 lanes → 1 via MiMC to fit the 8-input verifier) + a Move verifier/settlement, verified on mainnet. (This is issue #45.)
2. **Solana verifier + settlement** — native `alt_bn128` Groth16 for dregg proofs; the same vanilla proof verifies. Ready to PR alongside #45.

Happy to share the exact repro for the build question. Thanks!
