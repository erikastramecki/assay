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

**1. The core rule is mathematically *proven*, not just audited.**
Assay's enforcement runs on **dregg**, a formally-verified (Lean 4) kernel. The one invariant that
keeps a lending protocol solvent —

> *you can never borrow more than your collateral safely supports*
> (`debt ≤ collateral × conservative_price × LTV`)

— is **machine-checked math**. Not "we tested it," not "an auditor read it" — a proof assistant
verified it holds for *every* possible input. A bug somewhere else in the app can't produce bad
debt through that path, because the path is proven.

**2. Settlement is gated by a real cryptographic proof, on-chain.**
dregg produces a zero-knowledge proof (STARK → Groth16) that a batch of loans is valid, and that
proof is **verified on-chain by Sui's native `sui::groth16`** before the batch finalizes. The
protocol literally cannot settle a batch that doesn't verify. (This is already proven live on Sui —
see `docs/EVIDENCE-2026-07-14.md`.)

**3. The oracle is conservative and fails *closed*.**
Most protocols price you at the oracle's mid price. Assay prices collateral at the **conservative
price** (`price − 2× the oracle's own confidence band`) — it deliberately under-values your
collateral so a noisy print can't over-lend. And if a price is **stale**, or a **stock market is
closed** while its tokenized share keeps trading, Assay **refuses the loan** rather than risk a bad
price. Refusing is the safe default; most protocols keep lending.

**4. Non-custodial by construction.**
The operator that authorizes a loan **never holds your funds and never co-signs your transaction.**
It signs a one-time cryptographic *attestation* over your exact loan terms; your own wallet sends
the transaction, and the on-chain contract verifies the attestation. Nobody can move your
collateral except the proven contract rules.

**5. Real-world assets and crypto in one venue, with honest risk tiers.**
Tokenized stocks (xStocks) and crypto in the same pool, but each gets risk discipline appropriate
to it: crypto is 24/7 so it gets higher LTV; single-name stocks get **lower** LTV plus the
market-hours oracle guard, because a tokenized share trades 24/7 while the real stock market is
only open ~6.5 hours a day — that gap is a risk, and we price it in.

---

## Why *you're* safer here (in one paragraph)

Every other lending app is "trust the audit." Assay is "trust the proof." The single rule that can
bankrupt a lending protocol — letting someone borrow more than their collateral covers — is
**designed to be enforced by a formally-verified kernel** on Assay (see the status table in the README for what is live today), verified on-chain, priced conservatively, and it
fails safe (refuses) when anything looks wrong. You're not trusting that we wrote perfect code;
you're trusting math that a computer checked.

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

The honest pitch: **Assay removes the single largest category of DeFi lending failure — a bug that
lets the protocol lend more than it should — by proving that path instead of hoping the audit
caught everything.** That's a real, specific, defensible safety advantage. It is not a claim that
nothing can ever go wrong.
