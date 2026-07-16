#[test_only]
module dregg_verifier::batch_reconcile_test {
    use dregg_verifier::verifier;
    use sui::poseidon::poseidon_bn254;

    fun vk(): vector<u8> { x"a6eec2ad02d10a25c08b8084674e60c76a1260f56e09eab71b7e54ac46da6d1e1b70944f328460bdba78f71677b55417af00574eacb103945b5463cff245d31e315d99490e156097045a0433277b6afd15ca35914fe72fe828cf126b633a8807f2b77c8127f5c64117c41ca289407e1884cd5f9cdb17cc3fa8fbd16b39eef7244e8f3213c8b4ea58442e31d1a8e087f94eaa3096d7d664fbf3f630f8c56b9a8a387e13c9d7509d9b928411852778909249e68c8ccb54669bcff0b7ff1cebb7157ac16bf54d5d491c7990558184264b68ab9519410f625bdee50ac2b4f7d88b900200000000000000aa653bc670f990ddbf7ee34c22b252073d25e7cd5c7b9b1bc4e9c8777c874c0d0fd1b7b4306c88e7bc3e9427e84548de2a0aca69b093a45a450217f543bb3797" }
    fun proof(): vector<u8> { x"39a835ffe671abd73bd891a1a3465f31f1b487e163a20b6afe80d0938f31fc2f6485df06be0760ebaacce31b7e0a4e3d88408c4ea8c5cbc2c534038bf99afe0f4214db1628d5e58edae6733e9bd59eaa057d3025cf4de06e2476949274fff98590a11636420141917c0d65716e976ca605f9713f6c863e65218a029168d36300" }
    fun public_input(): vector<u8> { x"15746868a2bd2e45acc95f4a9c908a3155fa53cf65c0cebc59142cb0a8163f01" }
    fun lanes(): vector<u256> { vector[421210617u256,1637814550u256,431291584u256,1953496675u256,369364366u256,1006647231u256,1866996710u256,48274474u256,475853519u256,766719301u256,209460128u256,156803433u256,548349625u256,139347276u256,174962960u256,1721084437u256,2u256,1452650278u256,1371598315u256,900534217u256,247034909u256,1097876273u256,883942418u256,247917708u256,237544049u256] }

    // The batch proof's public input is a POSEIDON fold of the claim lanes, and the
    // on-chain sui::poseidon recomputes it independently — the reconciliation that
    // lets settle_batch check proof.public_input == on-chain accumulator.
    #[test]
    fun batch_proof_verifies_and_reconciles() {
        // 1) the dregg proof (Poseidon public input) verifies on-chain via sui::groth16
        assert!(verifier::verify(vk(), public_input(), proof()), 1);
        // 2) sui::poseidon recomputes that exact public input from the claim lanes
        let ls = lanes();
        let mut acc = 0u256;
        let mut i = 0;
        while (i < vector::length(&ls)) {
            acc = poseidon_bn254(&vector[acc, *vector::borrow(&ls, i)]);
            i = i + 1;
        };
        assert!(acc == 0x013f16a8b02c1459bccec065cf53fa55318a909c4a5fc9ac452ebda268687415u256, 2);
    }
}
