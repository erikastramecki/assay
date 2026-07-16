/// The async-lending BATCH ACCUMULATOR (Sui-native Poseidon).
///
/// As loans are disbursed, each loan's commit is folded into a rolling Poseidon
/// accumulator on-chain. The batch's dregg proof must expose this EXACT value as
/// its single public input, so `settle_batch` reconciles `proof.public_input ==
/// accumulator`. Poseidon is SNARK-friendly (cheap in the circuit) AND native on
/// Sui (`sui::poseidon`, cheap on-chain) — the two sides compute the same hash.
module rwa_batch::accumulator {
    use sui::poseidon::poseidon_bn254;

    /// Fold one loan commit into the accumulator. acc_0 = 0; acc_i = P([acc_{i-1}, c_i]).
    public fun fold(acc: u256, commit: u256): u256 {
        poseidon_bn254(&vector[acc, commit])
    }

    /// The batch root over an ordered set of loan commits — what the circuit exposes.
    public fun root(commits: vector<u256>): u256 {
        let mut acc = 0u256;
        let mut i = 0;
        let n = vector::length(&commits);
        while (i < n) {
            acc = fold(acc, *vector::borrow(&commits, i));
            i = i + 1;
        };
        acc
    }
}
