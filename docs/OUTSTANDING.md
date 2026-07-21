# Outstanding

Everything known-open, as of 2026-07-20. Written down so none of it lives only in someone's head.

---

## Blockers before any mainnet deployment

**1. No round has ever come back clean.** The stated gate is three auditors clean in the same
round. Six Move rounds and one Solidity round; none met it. Severity is falling and the remaining
items are mediums, but the gate is unmet and the code is unpushed-to-production for that reason.

**2. The ZK layer has never been audited, and cannot be.** `circuit/` contains a Poseidon gadget
and **no constraint system**. There is no `.zkey`, `.r1cs`, `.ptau` or `.wasm` anywhere. Audit
findings F1 and F4 both turn on what the batch proof binds, so the most load-bearing component in
the "provably safe" claim is the one nobody has been able to check.

**3. Both circuits must be re-proven upstream.** `dregg_lending` cannot originate and
`settle_batch` cannot succeed until they are. This is deliberate — a lending function that can be
drained must not originate loans — but it is blocked outside this repo.
`perloan-prep/RUNBOOK-terms-binding.md` still specifies the **pre-fix 8-term preimage**; it needs
the collateral-type term or the on-chain binding will never match.

**4. `README.md:5` claims "provably safe."** What the contracts currently enforce is an LTV check
against a signed price. That is a normal lending protocol's guarantee, not a proof. The claim
should be softened until the circuit work lands and is audited — especially given this repo now
publishes an audit trail that will be read alongside it.

**5. Republish required.** `Pool`, `Position` and `OperatorCap` all changed layout, so Sui cannot
upgrade in place. Needs a fresh package, a fresh pool, and a new `VITE_POOL`.

---

## Open findings

### Move (`move/`)

| Severity | Item |
|---|---|
| high | `disburse_entry` hands a cap holder the whole `pool.cap` against zero collateral — no signature, no delay, no pause check. **A trust-model decision, not a patch:** is the cap holder trusted with the full pool, or does that path need an attestation too? |
| medium | `repay` demands exact equality against a debt that grows every second, with no on-chain debt view to size it from. Fixed by construction in the Solidity port; not backported. |
| low | Faucet rate limit keyed on the raw request string, bypassable by address casing/padding. Devnet only. |

### Solidity (`rh-chain/`)

| Severity | Item |
|---|---|
| medium | `isUsMarketHours` uses a fixed UTC-5 offset, so the session window is an hour wrong during EDT. One existing test **enshrines the bug** by labelling EDT timestamps as ET. |
| medium | Market holidays: the feed stops updating but the clock says in-session, and the 25h staleness bound does not catch an 18–24h holiday gap. A source comment claims staleness covers this. It does not. |
| medium | `LivenessOracle` does not protect against outages **shorter than `maxHeartbeatAge`** — the restart-liquidation window it exists to close is still open below that threshold. |
| medium | Guard mutations still surviving a green suite, from the 18 the audit found. Each survivor is a guard nothing proves is load-bearing. |
| low | Dead declarations and hygiene. |

Nothing in `rh-chain/` is deployed to any network.

---

## Operational, before mainnet

- **Deploy the `LivenessOracle` keeper** under a supervisor with alerting. It exists and is tested;
  it is not running. A silently dead keeper degrades to "liquidations off" — safe, but an outage.
- **Split the keys.** The keeper's hot key must not be the cold guardian key, and the Sui keeper
  currently co-locates the `OperatorCap` and the operator signing key in one process, which
  collapses a two-party control into one.
- **Sequencer uptime feed.** Robinhood's docs say Chainlink provides one for Robinhood Chain; it is
  not on Chainlink's canonical list, not in the feed directory, and every contract from Chainlink's
  deployer on that chain resolves to a price feed. Either locate it (ask
  `chain-developers-group@robinhood.com`) or keep running on the keeper.
- **Verify who holds `ADMIN_BURNER_ROLE`.** On-chain it is a plain EOA with no multisig and no
  timelock — one key can destroy collateral inside a live pool. That is unmitigated on-chain and
  should be priced into LTV and disclosed to borrowers.

---

## Open questions

1. Can Robinhood's Trading MCP place the equity orders that become Stock Tokens, in the
   jurisdictions we care about? The agent half of the MVP is untested end-to-end.
2. Chainlink feed heartbeats are 86400s / 0.5% today. `rh-chain/script/fetch-feeds.mjs` fails loudly
   if that changes — but nothing runs it on a schedule yet.
3. Has `adminBurn` ever actually been used? Recoverable from `Transfer`-to-zero logs; frequency
   decides whether it is theoretical or operational.
