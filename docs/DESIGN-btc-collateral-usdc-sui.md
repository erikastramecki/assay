# Design — native BTC collateral → USDC loan on Sui

**Status:** design / scoping (2026-07-14). Author-facing. No code yet.
**Goal (Erik):** a user locks **native BTC on the Bitcoin network** (we custody it there) and
receives a **USDC loan on Sui**. Repay the USDC → reclaim the BTC.

This extends the existing Assay stack (`dregg_lending_async` on Sui + the operator attestation
pattern). It is **not** a new protocol — it reuses the pool, the borrow-index accounting, the
Pyth oracle, and the ed25519-attested disburse. The one genuinely new thing is that **the
collateral does not live on Sui**, so it cannot be a `Coin<Collateral>` — it is an off-chain fact
the operator attests to.

---

## 1. Why this is different from the xStock flow

Today's `disburse_attested<Collateral, Stable>` takes a real `Coin<Collateral>` on Sui, locks it in
the `Position`, and returns it on repay. That works because xStock/SSPX collateral is a Sui object.

Native BTC is on Bitcoin L1. There is no `Coin<BTC>` on Sui. So the collateral leg splits in two:

| Concern | xStock flow (today) | BTC flow (this doc) |
|---|---|---|
| Collateral lock | `coin::into_balance` inside the `Position` (on-chain, non-custodial) | BTC sent to a **custody address on Bitcoin**, watched off-chain |
| Proof it's locked | the tx contains the Coin — self-evident | operator **attests** "txid T deposited A sats to address X, N confs" |
| Release on repay | `coin::from_balance` back to borrower (on-chain) | operator **broadcasts a Bitcoin tx** returning BTC to the borrower |
| Trust | trustless (Sui enforces) | **operator-custodial** (v1) — see §7 |

So the BTC flow is a **custodial** variant. dregg still enforces the USDC-side accounting (LTV, cap,
borrow-index, over-borrow refusal); it does **not** enforce the Bitcoin custody/release. That
honesty is the core tradeoff (§7) and the thing to decide before building.

---

## 2. Components

```
   Borrower                Bitcoin L1                 Operator (off-chain)              Sui
  ─────────           ──────────────────        ───────────────────────────      ─────────────────
  send BTC  ─────────▶ custody addr (per-loan) ──▶ btc-watcher (indexer)
                                                   │  confirms N blocks
                                                   ▼
                                            dregg authorize (LTV/oracle)
                                                   │  sign ed25519 attestation
                                                   ▼
  wallet ◀──────────────────────────────── /borrow: {attestation, terms} ──────▶ disburse_btc_attested
                                                                                   opens Position(btc ref)
                                                                                   sends USDC to borrower
  repay USDC ─────────────────────────────────────────────────────────────────▶ repay: burns debt,
                                                   ┌───────────────────────────────  emits BtcRelease{txid?}
                                                   ▼
                                            operator broadcasts BTC release ──▶ borrower's BTC addr
```

New pieces vs today:
1. **Bitcoin custody** — a per-loan deposit address whose key(s) the operator controls (§5).
2. **btc-watcher** — a Bitcoin node + indexer that confirms deposits (amount, confs) and watches
   for the release/liquidation path. (regtest for v1.)
3. **Contract: a BTC-collateral Position variant** (§4) — records a BTC *reference*, not a Coin.
4. Everything else (pool, oracle, operator API, attestation signer, borrow-index) is reused.

---

## 3. Lifecycle

**Open**
1. Borrower requests a loan for `A` BTC. Operator derives/assigns a **per-loan custody address** `X`
   and returns it + a `loanCommit`.
2. Borrower sends `A` BTC to `X`. btc-watcher waits for **N confirmations** (e.g. 3–6).
3. Operator runs dregg authorization on the USDC side (debt ≤ A·conservativeBtcPrice·LTV, oracle
   fresh) and — only if authorized — signs an **attestation** over the exact terms (§4).
4. Borrower (or the operator, see §5 note) submits `disburse_btc_attested` on Sui → the contract
   verifies the attestation, opens a `BtcPosition` recording `{borrower, btc_sats, btc_txid,
   custody_addr_hash, principal, index_snapshot}`, and sends USDC from the pool to the borrower.

**Repay**
5. Borrower repays `owed` USDC on Sui via `repay_btc`. Contract burns the debt, closes the position,
   and **emits `BtcReleaseRequested{position, btc_txid, borrower_btc_addr}`**.
6. btc-watcher sees the event, operator broadcasts a Bitcoin tx returning `A` BTC (minus network fee)
   to the borrower's BTC address. The release is recorded (txid) for auditability.

**Liquidate**
7. If `A·conservativeBtcPrice·LT < owed` (underwater), operator liquidates: sells/moves the custodied
   BTC, repays the pool the outstanding USDC (`liquidate_btc`, operator-cap gated), closes the position.
   Any surplus handling is a policy decision (return to borrower vs protocol).

---

## 4. Contract change

A new position type + two entries. The Position stores a **reference** to the BTC, not a balance.

```move
public struct BtcPosition<phantom Stable> has key {
    id: UID,
    borrower: address,
    btc_sats: u64,             // amount custodied
    btc_txid: vector<u8>,      // 32-byte deposit txid (audit ref)
    custody_addr_hash: vector<u8>, // hash of the custody address (binds which address holds it)
    principal: u64,
    index_snapshot: u256,
    batch_id: u64,
}
```

Attestation message (what the operator signs, verified on-chain via `sui::ed25519`):
```
bcs(borrower:address) ‖ bcs(debt:u64) ‖ bcs(btc_sats:u64) ‖ bcs(btc_txid) ‖ bcs(custody_addr_hash) ‖ bcs(loan_commit:u256)
```
i.e. the same shape as `disburse_attested` today, with the Coin's `collateral_amount` replaced by the
**BTC reference** (sats + txid + custody addr hash). The operator only signs after btc-watcher confirms
the deposit AND dregg authorizes — so a valid signature provably means "the BTC is really locked and
the loan is within LTV." This is the crux: **the attestation is the bridge** between Bitcoin custody
and Sui state, exactly as it already bridges dregg-authorization and Sui state today.

`disburse_btc_attested<Stable>(pool, debt, btc_sats, btc_txid, custody_addr_hash, loan_commit,
attestation, clock, ctx)`:
- verify ed25519 attestation against `pool.operator_pubkey`
- cap check + fold `loan_commit` into the batch accumulator (unchanged)
- open `BtcPosition`, take USDC from the pool, transfer to borrower.

`repay_btc<Stable>(pool, pos, payment, clock, ctx)`:
- assert `pos.borrower == sender` (the P5 fix applies here too)
- exact `owed`, burn debt, close position, **emit `BtcReleaseRequested`** for the watcher.

`liquidate_btc` — operator-cap gated, closes an underwater position after the operator has (off-chain)
seized/sold the BTC and repaid the pool.

**Replay note:** unlike the Coin flow (where re-submitting an attestation would require re-supplying a
Coin), a BTC attestation has no on-chain Coin gate — so it **must be single-use**. Bind it to the
`btc_txid` and reject a second `disburse` against the same txid (a `Table<txid, bool>` of consumed
deposits in the pool). This closes double-borrow-against-one-deposit.

---

## 5. Custody design

**v1 (honest-operator, regtest):** a per-loan address controlled by the operator.
- Simplest: operator holds a single hot key deriving per-loan addresses (BIP32). Watched by the
  Bitcoin node. Adequate for regtest + a controlled demo.
- Production-leaning: **threshold/MPC** (e.g. 2-of-3) so no single key can move funds; or a
  Bitcoin **multisig** with a timelock refund path (borrower can reclaim after T if the operator
  vanishes — reduces "operator runs off with the BTC" risk).

**Who submits `disburse_btc_attested`?** Two options:
- **Borrower-submitted** (preferred, matches today): operator returns the attestation, borrower sends
  the Sui tx. Fully parallel to `disburse_attested`. No collateral Coin needed on Sui, so no two-party
  problem — the borrower just needs SUI gas.
- **Operator-submitted**: operator sends the disburse itself. Simpler UX (borrower only touches
  Bitcoin) but the operator pays Sui gas + it's one more operator action.

Recommendation: borrower-submitted, same as the current flow.

---

## 6. Oracle + LTV

- **Feed:** BTC/USD Pyth (`0xe62df6c8…`), already wired + 24/7. No market-hours gap risk (unlike
  equities) → the tight staleness bound just works.
- **Conservative price:** `price − 2·conf` (unchanged).
- **LTV:** BTC is deep-liquid + 24/7, so it earns a **high** max-LTV (≈70–75%) with LT ≈ 80–85% —
  see `docs/LTV-RISK-FRAMEWORK.md`. The extra risk here is **not** price gap (it's 24/7) but
  **custody + settlement latency** (Bitcoin confirmations on deposit; broadcast + confirmation on
  release/liquidation). Liquidation can't be atomic — build a **confirmation-latency buffer** into
  LT (a few % for the ~10–60 min it takes to move BTC).

---

## 7. Trust model — the decision to make before building

| Property | Enforced by | Trust |
|---|---|---|
| Debt ≤ collateral·price·LTV | dregg kernel (operator) + on-chain re-check | **provable** (as today) |
| USDC accounting (index, cap, over-borrow) | Sui contract | **trustless** |
| Attestation can't be forged/tampered | `sui::ed25519` on-chain | **trustless** |
| "The BTC is actually locked" | operator + btc-watcher attest it | **operator-trusted** |
| BTC returned on repay | operator broadcasts the release | **operator-trusted** ← main risk |
| No double-borrow on one deposit | single-use txid gate on-chain | **trustless** |

So v1 is **honest-operator custodial on the Bitcoin side**. The user trusts us to (a) not seize the
BTC and (b) release it on repay. That is a *materially different* trust posture than the Sui-collateral
flow (which is non-custodial). It carries the same class of concern as the xStocks permanent-delegate
posture: **holding user BTC is custody**, with the attendant regulatory/security weight. Flagging this
as a first-class decision, not a footnote.

**Mitigations that raise the trust floor without a full trustless build:**
- Multisig/MPC custody (no single-key seizure).
- A **timelock refund** path on the custody address (borrower reclaims BTC unilaterally after T if the
  operator disappears) — this alone removes the worst failure mode.
- Public, signed **release receipts** (txid per repay) for auditability.

**v2 (trustless), for later:** a Bitcoin **SPV/light-client on Sui** (verify Bitcoin headers +
Merkle proofs in Move) so the *deposit* is proven on-chain instead of attested; plus a
threshold-signed / discreet-log-contract release so the *release* is enforced, not trusted. This is a
large, separate track (BTC light-client in Move is real research-grade work). Not v1.

---

## 8. Threats & handling

- **Reorg / double-spend of the deposit:** require N confirmations before attesting (N≥3 regtest,
  ≥6 mainnet); the watcher must re-org-detect and never attest an unconfirmed deposit.
- **Attestation replay / double-borrow:** single-use `btc_txid` gate on-chain (§4).
- **Custody key compromise:** MPC/multisig + timelock refund (§7).
- **Release griefing (operator won't release):** timelock refund path + public receipts.
- **Underwater during Bitcoin settlement latency:** LT buffer (§6); liquidation is operator-executed
  and async (matches the existing async-batch posture).
- **Oracle failure:** existing fail-closed policy (`applyOraclePolicy`) — refuse rather than mis-price.

---

## 9. Implementation plan (when green-lit)

- **P0 — contract:** `BtcPosition` + `disburse_btc_attested` / `repay_btc` / `liquidate_btc` + the
  single-use-txid table; Move tests incl. forged-attestation, replay-same-txid, repay-non-borrower.
- **P1 — btc-watcher:** a `bitcoind` regtest node + a small indexer that (a) confirms deposits to a
  custody address with N confs, (b) watches `BtcReleaseRequested` events and broadcasts releases.
  Custody = BIP32 per-loan addresses (v1) with a multisig+timelock upgrade path.
- **P2 — operator API:** `/borrow-btc` = assign custody address → wait for confirmed deposit →
  dregg authorize → sign the BTC attestation. `/repay` unchanged on the USDC side; release is
  event-driven off the watcher.
- **P3 — web:** a "Borrow against BTC" path: show the deposit address + QR, poll confirmations, then
  the same Sui disburse tx. Repay unchanged.
- **P4 — evidence:** full regtest loop (deposit BTC → borrow USDC on devnet → repay → BTC released),
  plus a pentest (forged attestation, replay same txid, repay-other, underwater liquidation).

Everything on **regtest + devnet + tiny amounts** to start (never mainnet BTC until custody + the
trust posture in §7 is resolved).

---

## 10. Open questions for Erik

1. **Custody posture for v1:** single hot key (fastest, demo-only) vs multisig+timelock (safer, more
   work)? Recommendation: build the demo on a single key but design the address/format for the
   timelock-refund path from day one.
2. **Do we hold BTC at all, or bridge to a wrapped-BTC-on-Sui instead?** An alternative that keeps the
   flow **non-custodial** is to accept a wrapped BTC that already exists as a `Coin` on Sui (if/when
   one is available) — then it's exactly the current `disburse_attested` path, no Bitcoin custody, no
   new contract. Worth deciding: **native-BTC-custodial** (what you asked) vs **wrapped-BTC-on-Sui
   non-custodial** (much less risk, but depends on a bridge/asset existing).
3. **Regulatory read on custody** before anything touches mainnet BTC (same gate as the xStocks posture).
```
