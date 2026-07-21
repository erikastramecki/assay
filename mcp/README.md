# Assay MCP server

The half of the product that makes the pitch work. A user connects Robinhood's Trading MCP to buy
a stock and this one to borrow against it — in a single conversation.

```
Robinhood Trading MCP  ->  agent buys AAPL under the user's own credentials
Robinhood settlement   ->  Stock Token lands in the user's self-custody wallet
Assay MCP (this)       ->  agent quotes and opens a loan against it
```

Assay never holds the brokerage account and never custodies collateral before the loan. Tools that
move funds return **unsigned calldata** for the user's wallet to sign; this server never takes a
private key.

```bash
npm install
ASSAY_CHAIN=rh-testnet ASSAY_POOL=0x… ASSAY_MARKETS=0x… node assay-mcp.mjs
```

| Tool | Does |
|---|---|
| `assay_quote` | Collateral value, max borrow, whether borrowing is possible now, and the risks |
| `assay_borrow` | Unsigned approve + borrow calldata |
| `assay_health` | Debt, collateral value, health factor, liquidation status |
| `assay_repay` | Unsigned approve + repay calldata |

**`assay_quote` always returns the risks** — Jersey debt token, `adminBurn`, the 24/5 price feed,
and why to borrow well under the limit. A borrower who is not told cannot price them.

**Multi-chain by design.** `chain` is a parameter, not a constant: Robinhood Chain is implemented,
and the Sui deployment plugs in as another adapter. Adding a chain means adding an adapter, not
forking the server.
