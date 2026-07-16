# Assay — provably-safe RWA lending on Sui

A Sui-native lending protocol: borrow USDC against 68 markets of collateral (crypto + tokenized
stocks/xStocks), where the core solvency rule is enforced by a **formally-verified risk kernel**
(dregg) and settlement is gated by an **on-chain zk proof** (`sui::groth16`). Non-custodial: the
borrower sends the tx and supplies collateral; the operator's authorization is an ed25519
attestation verified in-Move.

**Live demo (devnet):** https://assay-sui.vercel.app  ·  Operator API: https://assay-operator-sui.vercel.app

> Devnet + test assets only. Not an offer of securities. See `docs/` for the full design, risk
> framework, interest-rate model, and security audit.

## Repo layout
```
move/
  dregg_lending_async/   the lending program (dynamic rates, isolation caps, attested disburse)
  dregg_verifier/        vendored BN254 Groth16 verifier (generic; from the dregg project)
app/
  sui-sdk/               @assay/sui-sdk — PTB builders, object readers, attestation, math
    scripts/             setup, governance (set-curve), keeper, liquidation-keeper
    test/                on-chain loops, pentest, five-loans evidence
  operator-api/          the operator: /quote (Pyth) + /borrow (attestation) + /faucet
    assay-operator/      esbuild-bundled Vercel serverless deploy
  web/                   the site (Vite + React + @mysten/dapp-kit)
  sui-harness/           dev-up-sui.sh (local stack), markets.json (source of truth), add-market.sh
  deploy.sh              one-command deploy (web/operator) with preflight + smoke check
docs/                    architecture, LTV framework, interest-rate model, audit, evidence, why-different
operator/pyth.mjs        Pyth Hermes oracle policy (conservative pricing, market-hours discipline)
```

## Run it locally
```bash
bash app/sui-harness/dev-up-sui.sh      # deploy + seed a pool + start the operator + write web/.env.local
cd app/web && npm run dev               # http://localhost:5173
```

## Deploy
```bash
bash app/deploy.sh            # web + operator (preflight tsc, build, deploy, pin alias, smoke check)
bash app/deploy.sh --web      # web only
```

## Add markets
```bash
bash app/sui-harness/add-market.sh spec.json   # publishes a small new coin pkg, appends to markets.json
bash app/sui-harness/deploy-markets.sh         # push registry/faucet + redeploy
```

## Dependencies & separation
- **Self-contained on Sui:** the contract vendors `dregg_verifier` locally; no reach into sibling repos.
- **Optional dregg kernel:** the operator's `/borrow` uses the formally-verified dregg kernel when a
  Rust `dregg` workspace is present (`DREGG` env), and an honest in-operator LTV+oracle fallback
  otherwise (flagged `authMode`). The on-chain guards are real either way. The hosted deploy runs the
  fallback (no Rust on serverless).
- **Secrets** (`.operator-sui.key`, `.env.*`) are git-ignored — never commit them.
- Contains **no CoinVoyage code**. The `dregg_verifier` copy is generic verifier code from the dregg
  project (same owner).

## Known backlog (see `docs/`)
Mainnet posture (real assets + regulatory read + independent audit), first-depositor share inflation
(MED, mitigated by seed), attestation single-use (LOW), hosted dregg-kernel host, BTC-collateral flow
(scoped, paused).
