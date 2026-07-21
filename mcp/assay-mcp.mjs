#!/usr/bin/env node
// Assay MCP server — lets an AI agent quote, borrow, check health and repay.
//
// This is the half of the product that makes the pitch work: a user connects Robinhood's Trading
// MCP to buy a stock, and connects this one to borrow against it, in a single conversation.
//
//   Robinhood Trading MCP   ->  agent buys AAPL under the user's own credentials
//   Robinhood settlement    ->  Stock Token lands in the user's self-custody wallet
//   Assay MCP (this)        ->  agent quotes and opens a loan against it
//
// Assay never holds the brokerage account and never custodies the collateral before the loan —
// the user's wallet signs. Deliberately: custody would forfeit the non-custodial property and
// bring licensing exposure that the transfer-based design avoids entirely.
//
// MULTI-CHAIN BY DESIGN. `chain` is a parameter, not a constant. Robinhood Chain is implemented
// today; Sui is wired to the existing Move deployment. Adding a chain means adding an adapter,
// not forking this server.
//
//   ASSAY_CHAIN=rh-testnet ASSAY_POOL=0x... ASSAY_MARKETS=0x... node mcp/assay-mcp.mjs
//
// Read-only tools work with no key. Anything that moves funds returns UNSIGNED CALLDATA for the
// user's wallet to sign — this server never takes a private key.

import { createPublicClient, http, defineChain, encodeFunctionData, formatUnits, parseUnits } from "viem";

// ---------------------------------------------------------------- chains

const CHAINS = {
  "rh-mainnet": {
    id: 4663,
    label: "Robinhood Chain",
    rpc: "https://rpc.mainnet.chain.robinhood.com",
    explorer: "https://robinhoodchain.blockscout.com",
    asset: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", // USDG
    assetSymbol: "USDG",
  },
  "local-fork": {
    id: 4663,
    label: "Robinhood Chain (local fork)",
    rpc: "http://127.0.0.1:8545",
    explorer: "https://robinhoodchain.blockscout.com",
    asset: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
    assetSymbol: "USDG",
  },
  "rh-testnet": {
    id: 46630,
    label: "Robinhood Chain testnet",
    rpc: "https://rpc.testnet.chain.robinhood.com/rpc",
    explorer: "https://robinhoodchain.blockscout.com",
    asset: process.env.ASSAY_ASSET || "",
    assetSymbol: "USDG",
  },
};

const CHAIN_KEY = process.env.ASSAY_CHAIN || "rh-testnet";
const CFG = CHAINS[CHAIN_KEY];
if (!CFG) throw new Error(`unknown ASSAY_CHAIN "${CHAIN_KEY}" (have: ${Object.keys(CHAINS).join(", ")})`);

const POOL = process.env.ASSAY_POOL;
const MARKETS = process.env.ASSAY_MARKETS;

const chain = defineChain({
  id: CFG.id,
  name: CFG.label,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [CFG.rpc] } },
});
const pub = createPublicClient({ chain, transport: http(CFG.rpc) });

// ---------------------------------------------------------------- abis

const MARKETS_ABI = [
  { type: "function", name: "collateralValue", stateMutability: "view",
    inputs: [{ type: "address" }, { type: "uint256" }],
    outputs: [{ type: "uint256" }, { type: "bool" }] },
  { type: "function", name: "maxBorrow", stateMutability: "view",
    inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "canBorrow", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "canLiquidate", stateMutability: "view",
    inputs: [{ type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "isUnderwater", stateMutability: "view",
    inputs: [{ type: "address" }, { type: "uint256" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "market", stateMutability: "view", inputs: [{ type: "address" }],
    outputs: [{ type: "tuple", components: [
      { name: "enabled", type: "bool" }, { name: "ltvBps", type: "uint16" },
      { name: "liqThresholdBps", type: "uint16" }, { name: "liqBonusBps", type: "uint16" },
      { name: "collateralDecimals", type: "uint8" }, { name: "cap", type: "uint128" }] }] },
  { type: "function", name: "assetDecimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
];

const POOL_ABI = [
  { type: "function", name: "borrow", stateMutability: "nonpayable",
    inputs: [{ type: "address" }, { type: "uint256" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "repay", stateMutability: "nonpayable",
    inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [] },
  { type: "function", name: "debtOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "positions", stateMutability: "view", inputs: [{ type: "uint256" }],
    outputs: [{ type: "address" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }] },
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];

const ERC20_ABI = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable",
    inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
];

const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });

// ---------------------------------------------------------------- tools

/// Everything a borrower should know BEFORE borrowing, including the parts that are easy to omit.
async function quote({ stockToken, amount, wallet }) {
  const [mkt, assetDec] = await Promise.all([
    read(MARKETS, MARKETS_ABI, "market", [stockToken]),
    read(MARKETS, MARKETS_ABI, "assetDecimals"),
  ]);
  if (!mkt.enabled) return { ok: false, reason: `${stockToken} is not an enabled market` };

  const raw = amount !== undefined
    ? parseUnits(String(amount), mkt.collateralDecimals)
    : await read(stockToken, ERC20_ABI, "balanceOf", [wallet]);
  if (raw === 0n) return { ok: false, reason: "wallet holds none of this Stock Token" };

  const [symbol, canBorrow] = await Promise.all([
    read(stockToken, ERC20_ABI, "symbol"),
    read(MARKETS, MARKETS_ABI, "canBorrow", [stockToken]),
  ]);

  // collateralValue reverts when the price is unusable — a stale/silent oracle or a shut market.
  // Surface that as a REASON rather than an error: "we cannot price this right now" is the
  // honest answer and the borrower can act on it.
  let value, inSession;
  try {
    [value, inSession] = await read(MARKETS, MARKETS_ABI, "collateralValue", [stockToken, raw]);
  } catch (e) {
    return { ok: false, reason: "no usable price right now (stale feed, or the market is closed)", canBorrow: false };
  }
  const max = await read(MARKETS, MARKETS_ABI, "maxBorrow", [stockToken, raw]);

  return {
    ok: true,
    chain: CFG.label,
    collateral: { symbol, amount: formatUnits(raw, mkt.collateralDecimals), raw: raw.toString() },
    collateralValue: `${formatUnits(value, assetDec)} ${CFG.assetSymbol}`,
    maxBorrow: `${formatUnits(max, assetDec)} ${CFG.assetSymbol}`,
    ltv: `${mkt.ltvBps / 100}%`,
    liquidationThreshold: `${mkt.liqThresholdBps / 100}%`,
    marketOpen: inSession,
    canBorrowNow: canBorrow,
    // Stated every time. These are properties of the collateral, not bugs to be fixed, and a
    // borrower who is not told about them cannot price them.
    risks: [
      "Stock Tokens are tokenised DEBT securities from Robinhood Assets (Jersey) Ltd — economic exposure only, no ownership of the underlying share.",
      "Robinhood can burn Stock Tokens from any address, including this pool. Collateral can be destroyed while your loan is open.",
      "The price feed follows US market hours (24/5). Overnight and at weekends there is no fresh price, borrowing is disabled, and a Monday gap cannot be liquidated into.",
      `Borrow well below the ${mkt.ltvBps / 100}% limit: the gap to the ${mkt.liqThresholdBps / 100}% liquidation threshold is what absorbs a weekend move.`,
    ],
    ...(canBorrow ? {} : { whyNot: inSession ? "market open but no fresh price" : "US equity market is closed" }),
  };
}

/// Returns UNSIGNED calldata. This server never holds a key and never signs.
async function borrowTx({ stockToken, collateralAmount, borrowAmount }) {
  const mkt = await read(MARKETS, MARKETS_ABI, "market", [stockToken]);
  const assetDec = await read(MARKETS, MARKETS_ABI, "assetDecimals");
  const raw = parseUnits(String(collateralAmount), mkt.collateralDecimals);
  const debt = parseUnits(String(borrowAmount), assetDec);

  const max = await read(MARKETS, MARKETS_ABI, "maxBorrow", [stockToken, raw]);
  if (debt > max) {
    return { ok: false, reason: `${borrowAmount} exceeds the maximum ${formatUnits(max, assetDec)} for that collateral` };
  }
  return {
    ok: true,
    note: "Two transactions, in order. Sign them with your own wallet — Assay never holds your key.",
    transactions: [
      { step: 1, description: `Approve the pool to take ${collateralAmount} ${await read(stockToken, ERC20_ABI, "symbol")}`,
        to: stockToken, data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [POOL, raw] }) },
      { step: 2, description: `Post collateral and borrow ${borrowAmount} ${CFG.assetSymbol}`,
        to: POOL, data: encodeFunctionData({ abi: POOL_ABI, functionName: "borrow", args: [stockToken, raw, debt] }) },
    ],
  };
}

async function health({ positionId }) {
  const id = BigInt(positionId);
  const [borrower, token, collateralRaw, principal] = await read(POOL, POOL_ABI, "positions", [id]);
  if (principal === 0n) return { ok: false, reason: `position ${positionId} is closed or does not exist` };
  const [debt, assetDec, mkt] = await Promise.all([
    read(POOL, POOL_ABI, "debtOf", [id]),
    read(MARKETS, MARKETS_ABI, "assetDecimals"),
    read(MARKETS, MARKETS_ABI, "market", [token]),
  ]);
  let value, underwater = null, priceKnown = true;
  try {
    [value] = await read(MARKETS, MARKETS_ABI, "collateralValue", [token, collateralRaw]);
    underwater = await read(MARKETS, MARKETS_ABI, "isUnderwater", [token, collateralRaw, debt]);
  } catch { priceKnown = false; }

  return {
    ok: true, positionId, borrower,
    debt: `${formatUnits(debt, assetDec)} ${CFG.assetSymbol}`,
    collateral: formatUnits(collateralRaw, mkt.collateralDecimals),
    ...(priceKnown
      ? { collateralValue: `${formatUnits(value, assetDec)} ${CFG.assetSymbol}`,
          healthFactor: Number((value * BigInt(mkt.liqThresholdBps)) / 10_000n) / Number(debt),
          underwater }
      : { note: "no fresh price right now — health cannot be evaluated, and liquidation is also disabled" }),
  };
}

async function repayTx({ positionId }) {
  const id = BigInt(positionId);
  const [debt, assetDec] = await Promise.all([
    read(POOL, POOL_ABI, "debtOf", [id]),
    read(MARKETS, MARKETS_ABI, "assetDecimals"),
  ]);
  if (debt === 0n) return { ok: false, reason: "nothing owed" };
  // Pad by 1% and let the contract refund the difference: debt grows every second, so quoting an
  // exact figure makes repayment a race against the clock that the borrower can lose.
  const pad = (debt * 101n) / 100n;
  return {
    ok: true,
    owed: `${formatUnits(debt, assetDec)} ${CFG.assetSymbol}`,
    note: "Approve slightly more than owed; the contract charges only the debt and returns the rest.",
    transactions: [
      { step: 1, description: `Approve ${formatUnits(pad, assetDec)} ${CFG.assetSymbol}`,
        to: CFG.asset, data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [POOL, pad] }) },
      { step: 2, description: "Repay and reclaim collateral",
        to: POOL, data: encodeFunctionData({ abi: POOL_ABI, functionName: "repay", args: [id, pad] }) },
    ],
  };
}

// ---------------------------------------------------------------- MCP wire protocol

const TOOLS = [
  { name: "assay_quote", description:
      "Quote a loan against a Robinhood Stock Token. Returns collateral value, max borrow, whether borrowing is currently possible, and the risks of this collateral. Call this before assay_borrow.",
    inputSchema: { type: "object", properties: {
      stockToken: { type: "string", description: "Stock Token contract address" },
      wallet: { type: "string", description: "Wallet address, to price its whole balance" },
      amount: { type: "number", description: "Optional: quote this many shares instead of the balance" },
    }, required: ["stockToken"] } },
  { name: "assay_borrow", description:
      "Build the unsigned transactions to post collateral and borrow. Returns calldata for the user's wallet to sign; Assay never holds a key.",
    inputSchema: { type: "object", properties: {
      stockToken: { type: "string" }, collateralAmount: { type: "number" }, borrowAmount: { type: "number" },
    }, required: ["stockToken", "collateralAmount", "borrowAmount"] } },
  { name: "assay_health", description:
      "Current debt, collateral value, health factor and liquidation status for a position.",
    inputSchema: { type: "object", properties: { positionId: { type: "number" } }, required: ["positionId"] } },
  { name: "assay_repay", description:
      "Build the unsigned transactions to repay a position and reclaim collateral.",
    inputSchema: { type: "object", properties: { positionId: { type: "number" } }, required: ["positionId"] } },
];

const HANDLERS = { assay_quote: quote, assay_borrow: borrowTx, assay_health: health, assay_repay: repayTx };

function send(msg) { process.stdout.write(JSON.stringify(msg) + "\n"); }

let buf = "";
process.stdin.on("data", async (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let req;
    try { req = JSON.parse(line); } catch { continue; }
    try {
      if (req.method === "initialize") {
        send({ jsonrpc: "2.0", id: req.id, result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "assay", version: "0.1.0" },
        } });
      } else if (req.method === "tools/list") {
        send({ jsonrpc: "2.0", id: req.id, result: { tools: TOOLS } });
      } else if (req.method === "tools/call") {
        const fn = HANDLERS[req.params.name];
        if (!fn) throw new Error(`unknown tool ${req.params.name}`);
        if (!POOL || !MARKETS) throw new Error("ASSAY_POOL and ASSAY_MARKETS must be set");
        const out = await fn(req.params.arguments || {});
        send({ jsonrpc: "2.0", id: req.id, result: { content: [{ type: "text", text: JSON.stringify(out, null, 2) }] } });
      } else if (req.id !== undefined) {
        send({ jsonrpc: "2.0", id: req.id, error: { code: -32601, message: `unknown method ${req.method}` } });
      }
    } catch (e) {
      send({ jsonrpc: "2.0", id: req.id, error: { code: -32603, message: e.message } });
    }
  }
});

process.stderr.write(`assay-mcp on ${CFG.label} (${CFG.id})  pool=${POOL || "unset"}  markets=${MARKETS || "unset"}\n`);
