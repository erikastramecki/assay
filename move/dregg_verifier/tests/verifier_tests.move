#[test_only]
module dregg_verifier::verifier_tests {
    use dregg_verifier::verifier;

    // Fixtures from groth16-gen (arkworks BN254, mul circuit a*b=c, c=12 public).
    // Regenerate with: cargo run -p groth16-gen
    fun vk(): vector<u8> {
        x"fbbcda2ed91e46826da705bdaa656f9ccf172aaf09e1e1d57707242d67e7cd968083f9cf87359056b1f6bee4ea162474eb7862a131dedee463444eb83028a32febd26ac16f97b2c7dd656b8f6e10373b5767ac6a833f978e6799cc08eb105413e74eba28ef0d72a90006fa8610ba307a11a6b5cff5421eb70503ece937bbf22ca9d436b67b6a89f2acfc2f4f2d92691e02626bda2639aa9e6f4bfc6a64c1be2b7e9a9bf1611dffb594ccf6a8343fe043c09421bfc22756a29c2247c0a95f1301a22a2ce175eed043ba8d6aac5f2336aafe00ec01c96bbbd0b5cf5178d91e392302000000000000008d4becb19bf8f54d7080253255b43696cd69dde5129ec5c607486d1273ac75a2e0ec6b4db7ee2a6f9ac6ae4d092109e048d58b2333895457c1fb26e834d45981"
    }
    fun proof(): vector<u8> {
        x"788023050a95454051e17d8adcc92f9b6ea856db73380d43bb4289fe377fadafe7b7aead413c38b38c6acea706cec13f3307c5185f0632e3141812603bdf672cd2b1c2dc1865583bd8c9d4f670e802914817aa3247bb8e328d8e94a80f4eaeafb5da4609053c4ea7abc2b1f51f296be8a5dc191fd3e375284e16efdf4e07fc13"
    }
    // public input c = 12 (0x0c), little-endian 32-byte BN254 Fr
    fun public_12(): vector<u8> {
        x"0c00000000000000000000000000000000000000000000000000000000000000"
    }
    // c = 13 — WRONG (the proof is for 12); verification must fail.
    fun public_13(): vector<u8> {
        x"0d00000000000000000000000000000000000000000000000000000000000000"
    }

    #[test]
    fun real_proof_verifies() {
        assert!(verifier::verify(vk(), public_12(), proof()), 100);
    }

    #[test]
    fun wrong_public_input_rejected() {
        // Not vacuous: the SAME proof against a different public input must fail.
        assert!(!verifier::verify(vk(), public_13(), proof()), 101);
    }
}
