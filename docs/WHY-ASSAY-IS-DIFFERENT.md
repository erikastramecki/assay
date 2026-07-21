# Why Assay is different — and why it's safer

A plain-language explainer of how Assay's lending protocol differs from the lending apps that
already exist on Sui and Solana, and why a user is safer here.

---

## What everyone else does (the status quo)

The established lending protocols — **Aave**, **Kamino**, **Solend/Save**, **MarginFi** on Solana;
**Suilend**, **NAVI**, **Scallop** on Sui — are all variations of the same design:

- You deposit collateral, you borrow another asset against it.
- A **smart contract** enforces the rules (how much you can borrow, when you get liquidated).
- Prices come from an **oracle** (Pyth, Switchboard, Chainlink).
- If your loan gets unhealthy, **liquidators** repay it and take your collateral.

The thing they all have in common: **you're trusting audited code.** Smart people (audit firms)
read the contract and looked for bugs. That's the whole safety model — "experts checked it, and
it's been running a while without blowing up." It usually works. But the multi-billion-dollar
hacks in DeFi are almost all the same story: audited code that had a bug nobody caught.

---

## What Assay does differently

> **Read this first — the design vs. what is deployed.** Points 1 and 2 below describe where this
> is going, and each one states its real status inline. Points 3, 4, and 5 are live and enforced on
> every loan today. The full status table is in the [README](../README.md); everything known-open is
> in [OUTSTANDING.md](OUTSTANDING.md).

**1. The core rule is designed to be mathematically *proven*, not just audited.**
Assay's enforcement is built around **dregg**, a formally-verified (Lean 4) kernel. The one
invariant that keeps a lending protocol solvent —

> *you can never borrow more than your collateral safely supports*
> (`debt ≤ collateral × conservative_price × LTV`)

— is **machine-checked math** in the kernel. Not "we tested it," not "an auditor read it" — a proof
assistant verified it holds for *every* possible input.

*Status: the kernel is real and verified, but it is not yet what gates the live deployment.* When
the kernel is absent the operator falls back to an equivalent in-process LTV check and reports which
one ran via `authMode`. On Robinhood Chain there is no dregg at all — the limit is enforced by the
Solidity contract against a Chainlink feed. That is the same guarantee Aave gives, and we describe
it that way rather than borrowing the kernel's credibility for it.

**2. Settlement is designed to be gated by a real cryptographic proof, on-chain.**
dregg produces a zero-knowledge proof (STARK → Groth16) that a batch of loans is valid, and that
proof is **verified on-chain by Sui's native `sui::groth16`** before the batch finalizes.

*Status: the verifier is deployed and live on Sui; the circuits are not.* `dregg_lending` cannot
originate and `settle_batch` cannot succeed until both circuits are re-proven upstream, and the
circuits **have never been audited** — `circuit/` currently holds a Poseidon gadget and no
constraint system. The gate is therefore **disabled rather than quietly trusted**, which is the
only honest way to ship a proof system that isn't finished.

**3. The oracle is conservative and fails *closed*.**
Most protocols price you at the oracle's mid price. Assay prices collateral at the **conservative
price** (`price − 2× the oracle's own confidence band`) — it deliberately under-values your
collateral so a noisy print can't over-lend. A **stale** price is refused outright rather than
risked. Refusing is the safe default; most protocols keep lending.

*Status, precisely:* on Sui, a closed underlying market **tightens** the staleness bound (60s → 15s)
rather than refusing the loan — `operator/pyth.mjs` does not fail closed off-session. Outright
session refusal exists only in `AssayMarkets.canBorrow` on the Robinhood Chain port, which is not
yet deployed. Closing that gap on Sui is tracked in [OUTSTANDING.md](OUTSTANDING.md).

**4. Non-custodial by construction.**
The operator that authorizes a loan **never holds your funds and never co-signs your transaction**
(`disburse_attested` takes no `OperatorCap` — there is no two-party transaction).
It signs a one-time cryptographic *attestation* over your exact loan terms; your own wallet sends
the transaction, and the on-chain contract verifies the attestation. Nobody can move your
collateral except the on-chain contract rules.

**5. Real-world assets and crypto in one venue, with honest risk tiers.**
Tokenized stocks and crypto in the same pool, but each gets risk discipline appropriate to it:
crypto is 24/7 so it gets higher LTV; single-name stocks get **lower** LTV plus the market-hours
oracle guard, because a tokenized share trades 24/7 while the real stock market is only open
~6.5 hours a day — that gap is a risk, and we price it in. On Robinhood Chain the contract enforces a
**minimum 20-point gap** between LTV and the liquidation threshold — that gap is the invariant,
chosen to absorb a weekend the position cannot be liquidated into. The launch proposal is 35/55,
which is a governed parameter, not a protocol constant. Fork-tested against the real Chainlink
feed at 35/55, a position at max LTV survives a 30% drop and is underwater by 40%; the arithmetic
break point is −36.4% (`0.35 / 0.55`).

**6. Multi-chain, because the collateral is.**
The assets worth borrowing against do not all live on one chain, so Assay deploys to each on that
chain's own terms rather than bridging everything to a preferred home:

- **Sui** — where the verified-kernel path is built. Move's type system hashes the collateral's
  type into the loan commitment, so a position cannot be reopened against a cheaper asset; that is
  enforced by the type system rather than by a check we remembered to write.
- **Robinhood Chain** (Arbitrum Orbit L2, chainId 4663) — where the real tokenized equities already
  are, so an agent can buy a stock and borrow against it without a bridge. We could not locate a Chainlink
  sequencer-uptime feed for this chain — their docs say one exists, we could not find it, and their
  docs have already been wrong about this chain once — so rather than assume, we run a keeper
  heartbeat (`LivenessOracle`) and keep liquidations disabled through a grace period after any
  outage. Note it gates liquidation only; borrowing is not blocked by an undetected outage.

Different chains give different guarantees. We state which one you are getting per deployment
instead of averaging them into a single marketing claim.

---

## Why *you're* safer here (in one paragraph)

Every other lending app is "trust the audit." Assay is built to be "trust the proof" — and until
that lands, we tell you exactly which of the two you are getting. The single rule that can
bankrupt a lending protocol — letting someone borrow more than their collateral covers — is
**designed to be enforced by a formally-verified kernel** on Assay — see the status table in the
README for what is live today. What you get right now is a conservative valuation, an on-chain limit
enforced by the contract that holds the money, and a system that **refuses** rather than guesses
when a price is stale or a market is shut. What you get when the kernel path lands is that same
rule, machine-checked. We publish which one is running.

---

## Being honest about the limits (what proof does *not* cover)

Formal verification is powerful but it is not magic, and overclaiming would be the opposite of safe:

- **It covers the enforcement invariant, not every line of the app.** The proven part is the
  solvency rule + the on-chain proof check. The website, the operator service, and the liquidation
  keeper are ordinary software with ordinary risk.
- **Oracle risk still exists.** We make it conservative and fail-closed, but if Pyth itself
  published a badly wrong price within its confidence band, that's a residual risk (as it is
  everywhere).
- **Liquidation is not instant.** Like all lending, a fast crash can outrun liquidators; the
  conservative LTV is the buffer.
- **The current hosted demo runs a fallback.** The live devnet demo authorizes loans with an
  operator-side LTV+oracle check (the serverless host has no Rust runtime for the dregg kernel);
  the **on-chain guards are fully real**, and the **verified kernel** runs in the full (non-serverless)
  deployment. The response is labeled `authMode` so it's never misrepresented.
- **It's early.** Devnet, test assets, tiny amounts. None of this has the battle-testing that the
  incumbents have — proof reduces a *class* of risk; time reduces a different class.

The honest pitch: **Assay is built to remove the single largest category of DeFi lending failure —
a bug that lets the protocol lend more than it should — by proving that path instead of hoping the
audit caught everything.** The kernel that does it is real and verified; wiring it to be the thing
that gates every live loan is the work still in front of us, and the status tables say exactly how
far along that is.

In the meantime we do the unglamorous version of the same idea: **we attack our own code and publish
what we find, clean or not.** Six adversarial rounds on the Move protocol produced 66 confirmed
findings and not one round came back clean the first time; the Solidity port's first round found 19
confirmed and refuted 5. All of it is in [audits/](audits/), including the rounds that made us look
bad, because an audit trail you only publish when it is flattering is not an audit trail.
