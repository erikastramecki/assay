# Move / Sui protocol — adversarial audit rounds 1–6

**Target:** `move/` · **Date:** 2026-07-19–20 · **Result:** 66 confirmed across six rounds ·
**No round ever came back clean.**

| Round | Audited | Confirmed | Ceiling |
|---|---|---|---|
| 1 | the codebase as it stood | 9 | 2 critical |
| 2 | the F2 fix | 10 | 1 critical |
| 3 | the R2 fixes | 17 | 2 critical |
| 4 | the R3 fixes | 9 | high |
| 5 | F1/F3/F4 structural fixes | 9 | high |
| 6 | the R5 fixes | 12 | high |

Severity fell steadily; findings did not stop. Rounds 5 and 6 are the honest ones to read, because
in each the highest-severity finding was **introduced by the previous round's fix**.

---

## Fixed (full detail — see the commits)

### F1 CRITICAL — the proof proved nothing about the loan (`dregg_lending::borrow`)
Gated on a nullifier and a Groth16 verify. `debt` was a free caller-supplied `u64`; collateral was
consumed without a single `coin::value` inspection. Nothing tied debt, collateral, sender or pool
to what the proof proved. `loan_commit_of` computed the correct binding and had **zero call sites**.

A verifier reproduced it with the repo's own fixture: any holder of one valid `(payment_id, proof)`
— *including an honest borrower issued a proof for a 50 USDC loan* — could call with
`debt = pool_liquidity()` and `coin::zero()` collateral and empty the pool, then replay against
every other pool pinning the same vk.

**Fix (`45287d9`, extended in `7d8584b`):** the proof's public input must equal a commitment over
the actual pool, sender, debt, collateral **amount and type**, LTV and nonce. Round 5 caught that
the first version bound the amount but not the **type** — a proof for 100e9 of a real RWA was
redeemable with 100e9 of a worthless coin the attacker publishes themselves.

### F2 CRITICAL — the operator attestation was a perpetual bearer instrument
No expiry, no nonce, no consumed-set, no pool binding — and it was the *only* solvency gate, since
the module has no on-chain oracle. Poll `/borrow` at a price peak, hold the signature through a
drawdown, redeem a peak-priced loan that is insolvent at origination. Replay compounded it.

**Fix (`6d9046a`):** expiry with a 120s ceiling, a `used_commits` nullifier, pool and stable-type
binding, and key rotation. Type names are BCS length-prefixed — raw concatenation would make
`("AB","C")` and `("A","BC")` identical bytes.

### F3 HIGH — liquidation checked nothing and seized everything
The doc comment claimed operator-attested, underwater-only liquidation. The body verified no
attestation, read no price, checked no health condition — the only gate was an **unused** `_cap`
parameter — and it seized 100% of collateral with no refund. A cap holder could liquidate a
perfectly healthy position at ~1.43×, repeatedly; and a position 1bp underwater forfeited
everything even with an honest operator.

**Fix (`d2f04fc`):** a signed, amount-bound, short-lived attestation plus surplus refunded to the
borrower. Adding a second signed message type also required domain separation — a refuted round-2
finding that became real the moment the code changed around it.

### F4 HIGH — `settle_batch` was permissionless and replayable
Public input was `bcs(batch_root)` alone. Groth16 is stateless, so a scraped proof could be
replayed to reset `total_pending` — the only global cap on unproven exposure — indefinitely.
**Fix (`f70a9ec`):** cap-gated, public input binds pool id and batch index, and the accumulator
folds unconditionally from `acc_0 = 0`.

### R2-1 CRITICAL — `OperatorCap` was not bound to a pool
`init_pool` is permissionless, so anyone could mint a cap and point it at someone else's pool.
None of seven cap-gated functions inspected it. A PoC drained a funded pool against 1 unit of a
self-minted worthless coin and seized 100,000 units from a healthy position.

### R2-2 HIGH — an unbounded rate curve bricked the pool permanently
An absurd `base_bps` made the accrual downcast abort, and every entrypoint calls accrue first —
**unrecoverable even by the operator**, since the repair transaction accrues before applying the
fix. A plain typo reached it.

### R2-3 / R4 — the low-order ed25519 key check, wrong twice
`0x00×32` is a low-order point and Sui's ZIP-215 verify **accepts any signature against it**,
turning the only solvency gate into a no-op. The first fix substituted two non-canonical encodings
for two genuine order-8 points, leaving both forgeable keys accepted. The second enumeration was
still incomplete — 4 of 14 valid encodings missing.

**Fix:** stopped enumerating. A canonical key encodes `y < p`, so all non-canonical forms are
rejected structurally, and all 14 encodings are asserted by test.

### R3, R5, R6 — the binding class, one level at a time
`Position` was not bound to its pool (R3). `total_pending` was released only by `settle_batch`,
which F4 had made impossible, so it accumulated over lifetime volume until `pool.cap` bricked all
borrowing (R5) — and the fix for that then **double-released** against `settle_batch`'s wholesale
reset, making the cap stop binding entirely (R6).

---

## Open

| # | Severity | Surface | Status |
|---|---|---|---|
| 1 | high | cap-holder trust model on the un-attested disburse path | open — design decision, not a patch |
| 2 | medium | `repay` exact-equality with no on-chain debt view | open |
| 3 | low | faucet rate-limit bypass | open |
| 4 | — | both circuits must be re-proven upstream | blocked externally |

The deployed devnet package predates these fixes and holds faucet-minted test coins only.

---

## What this actually cost, and bought

Three of the fix commits contained **claims the next round disproved**:

- F1's message said it closed "the collateral substitution." It closed *amount* substitution only.
- F3's said liquidation now took two parties. It did not — rotation and liquidation shared one cap
  with no delay, so both could happen in a single transaction.
- F4's said exposure was "still released by repay/liquidate." That was a different ledger. The one
  in question was released by nothing.

Four guards were deletable with a fully green suite, including `EOverCap` — the exact ledger round 5
existed to preserve. `loan_commit_of`'s Poseidon preimage could be **reordered**, or its hash
function swapped, with every test still passing.

The output that survived is the invariant list, and it is the thing that ported to Solidity when
the implementation did not:

1. Authorisation must bind the loan's actual terms — debt, collateral **amount and type**.
2. Liquidation needs a real health check and must refund surplus.
3. Every capability must be bound to the object it governs.
4. Exposure must release on close, exactly once, from exactly one place.
5. Rate parameters must be bounded; arithmetic must saturate, never trap funds.
6. Privileged changes need a timelock, so rotate-and-use is not atomic.
7. A guard is not covered until you have deleted it and watched a test fail.

## Not covered

The ZK layer was never audited — `circuit/` contains a Poseidon gadget and no constraint system,
and no `.zkey`/`.r1cs`/`.ptau` exists in the repo. Since F1 and F4 both turn on what the proof
binds, **the most load-bearing component is the one nobody could check.** The dregg kernel lives
outside this repo and was not reviewed.
