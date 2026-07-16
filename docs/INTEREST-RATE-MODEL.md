# Interest rate model — how to price USDC deposits

**The question:** what interest rate do we offer to get people to deposit USDC, so there's
liquidity sitting in the pool for borrowers to draw? And how is that rate decided?

**The short answer:** you don't pick a fixed rate. In lending protocols the rate is a **function
of how much of the pool is being borrowed** (utilization). The market sets the equilibrium; you
only choose the *shape* of the curve. This is the same model Aave and Compound use, and it's the
right one for Assay.

---

## 1. The mechanic: utilization drives the rate

Define **utilization** = how much of the supplied USDC is currently lent out:

```
U = totalBorrows / (idleCash + totalBorrows)
```

- **Borrowers** pay a *borrow APR* that **rises as U rises**.
- **Suppliers** earn a *supply APY* = `borrowAPR × U × (1 − reserveFactor)`.
  (Suppliers only earn on the portion actually borrowed — that's the `× U` — minus the protocol's cut.)

Why tie it to utilization? It's self-balancing:
- **Low U** (lots of idle USDC) → low rates → cheap to borrow → attracts borrowing, and suppliers
  earn little so they don't over-supply.
- **High U** (pool nearly drained) → high rates → expensive to borrow (borrowers repay) and
  lucrative to supply (new deposits arrive). This automatically pulls the pool back to a healthy level
  and **always keeps a buffer so suppliers can withdraw.**

## 2. The "kinked" curve (the standard shape)

Rates are flat-ish until a **target utilization** (the *kink*, `U*` ≈ 80–90%), then steep above it:

```
if U ≤ U*:   borrowAPR = base + slope1 · (U / U*)
if U > U*:   borrowAPR = base + slope1 + slope2 · ((U − U*) / (1 − U*))
```

- **base** — rate at zero utilization (often 0–1%).
- **slope1** — gentle rise up to the kink (this is the "normal operating" zone).
- **U\*** — the kink; the utilization you *want* the pool to sit near. Above it you're eating into the
  withdrawal buffer, so…
- **slope2** — a **steep** climb above the kink (e.g. +100–300% by U=100%) that makes running the pool
  dry very expensive and yanks it back.
- **reserveFactor** — the protocol's cut of borrow interest (e.g. 10–20%), funds treasury/insurance.

## 3. How to actually pick the numbers (worked example)

Start from the answer you want and work backwards. Suppliers won't deposit USDC unless the yield
beats their alternatives — roughly **~4–5% (T-bills / just holding USDC)** on the low end, and
**~5–10%** in competing DeFi lending. So to attract liquidity, target a supply APY that's clearly
competitive at the utilization you expect to run.

Say you want **~10% supply APY at the 80% kink**, with a 10% reserve factor:

```
supplyAPY = borrowAPR · U · (1 − reserveFactor)
0.10      = borrowAPR · 0.80 · 0.90
borrowAPR ≈ 13.9%   at the kink
```

So you'd set: **base ≈ 0%, slope1 ≈ 14%** (reaches ~14% borrow APR at U*=80%), **slope2 ≈ 150–300%**
(punishes >80%), **U\* = 80%**, **reserveFactor = 10%**. Borrowers pay ~14% at target; suppliers
earn ~10%; the protocol keeps ~1.5%.

Tune per environment:
- **Bluechip/stable demand** (BTC/ETH collateral) → flatter curve, lower rates.
- **Volatile/uncertain demand** → higher slope2 so scarcity self-corrects fast.
- Higher target APY if you need to attract liquidity faster; lower once liquidity is deep.

## 4. The real problem: bootstrapping (chicken-and-egg)

The IRM sets the *equilibrium*, but early on there's a cold-start problem: **no borrowers → low
utilization → low supply APY → no reason to supply.** The dynamic rate alone won't bootstrap you.
The standard fixes:

1. **Seed the pool yourself** (protocol-owned liquidity). You/treasury supply the initial USDC so
   borrowers have something to draw from day one. (This is literally what `dev-up-sui.sh` does now —
   it seeds the pool.)
2. **Liquidity incentives** — emit a token / points to supplement organic supply APY early
   ("supply USDC, earn 10% interest **+** X in rewards"). This is how essentially every new lending
   protocol got its first liquidity. Sunset it as organic utilization grows.
3. **Promotional fixed APY** early, then transition to the dynamic curve once there's real demand.
4. **Reserve factor → insurance fund** — a slice of interest builds a backstop that makes suppliers
   more comfortable, which lets you attract them at a lower headline rate.

The honest sequencing: **seed + incentivize to get initial liquidity and borrowers → real
utilization builds → the dynamic curve takes over and you dial incentives down.**

## 5. What Assay needs to implement (current state → target)

**Today:** the pool stores a single fixed `rate_bps` (set to 0 in the demo, so there's no interest —
that's why the demo shows ~0% APY). The accrual math (`accrue`) already compounds a rate over time;
it just uses a constant.

**Target:** make the rate a **function of utilization** instead of a constant. Concretely, in the
Move contract:
- Store the curve params in the pool: `base_bps, slope1_bps, slope2_bps, kink_bps, reserve_bps`.
- In `accrue`, compute `U` from `liquidity` vs `total_borrows`, evaluate the kinked borrow APR, and
  compound *that* over the elapsed time (instead of the fixed `rate_bps`).
- Route `reserve_bps` of the interest to a protocol reserve balance.
- Supply APY is then **emergent** — the UI already derives it as `rate × utilization` (see
  `usePool` / the Earn panel), so it will display correctly once the rate is dynamic.

That's a contained contract change (no new external dependencies, no oracle changes). It converts
the pool from "fixed demo rate" to a real, self-balancing money market — and it's the piece that
makes "deposit USDC and earn yield" actually mean something.

---

### TL;DR
- Don't set a rate — set a **curve**; utilization sets the rate automatically and keeps the pool liquid.
- Target a **supply APY that beats ~5–10% alternatives** at your expected utilization; work backwards
  to the borrow curve (example: ~14% borrow at 80% util → ~10% supply).
- The rate model doesn't solve cold-start — **seed the pool + incentivize early supply**, then let the
  curve take over.
- Implementation is a **contained contract change**: make `accrue` compute the rate from utilization
  (kinked curve) instead of a constant, add a reserve factor. The UI already shows the emergent APY.
