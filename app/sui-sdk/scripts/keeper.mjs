// RATE KEEPER — nudges the pool's interest curve (slope1) to steer utilization toward a target.
// Control logic: higher rates dampen borrowing + attract supply → utilization falls, and vice-versa.
// So U above target → RAISE rates; U below target → LOWER rates. Proportional step, bounded, deadband.
// Governance action (OperatorCap holder signs). Env: SUI_PRIVKEY LENDING POOL OPCAP STABLE
//   node --import tsx scripts/keeper.mjs [targetBps=8000] [--loop] [--interval=60]
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { ptb, readPool, utilizationBps, borrowRateBps, supplyApyPct } from "../src/index.ts";

const { LENDING, POOL, OPCAP, STABLE } = process.env;
const args = process.argv.slice(2);
const TARGET = Number(args.find((a) => /^\d+$/.test(a)) || 8000); // target utilization (bps)
const LOOP = args.includes("--loop");
const INTERVAL = Number((args.find((a) => a.startsWith("--interval=")) || "=60").split("=")[1]) * 1000;
const STEP = 200n, BAND = 500n, MIN = 200n, MAX = 8000n; // slope1 step / deadband / bounds (bps)

const kp = Ed25519Keypair.fromSecretKey(process.env.SUI_PRIVKEY.trim());
const client = new SuiClient({ url: getFullnodeUrl("devnet") });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function tick() {
  const p = await readPool(client, POOL);
  const u = utilizationBps(p);
  const s1 = BigInt(p.slope1Bps);
  let next = s1;
  if (u > BigInt(TARGET) + BAND) next = s1 + STEP > MAX ? MAX : s1 + STEP;      // too high → raise rates
  else if (u < BigInt(TARGET) - BAND) next = s1 < MIN + STEP ? MIN : s1 - STEP; // too low  → lower rates
  if (next === s1) { console.log(`util ${(Number(u) / 100).toFixed(1)}% within deadband of target ${TARGET / 100}% — no change`); return; }
  const tx = new Transaction();
  ptb.setRateCurve(tx, { pkg: LENDING, stableType: STABLE, cap: OPCAP, pool: POOL, curve: { baseBps: p.baseBps, slope1Bps: Number(next), slope2Bps: p.slope2Bps, kinkBps: p.kinkBps, reserveBps: p.reserveBps } });
  tx.setSender(kp.toSuiAddress());
  const r = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } });
  await client.waitForTransaction({ digest: r.digest });
  const np = await readPool(client, POOL);
  console.log(`util ${(Number(u) / 100).toFixed(1)}% vs target ${TARGET / 100}% → slope1 ${p.slope1Bps}→${Number(next)} · borrow APR now ${(borrowRateBps(np) / 100).toFixed(2)}% · supply APY ${supplyApyPct(np).toFixed(2)}%  (${r.effects?.status?.status})`);
}

if (LOOP) { for (;;) { try { await tick(); } catch (e) { console.error("keeper tick err:", e.message || e); } await sleep(INTERVAL); } }
else await tick();
