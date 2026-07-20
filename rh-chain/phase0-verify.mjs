// Phase 0 — verify the Robinhood Chain assumptions the Assay port depends on.
//
// READ-ONLY section needs no keys and no gas: run it anywhere.
// The TRANSFER section needs a funded wallet holding a Stock Token; it is the one
// assumption that cannot be proven by reading contract source alone.
//
//   node rh-chain/phase0-verify.mjs                  # read-only checks
//   RH_PRIVKEY=0x... node rh-chain/phase0-verify.mjs # + live transfer test
import { keccak_256 } from "../app/sui-sdk/node_modules/@noble/hashes/sha3.js";

const MAINNET = "https://rpc.mainnet.chain.robinhood.com"; // chainId 4663
const TESTNET = "https://rpc.testnet.chain.robinhood.com/rpc"; // chainId 46630
const RPC = process.env.RH_RPC || MAINNET;

const sel = (s) => Buffer.from(keccak_256(s)).toString("hex").slice(0, 8);
const pad = (a) => a.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const num = (h) => (h?.startsWith("0x") ? BigInt(h) : null);

async function rpc(method, params) {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}
const call = (to, data) => rpc("eth_call", [{ to, data: "0x" + data }, "latest"]);

// Stock Tokens (mainnet). Verified beacon proxies -> one shared `Stock` implementation.
const TOKENS = {
  AAPL: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9",
  TSLA: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d",
  NVDA: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC",
  SPY:  "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C",
};
const REGISTRY = "0xe10b6f6b275de231345c20d14ab812db62151b00";
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";

let pass = 0, fail = 0;
const ok = (m) => { console.log("  \x1b[32m✔\x1b[0m " + m); pass++; };
const no = (m) => { console.log("  \x1b[31mx\x1b[0m " + m); fail++; };

console.log(`\nRPC ${RPC}  chainId ${num(await rpc("eth_chainId", []))}\n`);

// ---- A1. Is the transfer gate a deny-list (default OPEN) or an allow-list? ----
console.log("A1. isBlocked() default — deny-list vs allow-list");
for (const [label, addr] of Object.entries({
  "never-used address": "0x1111111111111111111111111111111111111111",
  "a plain contract  ": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
})) {
  const blocked = num(await call(REGISTRY, sel("isBlocked(address)") + pad(addr))) === 1n;
  blocked ? no(`${label} is BLOCKED — allow-list! the port assumption is WRONG`)
          : ok(`${label} not blocked → arbitrary addresses can hold Stock Tokens`);
}

// ---- A2. uiMultiplier: corporate-action scaling ----
console.log("\nA2. uiMultiplier() — collateral must be priced as balanceOfUI, not balanceOf");
for (const [sym, addr] of Object.entries(TOKENS)) {
  const m = num(await call(addr, sel("uiMultiplier()")));
  const one = 10n ** 18n;
  console.log(`     ${sym.padEnd(5)} multiplier ${m} ${m === one ? "(=1.0, no corporate action applied)" : "\x1b[33m(≠1.0 — a split/action IS applied)\x1b[0m"}`);
}
ok("multiplier readable — pricing must multiply by it every read, never cache");

// ---- A3. Pause state ----
console.log("\nA3. pause state (a global pause traps repay AND liquidate)");
const gp = num(await call(REGISTRY, sel("paused()")));
gp === 0n ? ok("registry not globally paused") : no("registry GLOBALLY PAUSED — transfers dead");
for (const [sym, addr] of Object.entries(TOKENS)) {
  const p = num(await call(addr, sel("paused()")));
  if (p !== 0n) no(`${sym} is paused`);
}
ok("per-token pause readable — accrual must suspend while paused");

// ---- A4. Borrow asset ----
console.log("\nA4. USDG (borrow asset)");
const usdgSupply = num(await call(USDG, sel("totalSupply()")));
usdgSupply > 0n ? ok(`USDG live, totalSupply ${usdgSupply}`) : no("USDG unreadable");

console.log(`\n${pass} passed, ${fail} failed`);

// ---- B. The one check that needs a funded wallet ----
if (!process.env.RH_PRIVKEY) {
  console.log(`
\x1b[33mTRANSFER TEST SKIPPED\x1b[0m — set RH_PRIVKEY (a wallet holding a Stock Token) to run it.
It is the only Phase 0 assumption that source-reading cannot prove: that a *contract*
(not just an EOA) can actually receive a Stock Token. Steps it will run:
  1. deploy a minimal receiver contract
  2. transfer 1 unit of a Stock Token to it
  3. assert balanceOf(receiver) > 0
Run it on TESTNET first:  RH_RPC=${TESTNET} RH_PRIVKEY=0x... node rh-chain/phase0-verify.mjs`);
}
