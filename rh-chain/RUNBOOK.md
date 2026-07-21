# Runbook — testnet to first loan

Three steps. Each needs your wallet; none needs real money.

## 0. Prove it first (no wallet, no gas)

```bash
cd rh-chain
forge test                                                        # 85 unit tests
forge test --match-path test/ForkMvp.t.sol \
  --fork-url https://rpc.mainnet.chain.robinhood.com -vv           # the MVP path on real state
```

The fork test deploys the stack against live mainnet, funds a pool with real USDG, borrows against
a real AAPL Stock Token priced by the real Chainlink feed, and repays. If that passes, the only
things testnet adds are your key and real block times.

## 1. Deploy

```bash
export PK=0x…                       # a testnet key
cd rh-chain
forge script script/Deploy.s.sol --rpc-url rh_testnet --broadcast --private-key $PK
```

Set `USDG`, `STOCK`, `FEED` in env if the testnet addresses differ from mainnet's. Every decimal is
read from the chain and asserted, so a wrong address fails loudly rather than deploying a market
that misprices by 1e12.

Record the three printed addresses.

## 2. Start the clock and the keeper

The market is **proposed, not live** — there is a 2-day timelock. Start it now; it runs while you
do everything else.

```bash
cd rh-chain/keeper && npm install
LIVENESS_ORACLE=<liveness> KEEPER_PRIVKEY=$PK \
  RH_RPC=https://rpc.testnet.chain.robinhood.com/rpc node liveness-keeper.mjs
```

Liquidations stay disabled until the keeper has been beating for the grace period. That is
deliberate: a fresh deployment has not proven liveness.

After 2 days:

```bash
cast send <markets> "commitMarket(address)" <stock> --rpc-url rh_testnet --private-key $PK
```

## 3. Borrow, from an agent

```bash
cd mcp && npm install
ASSAY_CHAIN=rh-testnet ASSAY_POOL=<pool> ASSAY_MARKETS=<markets> node assay-mcp.mjs
```

Register it with your MCP client alongside Robinhood's Trading MCP. Then, in one conversation:

1. *"Buy 10 shares of AAPL"* → Robinhood Trading MCP, under your own credentials
2. wait for settlement → the Stock Token lands in your self-custody wallet
3. *"What can I borrow against my AAPL?"* → `assay_quote`
4. *"Borrow $500"* → `assay_borrow` returns unsigned calldata; your wallet signs
5. *"How's my loan?"* → `assay_health`
6. *"Repay it"* → `assay_repay`

Step 4 is the moment the MVP exists.

## Known limits at this stage

Testnet, one lender, one borrower. `docs/OUTSTANDING.md` lists every open finding — none blocks a
single-user demo, and all of them start mattering the moment real users arrive.
