// FIVE FULL LOANS — end-to-end evidence on the v8 stack. Each: mint collateral → /quote → /borrow
// (HOSTED operator ed25519 attestation, type-bound) → on-chain disburse_attested → verify position →
// repay → verify closed. Across BTC/ETH/SOL/HYPE (main pkg) + LINK (ext pkg): multi-market,
// multi-package, 9-decimal (SOL), and the type-binding fix. Uses a fresh rate=0 pool pinned to the
// hosted operator key so repay is exact/deterministic. Env: SUI_PRIVKEY LENDING
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { fromHex } from "@mysten/sui/utils";
import { readFileSync } from "node:fs";
import os from "node:os";
import { ptb, exactCoin, findPositions } from "../src/index.ts";

const API = "https://assay-operator-sui.vercel.app";
const LENDING = process.env.LENDING;
const HOME = os.homedir();
const COINS = "0x537ba694cf26744a208ac69001a2102f12258e2999834ed8ea0b0cc941667d1f";
const TUSDC = `${COINS}::tusdc::TUSDC`, CAP_USDC = "0x6ac4c50740c98fc78057c62efb00bc96ca7e0201f7c854f5d86bb906cafe6446";
const VK = Uint8Array.from(readFileSync(new URL("../../../perloan-prep/proof_A_sui_hex.txt", import.meta.url), "utf8").split("\n").find((l) => l.startsWith("VK_HEX=")).slice(7).match(/../g).map((h) => parseInt(h, 16)));
const markets = JSON.parse(readFileSync(new URL("../../../app/sui-harness/markets.json", import.meta.url), "utf8"));
const mkt = (sym) => markets.markets.find((m) => m.sym === sym);

const kp = Ed25519Keypair.fromSecretKey(process.env.SUI_PRIVKEY.trim());
const me = kp.toSuiAddress();
const capOwner = Ed25519Keypair.fromSecretKey(readFileSync(new URL("../../../app/operator-api/.operator-sui.key", import.meta.url), "utf8").trim());
const client = new SuiClient({ url: getFullnodeUrl("devnet") });
const post = async (p, b) => { const r = await fetch(API + p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(b) }); const j = await r.json(); if (!r.ok) throw new Error(p + " " + JSON.stringify(j)); return j; };
async function exec(tx, signer = kp) { tx.setSender(signer.toSuiAddress()); const r = await client.signAndExecuteTransaction({ signer, transaction: tx, options: { showEffects: true, showObjectChanges: true } }); await client.waitForTransaction({ digest: r.digest }); if (r.effects?.status?.status !== "success") throw new Error(JSON.stringify(r.effects?.status)); return r; }
const created = (r, needle) => r.objectChanges.find((c) => c.type === "created" && c.objectType.includes(needle))?.objectId;

// markets to exercise (all crypto → 24/7, so they price regardless of US market hours)
const PLAN = [
  { sym: "BTC", lock: 1 }, { sym: "ETH", lock: 1 }, { sym: "SOL", lock: 10 }, { sym: "HYPE", lock: 50 }, { sym: "LINK", lock: 100 },
];

// ---- setup: seed a fresh rate=0 pool pinned to the hosted operator key ----
const health = await (await fetch(API + "/health")).json();
{ const tx = new Transaction(); tx.moveCall({ target: `${COINS}::tusdc::mint`, arguments: [tx.object(CAP_USDC), tx.pure.u64(4_000_000_000n), tx.pure.address(me)] }); await exec(tx, capOwner); }
let POOL;
{ const tx = new Transaction();
  ptb.initPool(tx, { pkg: LENDING, stableType: TUSDC, curve: { baseBps: 0, slope1Bps: 0, slope2Bps: 0, kinkBps: 8000, reserveBps: 0 }, cap: 1_000_000_000_000n, perCollateralCap: 0n, vk: VK, operatorPubkey: fromHex(health.operatorPubkey) });
  const r = await exec(tx); POOL = created(r, "async_lending::Pool"); }
{ const tx = new Transaction(); const c = await exactCoin(tx, client, me, TUSDC, 4_000_000_000n); ptb.deposit(tx, { pkg: LENDING, stableType: TUSDC, pool: POOL, coin: c }); await exec(tx); }
console.log(`pool ${POOL} (seeded 4000 TUSDC)\n`);

const loans = [];
for (let i = 0; i < PLAN.length; i++) {
  const m = mkt(PLAN[i].sym), dec = m.decimals, type = m.coinType || `${markets.marketsPkg}::${m.module}::${m.struct}`;
  const collBase = BigInt(Math.round(PLAN[i].lock * 10 ** dec));
  // mint the collateral to me (operator owns the market caps)
  { const tx = new Transaction(); tx.moveCall({ target: m.mintTarget, arguments: [tx.object(m.cap), tx.pure.u64(collBase), tx.pure.address(me)] }); await exec(tx, capOwner); }
  const q = await post("/quote", { collateralMint: type, collateralWhole: PLAN[i].lock });
  const debtUsdc = Math.min(500, Math.floor(q.maxBorrowUsdc * 0.4 * 100) / 100);
  const b = await post("/borrow", { borrower: me, collateralMint: type, collateralAmount: Number(collBase), debtUsdc });
  // borrow: on-chain disburse_attested with the hosted (type-bound) attestation
  let borrowTx, posId;
  { const tx = new Transaction(); const coll = await exactCoin(tx, client, me, type, BigInt(b.collateralBase));
    ptb.disburseAttested(tx, { pkg: LENDING, collType: type, stableType: TUSDC, pool: POOL, collateralCoin: coll, debt: BigInt(b.debtBase), loanCommit: BigInt(b.loanCommit), expiryS: BigInt(b.expiryS), attestation: fromHex(b.attestation) });
    const r = await exec(tx); borrowTx = r.digest; posId = created(r, "async_lending::Position"); }
  // repay: rate=0 → owed == principal == debtBase, exact + deterministic
  let repayTx;
  { const tx = new Transaction(); const pay = await exactCoin(tx, client, me, TUSDC, BigInt(b.debtBase));
    ptb.repay(tx, { pkg: LENDING, collType: type, stableType: TUSDC, pool: POOL, position: posId, paymentCoin: pay, recipient: me });
    const r = await exec(tx); repayTx = r.digest; }
  const closed = !(await client.getObject({ id: posId })).data;
  loans.push({ i: i + 1, sym: PLAN[i].sym, pkg: type.startsWith(markets.marketsPkg) ? "main" : "ext", price: q.priceCents / 100, debtUsdc, borrowTx, repayTx, closed });
  console.log(`Loan #${i + 1} ${PLAN[i].sym} (${loans[i].pkg} pkg) @ $${loans[i].price} — borrowed $${debtUsdc}  borrow ${borrowTx.slice(0, 8)}…  repay ${repayTx.slice(0, 8)}…  closed:${closed}`);
}

console.log("\n================ FIVE FULL LOANS — v8 EVIDENCE ================");
for (const L of loans) console.log(`#${L.i} ${L.sym.padEnd(5)} $${String(L.debtUsdc).padStart(6)}  borrow ${L.borrowTx}  repay ${L.repayTx}  ${L.closed ? "closed ✓" : "OPEN ✗"}`);
const ok = loans.every((L) => L.closed) && loans.length === 5;
console.log(ok ? "\n✅ 5/5 LOANS COMPLETED END-TO-END (borrow via hosted type-bound attestation → repaid → position closed)" : "\n❌ a loan did not complete");
process.exit(ok ? 0 : 1);
