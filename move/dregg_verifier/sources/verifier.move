/// On-chain BN254 Groth16 verification for dregg proofs (M1 foundation).
/// The dregg STARK is wrapped to a BN254 Groth16 proof off-chain; THIS verifies
/// it natively on Sui via `sui::groth16`. Settlement (M4) will gate fund release
/// on `verify` + a public-input binding.
module dregg_verifier::verifier {
    use sui::groth16;

    use sui::event;

    /// Emitted by `assert_verify` on a successful on-chain verification.
    public struct Verified has copy, drop { ok: bool }

    const EProofInvalid: u64 = 0xDEAD;

    /// Verify a BN254 Groth16 proof against a verifying key + public inputs.
    /// Pure: no funds, no state. Returns true iff the proof is valid.
    public fun verify(
        vk_bytes: vector<u8>,
        public_inputs_bytes: vector<u8>,
        proof_bytes: vector<u8>,
    ): bool {
        let curve = groth16::bn254();
        let pvk = groth16::prepare_verifying_key(&curve, &vk_bytes);
        let public_inputs = groth16::public_proof_inputs_from_bytes(public_inputs_bytes);
        let proof = groth16::proof_points_from_bytes(proof_bytes);
        groth16::verify_groth16_proof(&curve, &pvk, &public_inputs, &proof)
    }

    /// On-chain entry: aborts (`EProofInvalid`) if the proof does NOT verify, so a
    /// successful transaction IS the on-chain proof of verification. Emits `Verified`.
    public entry fun assert_verify(
        vk_bytes: vector<u8>,
        public_inputs_bytes: vector<u8>,
        proof_bytes: vector<u8>,
    ) {
        assert!(verify(vk_bytes, public_inputs_bytes, proof_bytes), EProofInvalid);
        event::emit(Verified { ok: true });
    }
}
