pub struct RealShrinkFriFixture {
    pub version: u32,
    pub description: String,
    /// Per-instance `log2(extended trace domain)` of the shrink proof.
    pub degree_bits: Vec<usize>,
    /// Per-instance table PUBLIC VALUES (canonical BabyBear lanes), in
    /// instance order — primitive tables carry none; the `expose_claim`
    /// instance carries the re-exposed 25-lane chain claim FOLLOWED BY the
    /// 8 apex VK-core lanes (the apex's preprocessed commitment — see
    /// [`shrink_apex_to_outer_exposed`], THE APEX-VK PIN). These are the
    /// exact values `verify_batch` observes into the transcript right after
    /// the main commitment, and the `ExposeClaimAir` constraints bind them to
    /// the committed trace.
    pub table_publics: Vec<Vec<u32>>,
    /// Instance index of the shrink proof's own `expose_claim` table (the
    /// settlement claim channel).
    pub claim_instance: usize,
    /// The apex's preprocessed commitment (the deployed dregg apex's
    /// VK-identity core, 8 canonical BabyBear lanes) — a labeled copy of
    /// `table_publics[claim_instance][25..33]`, the value
    /// `chain/gnark/settlement_circuit.go` bakes as `apexPreprocessedCommit`.
    /// Fail-closed cross-checked against the claim-channel tail by the gnark
    /// loader.
    pub apex_preprocessed_commit: Vec<u32>,
    pub fri: FixtureFriShape,
    /// The pre-FRI transcript, `initialise_challenger()` through the FRI
    /// batch-combination alpha sample (inclusive).
    pub prefix_events: Vec<FixtureEvent>,
    /// Commit-phase Merkle roots (native BN254), in round order.
    pub commit_roots: Vec<String>,
    /// Expected betas (pinned in-circuit after each root observe).
    pub expected_betas: Vec<[u32; 4]>,
    /// Final polynomial coefficients (length `2^log_final_poly_len`).
    pub final_poly: Vec<[u32; 4]>,
    /// The query proof-of-work witness.
    pub query_pow_witness: u32,
    /// Rounds AFTER whose fold a reduced opening rolls in (ascending;
    /// identical across queries — the input heights are structural).
    pub roll_in_rounds: Vec<usize>,
    /// The structural PCS input-round shapes (trace, quotient, preprocessed,
    /// permutation — `verify_batch`'s `coms_to_verify` order).
    pub input_rounds: Vec<FixtureInputRound>,
    pub queries: Vec<FixtureQuery>,
}
