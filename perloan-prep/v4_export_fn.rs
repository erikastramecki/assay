pub fn export_real_shrink_fri_fixture(
    proof: &BatchStarkProof<DreggOuterConfig>,
    config: &DreggOuterConfig,
) -> Result<RealShrinkFriFixture, String> {
    if config.is_zk() != 0 {
        return Err("exporter assumes a non-ZK outer config".into());
    }
    if proof.ext_degree != D {
        return Err(format!("expected ext_degree {D}, got {}", proof.ext_degree));
    }
    let p = &proof.proof;
    let n = p.degree_bits.len();
    if p.commitments.random.is_some() {
        return Err("unexpected ZK randomization commitment".into());
    }
    if p.opened_values.instances.len() != n {
        return Err("instance count mismatch between opened values and degree_bits".into());
    }
    if NUM_PRIMITIVE_TABLES + proof.non_primitives.len() != n {
        return Err(format!(
            "instance count {} != {} primitive + {} non-primitive tables",
            n,
            NUM_PRIMITIVE_TABLES,
            proof.non_primitives.len()
        ));
    }

    // Public values in instance order: primitive tables have none, dynamic
    // tables carry theirs in the proof (rebuild_airs_pvs_common's order).
    let mut publics: Vec<Vec<BabyBear>> = vec![Vec::new(); NUM_PRIMITIVE_TABLES];
    publics.extend(proof.non_primitives.iter().map(|e| e.public_values.clone()));

    // The settlement claim channel: the shrink proof's OWN expose_claim table
    // (fixture v3 REQUIRES it — a claimless shrink cannot bind a settlement
    // statement; mint via `shrink_apex_to_outer_exposed`).
    let claim_instance = NUM_PRIMITIVE_TABLES
        + proof
            .non_primitives
            .iter()
            .position(|e| e.op_type.as_str() == "expose_claim")
            .ok_or(
                "shrink proof carries no expose_claim table — the settlement claim is unbound \
                 (mint with shrink_apex_to_outer_exposed, not the plain shrink)",
            )?;
    if publics[claim_instance].len() != SETTLEMENT_CLAIM_LANES + APEX_VK_LANES {
        return Err(format!(
            "shrink expose_claim table carries {} lanes, want {} claim + {} apex-VK \
             (mint with shrink_apex_to_outer_exposed, which pins+exposes the apex VK core)",
            publics[claim_instance].len(),
            SETTLEMENT_CLAIM_LANES,
            APEX_VK_LANES
        ));
    }
    let apex_preprocessed_commit: Vec<u32> = publics[claim_instance][SETTLEMENT_CLAIM_LANES..]
        .iter()
        .map(bb_u32)
        .collect();

    // Lookup contexts + preprocessed binding, rebuilt exactly as the verifier
    // rebuilds them (public fork API).
    let common = outer_shrink_prover(config)
        .rebuild_verifiable_common::<D>(proof, proof.w_binomial)
        .map_err(|e| format!("rebuild_verifiable_common failed: {e:?}"))?;

    // ---- Phase A: the pre-FRI transcript, mirrored + recorded --------------
    // Mirror of p3_batch_stark::verifier::verify_batch (rev 82cfad7) up to and
    // including the pcs.verify opened-value observes and the FRI alpha sample.
    let mut rec = Recorder::new(config.initialise_challenger());

    // observe_instance_count
    rec.obs_usize(n);
    // per-instance observe_instance_binding(ext_db, base_db, width, n_chunks)
    for i in 0..n {
        let inst = &p.opened_values.instances[i].base_opened_values;
        let ext_db = p.degree_bits[i];
        rec.obs_usize(ext_db);
        rec.obs_usize(ext_db); // base_db == ext_db (is_zk = 0)
        rec.obs_usize(inst.trace_local.len());
        rec.obs_usize(inst.quotient_chunks.len());
    }
    // observe_main: main commitment, then per-instance public values.
    rec.obs_cap(&p.commitments.main);
    for pv in &publics {
        rec.obs_bb_slice(pv);
    }
    // observe_preprocessed: widths (all instances), then the global commitment.
    let preprocessed_widths: Vec<usize> = (0..n)
        .map(|i| {
            common
                .preprocessed
                .as_ref()
                .and_then(|g| g.instances[i].as_ref().map(|m| m.width))
                .unwrap_or(0)
        })
        .collect();
    for &w in &preprocessed_widths {
        rec.obs_usize(w);
    }
    if let Some(global) = &common.preprocessed {
        rec.obs_cap(&global.commitment);
    }
    // sample_perm_challenges: global buses share, locals are fresh.
    let lookup_gadget = LogUpGadget::new();
    let n_ch = lookup_gadget.num_challenges();
    let mut seen_buses: HashMap<String, ()> = HashMap::new();
    for lookups in &common.lookups {
        for ctx in lookups.as_ref() {
            match &ctx.kind {
                Kind::Global(name) => {
                    if seen_buses.insert(name.clone(), ()).is_none() {
                        for _ in 0..n_ch {
                            let _ = rec.sample_ext();
                        }
                    }
                }
                Kind::Local => {
                    for _ in 0..n_ch {
                        let _ = rec.sample_ext();
                    }
                }
            }
        }
    }
    // observe_perm_and_sample_alpha.
    if let Some(perm_commit) = &p.commitments.permutation {
        rec.obs_cap(perm_commit);
        for data in p.global_lookup_data.iter().flatten() {
            rec.obs_ext(&data.cumulative_sum);
        }
    }
    let _alpha_constraints = rec.sample_ext();
    // observe_quotient_commitment; sample zeta.
    rec.obs_cap(&p.commitments.quotient_chunks);
    let zeta = rec.sample_ext();

    // ---- The PCS round structure (verify_batch's coms_to_verify) ----------
    let pcs = config.pcs();
    let ext_doms: Vec<OuterDomain> = p
        .degree_bits
        .iter()
        .map(|&db| outer_domain(pcs, 1usize << db))
        .collect();
    let zeta_nexts: Vec<EF> = ext_doms
        .iter()
        .map(|dom| {
            dom.next_point(zeta)
                .ok_or("next_point unavailable".to_string())
        })
        .collect::<Result<_, _>>()?;

    let mut coms: Vec<ComRound> = Vec::new();
    // The structural input-round shapes, built ALONGSIDE coms so the
    // (log_height, width, points, next-generator) tuples come from the same
    // objects the real pcs.verify consumes (self-check 1 below covers both).
    let mut input_rounds: Vec<FixtureInputRound> = Vec::new();
    let mat_shape = |domain: &OuterDomain, width: usize, num_points: usize, next_bits: usize| {
        FixtureInputMatrix {
            log_height: log2_strict(domain.size()) + OUTER_FRI_LOG_BLOWUP,
            width,
            num_points,
            next_point_bits: if num_points == 2 { next_bits } else { 0 },
        }
    };
    // Trace round.
    let mut trace_round = Vec::with_capacity(n);
    let mut trace_shape = Vec::with_capacity(n);
    for i in 0..n {
        let inst = &p.opened_values.instances[i].base_opened_values;
        let mut points = vec![(zeta, inst.trace_local.clone())];
        if let Some(next) = &inst.trace_next {
            points.push((zeta_nexts[i], next.clone()));
        }
        trace_shape.push(mat_shape(
            &ext_doms[i],
            inst.trace_local.len(),
            points.len(),
            p.degree_bits[i],
        ));
        trace_round.push((ext_doms[i], points));
    }
    coms.push((p.commitments.main.clone(), trace_round));
    input_rounds.push(FixtureInputRound {
        matrices: trace_shape,
    });
    // Quotient chunks round (natural domains of size 2^ext_db, flattened).
    let mut qc_round = Vec::new();
    let mut qc_shape = Vec::new();
    for i in 0..n {
        let inst = &p.opened_values.instances[i].base_opened_values;
        for chunk in &inst.quotient_chunks {
            qc_shape.push(mat_shape(&ext_doms[i], chunk.len(), 1, 0));
            qc_round.push((ext_doms[i], vec![(zeta, chunk.clone())]));
        }
    }
    coms.push((p.commitments.quotient_chunks.clone(), qc_round));
    input_rounds.push(FixtureInputRound { matrices: qc_shape });
    // Preprocessed round.
    if let Some(global) = &common.preprocessed {
        let mut pre_round = Vec::new();
        let mut pre_shape = Vec::new();
        for &inst_idx in &global.matrix_to_instance {
            let inst = &p.opened_values.instances[inst_idx].base_opened_values;
            let local = inst
                .preprocessed_local
                .as_ref()
                .ok_or("missing preprocessed_local for a preprocessed instance")?;
            let meta = global.instances[inst_idx]
                .as_ref()
                .ok_or("missing preprocessed metadata")?;
            let pre_domain = outer_domain(pcs, 1usize << meta.degree_bits);
            let mut points = vec![(zeta, local.clone())];
            if let Some(next) = &inst.preprocessed_next {
                points.push((zeta_nexts[inst_idx], next.clone()));
            }
            pre_shape.push(mat_shape(
                &pre_domain,
                local.len(),
                points.len(),
                p.degree_bits[inst_idx],
            ));
            pre_round.push((pre_domain, points));
        }
        coms.push((global.commitment.clone(), pre_round));
        input_rounds.push(FixtureInputRound {
            matrices: pre_shape,
        });
    }
    // Permutation round.
    if let Some(perm_commit) = &p.commitments.permutation {
        let mut perm_round = Vec::new();
        let mut perm_shape = Vec::new();
        for i in 0..n {
            let inst = &p.opened_values.instances[i];
            if !inst.permutation_local.is_empty() {
                perm_shape.push(mat_shape(
                    &ext_doms[i],
                    inst.permutation_local.len(),
                    2,
                    p.degree_bits[i],
                ));
                perm_round.push((
                    ext_doms[i],
                    vec![
                        (zeta, inst.permutation_local.clone()),
                        (zeta_nexts[i], inst.permutation_next.clone()),
                    ],
                ));
            }
        }
        coms.push((perm_commit.clone(), perm_round));
        input_rounds.push(FixtureInputRound {
            matrices: perm_shape,
        });
    }

    // ---- SELF-CHECK 1: the REAL pcs.verify accepts from the recorded state.
    // This validates every event recorded so far AND the round structure: the
    // pcs re-observes the opened values itself, samples alpha and the whole
    // FRI transcript, and re-checks all Merkle openings + the fold chains.
    {
        let mut ch = rec.ch.clone();
        <OuterPcsT as Pcs<EF, OuterChallenger>>::verify(
            pcs,
            coms.clone(),
            &p.opening_proof,
            &mut ch,
        )
        .map_err(|e| {
            format!(
                "REAL pcs.verify rejected from the mirrored transcript state \
                     (the prefix mirror or round structure diverges from verify_batch): {e:?}"
            )
        })?;
    }

    // pcs.verify's own opened-value observes (two_adic_pcs.rs:687-694), then
    // the FRI batch-combination alpha (verifier.rs:143).
    for (_, round) in &coms {
        for (_, mat) in round {
            for (_, values) in mat {
                for v in values {
                    rec.obs_ext(v);
                }
            }
        }
    }
    let alpha = rec.sample_ext();

    let prefix_events = rec.events;
    let ch0 = rec.ch; // positioned at the FRI commit phase

    // ---- Phase B: the FRI core, exactly as the gnark circuit will run it ---
    let fri = &p.opening_proof;
    let rounds = fri.commit_phase_commits.len();
    if fri.commit_pow_witnesses.len() != rounds {
        return Err("commit PoW witness count mismatch".into());
    }
    if fri.query_proofs.len() != OUTER_FRI_NUM_QUERIES {
        return Err(format!(
            "expected {OUTER_FRI_NUM_QUERIES} query proofs, got {}",
            fri.query_proofs.len()
        ));
    }
    for qp in &fri.query_proofs {
        if qp.commit_phase_openings.len() != rounds {
            return Err("query has wrong number of commit-phase openings".into());
        }
        for step in &qp.commit_phase_openings {
            if step.log_arity != 1 || step.sibling_values.len() != 1 {
                return Err("non-arity-2 commit round (fixture scope is arity 2)".into());
            }
        }
    }
    let log_global_max_height = rounds + OUTER_FRI_LOG_BLOWUP; // log_final_poly_len = 0
    let max_db = *p.degree_bits.iter().max().ok_or("no instances")?;
    if max_db + OUTER_FRI_LOG_BLOWUP != log_global_max_height {
        return Err(format!(
            "round count {rounds} inconsistent with max degree bits {max_db} + blowup {OUTER_FRI_LOG_BLOWUP}"
        ));
    }
    if fri.final_poly.len() != 1 {
        return Err("expected a constant final polynomial (log_final_poly_len = 0)".into());
    }

    // Real MMCSes for host-side re-verification (identical constants to the
    // config's own — dregg_poseidon2_bn254 is deterministic).
    let perm = dregg_poseidon2_bn254();
    let val_mmcs = OuterValMmcs::new(
        OuterHash::new(perm.clone()).map_err(|e| format!("{e:?}"))?,
        OuterCompress::new(perm),
        0,
    );
    let challenge_mmcs = OuterChallengeMmcs::new(val_mmcs.clone());
    let folding: TwoAdicFriFolding<
        Vec<BatchOpening<BabyBear, OuterValMmcs>>,
        <OuterValMmcs as Mmcs<BabyBear>>::Error,
    > = TwoAdicFriFolding(core::marker::PhantomData);

    let mut ch = ch0;
    let mut betas: Vec<EF> = Vec::with_capacity(rounds);
    for comm in &fri.commit_phase_commits {
        ch.observe(comm.clone());
        // commit_proof_of_work_bits = 0: check_witness is a no-op.
        betas.push(ch.sample_algebra_element());
    }
    ch.observe_algebra_slice(&fri.final_poly);
    for _ in 0..rounds {
        ch.observe(BabyBear::ONE); // the arity schedule (log_arity = 1)
    }
    if !ch.check_witness(OUTER_FRI_QUERY_POW_BITS, fri.query_pow_witness) {
        return Err("query PoW witness failed host-side check".into());
    }

    let mut roll_in_rounds: Option<Vec<usize>> = None;
    let mut queries_out: Vec<FixtureQuery> = Vec::with_capacity(fri.query_proofs.len());

    for (qi, qp) in fri.query_proofs.iter().enumerate() {
        let index = ch.sample_bits(log_global_max_height); // extra_query_index_bits = 0
        let ro = open_input_replica(
            OUTER_FRI_LOG_BLOWUP,
            log_global_max_height,
            index,
            &qp.input_proof,
            alpha,
            &val_mmcs,
            &coms,
        )?;
        if ro.first().map(|(lh, _)| *lh) != Some(log_global_max_height) {
            return Err(format!(
                "query {qi}: initial reduced opening not at max height"
            ));
        }
        let initial_eval = ro[0].1;

        // Serialize the input-batch openings (already host-verified by the
        // real val_mmcs.verify_batch inside open_input_replica), shape-checked
        // against the structural input_rounds.
        if qp.input_proof.len() != input_rounds.len() {
            return Err(format!(
                "query {qi}: {} input batches for {} structural rounds",
                qp.input_proof.len(),
                input_rounds.len()
            ));
        }
        let mut input_openings: Vec<FixtureInputBatch> = Vec::with_capacity(qp.input_proof.len());
        for (ri, (batch, round_shape)) in qp.input_proof.iter().zip(input_rounds.iter()).enumerate()
        {
            if batch.opened_values.len() != round_shape.matrices.len() {
                return Err(format!(
                    "query {qi} input round {ri}: {} opened rows for {} matrices",
                    batch.opened_values.len(),
                    round_shape.matrices.len()
                ));
            }
            for (row, m) in batch.opened_values.iter().zip(&round_shape.matrices) {
                if row.len() != m.width {
                    return Err(format!(
                        "query {qi} input round {ri}: row width {} != matrix width {}",
                        row.len(),
                        m.width
                    ));
                }
            }
            let max_lh = round_shape
                .matrices
                .iter()
                .map(|m| m.log_height)
                .max()
                .ok_or("empty input round")?;
            if batch.opening_proof.len() != max_lh {
                return Err(format!(
                    "query {qi} input round {ri}: path has {} levels, tree height is {max_lh}",
                    batch.opening_proof.len()
                ));
            }
            input_openings.push(FixtureInputBatch {
                rows: batch
                    .opened_values
                    .iter()
                    .map(|row| row.iter().map(bb_u32).collect())
                    .collect(),
                path: batch
                    .opening_proof
                    .iter()
                    .map(|d| bn254_hex(&d[0]))
                    .collect(),
            });
        }
        let mut ro_iter = ro[1..].iter().peekable();

        let mut folded = initial_eval;
        let mut domain_index = index;
        let mut log_current = log_global_max_height;
        let mut q_roll_rounds: Vec<usize> = Vec::new();
        let mut q_roll_vals: Vec<EF> = Vec::new();
        let mut siblings: Vec<[u32; 4]> = Vec::with_capacity(rounds);
        let mut merkle_paths: Vec<Vec<String>> = Vec::with_capacity(rounds);

        for (r, step) in qp.commit_phase_openings.iter().enumerate() {
            let sib = step.sibling_values[0];
            let bit = domain_index & 1;
            let evals: Vec<EF> = if bit == 0 {
                vec![folded, sib]
            } else {
                vec![sib, folded]
            };
            domain_index >>= 1;
            let log_folded = log_current - 1;

            challenge_mmcs
                .verify_batch(
                    &fri.commit_phase_commits[r],
                    &[Dimensions {
                        width: 2,
                        height: 1 << log_folded,
                    }],
                    domain_index,
                    BatchOpeningRef::new(core::slice::from_ref(&evals), &step.opening_proof),
                )
                .map_err(|e| {
                    format!("query {qi} round {r}: commit-phase Merkle opening failed: {e:?}")
                })?;

            folded = <TwoAdicFriFolding<_, _> as FriFoldingStrategy<BabyBear, EF>>::fold_row(
                &folding,
                domain_index,
                log_folded,
                1,
                betas[r],
                evals.into_iter(),
            );
            log_current = log_folded;

            if let Some((_, v)) = ro_iter.next_if(|(lh, _)| *lh == log_current) {
                folded += betas[r] * betas[r] * *v; // beta^arity = beta^2
                q_roll_rounds.push(r);
                q_roll_vals.push(*v);
            }

            siblings.push(ef_coords(&sib));
            merkle_paths.push(
                step.opening_proof
                    .iter()
                    .map(|d| bn254_hex(&d[0]))
                    .collect(),
            );
        }
        if log_current != OUTER_FRI_LOG_BLOWUP {
            return Err(format!("query {qi}: fold ended at height {log_current}"));
        }
        if ro_iter.next().is_some() {
            return Err(format!("query {qi}: unconsumed reduced openings"));
        }
        // final_poly is a constant: its evaluation at any x is coefficient 0.
        if folded != fri.final_poly[0] {
            return Err(format!(
                "query {qi}: fold chain does not reach the final polynomial \
                 (transcript or reduced-opening replica diverges)"
            ));
        }
        match &roll_in_rounds {
            None => roll_in_rounds = Some(q_roll_rounds.clone()),
            Some(expected) if *expected != q_roll_rounds => {
                return Err("roll-in schedule differs across queries".into());
            }
            _ => {}
        }
        queries_out.push(FixtureQuery {
            expected_index: index as u64,
            initial_eval: ef_coords(&initial_eval),
            roll_ins: q_roll_vals.iter().map(ef_coords).collect(),
            siblings,
            merkle_paths,
            input_openings,
        });
    }

    Ok(RealShrinkFriFixture {
        version: 4,
        description: "REAL dregg apex shrink proof (BatchStarkProof<DreggOuterConfig> over a real \
                      ir2_leaf_wrap apex) WITH the 25-lane chain claim AND the 8-lane apex \
                      VK-core (the apex's preprocessed commitment, in-circuit pinned via \
                      pin_preprocessed_commit) re-exposed through the shrink proof's own \
                      expose_claim table (shrink_apex_to_outer_exposed): pre-FRI transcript \
                      events + per-instance table public values + FRI commit-phase data + \
                      per-query INPUT-BATCH openings (open_input) for the chain/gnark native \
                      verifier."
            .into(),
        degree_bits: p.degree_bits.clone(),
        table_publics: publics
            .iter()
            .map(|pv| pv.iter().map(bb_u32).collect())
            .collect(),
        claim_instance,
        apex_preprocessed_commit,
        fri: FixtureFriShape {
            log_blowup: OUTER_FRI_LOG_BLOWUP,
            log_final_poly_len: 0,
            max_log_arity: 1,
            num_queries: OUTER_FRI_NUM_QUERIES,
            commit_pow_bits: 0,
            query_pow_bits: OUTER_FRI_QUERY_POW_BITS,
            extra_query_index_bits: 0,
            rounds,
            log_global_max_height,
        },
        prefix_events,
        commit_roots: fri
            .commit_phase_commits
            .iter()
            .map(|cap| {
                let roots = cap.roots();
                assert_eq!(roots.len(), 1, "cap_height 0 ⇒ single root");
                bn254_hex(&roots[0][0])
            })
            .collect(),
        expected_betas: betas.iter().map(ef_coords).collect(),
        final_poly: fri.final_poly.iter().map(ef_coords).collect(),
        query_pow_witness: bb_u32(&fri.query_pow_witness),
        roll_in_rounds: roll_in_rounds.unwrap_or_default(),
        input_rounds,
        queries: queries_out,
    })
}
