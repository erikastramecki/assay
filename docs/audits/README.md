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
| [Solidity 2](solidity-round-1.md) | `rh-chain/` — re-audit + mutation sweep | see round-1 report | **not clean**; ~50 mutations survive a green suite |

Round 2 has no separate file: its findings are corrections to round 1 and are folded into that
report. It is listed separately here because the round-1 document, read alone, states a
mutation-coverage claim that round 2 disproved by a factor of 50 — including that
`MIN_RISK_GAP_BPS` and `PARAM_TIMELOCK`, the two constants we cite publicly as controls, can both
be halved with every test passing. Anyone auditing us should know that before trusting round 1's
coverage section.

## Method

Each round runs three auditors over different surfaces, then two verifiers per finding — one
instructed to **refute**, one to **reproduce**. Verifiers write and run real PoCs (Move tests,
Foundry tests, on-chain `eth_call`) rather than reasoning. Roughly a third of initial findings do
not survive.

Alongside every round we mutation-test guards: delete the guard, and a test must fail. We have
twice claimed "all guards mutation-verified" and been wrong both times — first by only mutating
guards we had already written tests for (circular), then by using a sweep script that matched
`if (...) revert` and was structurally blind to early-return guards, reporting 1 survivor where an
independent sweep of 139 mutations found 50. A passing suite is necessary and nowhere near
sufficient, and our own coverage claims are the thing to check hardest.
