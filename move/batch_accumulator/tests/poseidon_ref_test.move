#[test_only]
module rwa_batch::poseidon_ref_test {
    use sui::poseidon::poseidon_bn254;
    // circomlib/iden3 Poseidon test vector: poseidon([1,2]) ==
    // 7853200120776062878684798364095072458815029376092732009249414926327459813530
    #[test]
    fun sui_is_circomlib_poseidon() {
        let h = poseidon_bn254(&vector[1u256, 2u256]);
        assert!(h == 7853200120776062878684798364095072458815029376092732009249414926327459813530u256, (h as u64));
    }
}
