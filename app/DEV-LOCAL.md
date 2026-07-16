# Run Assay locally + click-test it

The devnet faucet is throttled, so here's a **fully local, clickable** stack — everything
real (program, pool, USDC, wallet-signed txs), just on a local validator instead of devnet.

## One-time
- Solana CLI + `cargo-build-sbf` installed; Node installed.
- `cd app/web && npm i` and `cd app/sdk && npm i` (once).
- Phantom (or Solflare) browser extension.

## Bring the stack up
```
bash app/dev-up.sh
```
This starts a local validator, deploys the program, creates a test-USDC mint, inits the pool,
**seeds it with 5,000 USDC**, and writes `app/web/.env.local`. Leave it running (it prints the
PID + how to stop). It reprints the exact next commands too.

## Point your wallet at the local validator
In Phantom: Settings → Developer Settings → **Change Network → Add Custom RPC** →
`http://127.0.0.1:8899`. (Phantom needs a custom network for localhost.)

## Fund your wallet (SOL + test USDC)
Copy your Phantom address, then:
```
cd app/sdk && node --import tsx scripts/faucet.mjs <YOUR_PHANTOM_ADDRESS>
```
→ +2 SOL (fees) and +10,000 test USDC.

## Run the app
```
cd app/web && npm run dev        # http://localhost:5173
```
Connect Phantom, then click through the **whole loop**:
- **Supply** USDC (Earn panel) — a wallet-signed `deposit`; watch APY/liquidity/your-position.
- **Borrow** (money moment) — set collateral + LTV, **Review & borrow**: the Operator API
  dregg-authorizes + co-signs, your wallet co-signs, USDC lands. (Demo collateral is priced
  live via the BTC feed, so it works even when equity markets are closed.)
- **Your positions** — see the open loan; **Repay** to reclaim collateral.
- **Withdraw** your supplied USDC.

## Notes
- Everything is real on-chain — the same instructions proven in `test-all.sh`, the SDK
  on-chain tests, and the borrow integration test. Only the cluster is local.
- `dev-up.sh` also starts the **Operator API** (:8787) and pre-builds the dregg authorizer.
- Stop everything: the `kill <PID>` the script printed, plus `pkill -f server.mjs`.
- Re-running `dev-up.sh` resets the validator and rewrites `.env.local` with the fresh ids.
- Stop everything with the `kill <PID>` the script printed.
- **To move to devnet later:** deploy there (needs ~3 devnet SOL), then set
  `VITE_RPC`/`VITE_PROGRAM_ID`/`VITE_USDC_MINT` in `.env.local` — no code changes.
