#[test_only]
module rwa_batch::accumulator_tests {
    use rwa_batch::accumulator;

    #[test]
    fun batch_root_incremental_equals_full() {
        let c1 = 11111111u256; let c2 = 22222222u256; let c3 = 33333333u256;
        // full 3-loan batch root
        let full = accumulator::root(vector[c1, c2, c3]);
        // incremental fold (as loans arrive) must equal it
        let mut acc = 0u256;
        acc = accumulator::fold(acc, c1);
        acc = accumulator::fold(acc, c2);
        acc = accumulator::fold(acc, c3);
        assert!(full == acc, 1);
        assert!(full != 0, 2);
        // order matters (a different order => different root => can't substitute a batch)
        let swapped = accumulator::root(vector[c2, c1, c3]);
        assert!(swapped != full, 3);
    }
}
