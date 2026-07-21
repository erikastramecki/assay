# Security audits

Every substantive change to this protocol goes through an adversarial audit before it is
considered done: independent agents attack the code from different angles, and **every finding is
then independently verified by two skeptics whose job is to refute it**. Only findings that
survive refutation are reported. Refuted findings are recorded too — they show what was considered
and why it was dismissed, which is often more informative than the confirmed list.

## Publishing policy

These reports are public deliberately. The discipline is **fix-first**:

- A finding's full detail — exploit path, code, fix, closing commit — publishes **after** its fix
  is committed.
- **Open** findings appear as a placeholder: round, severity, affected surface, status. No exploit
  path.
- Clean rounds and refuted findings publish immediately; neither arms anyone.

The point is a trail an outsider can actually check, not a highlight reel. Severities are the
verifiers' calibrated ones, not the reporters' initial claims, and the reports name what was NOT
covered.

## Reports

| Round | Target | Confirmed | Status |
|---|---|---|---|
| [Sui 1–6](sui-rounds-1-6.md) | `move/` — the Move protocol | 9, 10, 17, 9, 9, 12 | fixes committed; **no round ever came back clean** |
| [Solidity 1](solidity-round-1.md) | `rh-chain/` — the Robinhood Chain port | 19 | criticals + highs fixed; tail open |

## Method

Each round runs three auditors over different surfaces, then two verifiers per finding — one
instructed to **refute**, one to **reproduce**. Verifiers write and run real PoCs (Move tests,
Foundry tests, on-chain `eth_call`) rather than reasoning. Roughly a third of initial findings do
not survive.

Alongside every round, **every guard is mutation-tested**: delete the guard, and a test must fail.
A passing suite is necessary and nowhere near sufficient — see the Solidity report for how badly
that assumption failed here.
