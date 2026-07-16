// LIQUIDATION KEEPER — scans every open position, computes health from the CONSERVATIVE Pyth price
// and each market's liquidation threshold (liqBps), and liquidates the underwater ones: pays the
// debt from a USDC buffer and seizes the collateral (profit = the liquidation margin). Operator-run
// (holds the OperatorCap). Env: SUI_PRIVKEY LENDING POOL OPCAP STABLE
//   node --import tsx scripts/liquidation-keeper.mjs            # one scan of the env pool
//   node --import tsx scripts/liquidation-keeper.mjs --loop     # keep watching
//   node --import tsx scripts/liquidation-keeper.mjs --demo     # stage an underwater loan, then liquidate it
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { readFileSync } from "node:fs";
import os from "node:os";
import { ptb, exactCoin, readPool, allOpenPositions, accrueIndex, currentDebt } from "../src/index.ts";
import { fetchPythPrice, applyOraclePolicy } from "../../../operator/pyth.mjs";

const HOME = os.homedir();
const markets = JSON.parse(readFileSync(new URL("../../../app/sui-harness/markets.json", import.meta.url), "utf8"));
const ctOf = (m) => m.coinType || `${markets.marketsPkg}::${m.module}::${m.struct}`;
const byType = Object.fromEntries(markets.markets.map((m) => [ctOf(m), m]));
const STABLE = process.env.STABLE, STABLE_UNIT = 1e6;
const VK = Uint8Array.from(readFileSync(new URL("../../../perloan-prep/proof_A_sui_hex.txt", import.meta.url), "utf8").split("\n").find((l) => l.startsWith("VK_HEX=")).slice(7).match(/../g).map((h) => parseInt(h, 16)));

const kp = Ed25519Keypair.fromSecretKey(process.env.SUI_PRIVKEY.trim());
const me = kp.toSuiAddress();
const client = new SuiClient({ url: getFullnodeUrl("devnet") });
let LENDING = process.env.LENDING, POOL = process.env.POOL, OPCAP = process.env.OPCAP;
const args = process.argv.slice(2);
const DEMO = args.includes("--demo"), LOOP = args.includes("--loop");
const INTERVAL = Number((args.find((a) => a.startsWith("--interval=")) || "=30").split("=")[1]) * 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function exec(tx, signer = kp) { tx.setSender(signer.toSuiAddress()); const r = await client.signAndExecuteTransaction({ signer, transaction: tx, options: { showEffects: true, showObjectChanges: true } }); await client.waitForTransaction({ digest: r.digest }); if (r.effects?.status?.status !== "success") throw new Error(JSON.stringify(r.effects?.status)); return r; }
const created = (r, n) => r.objectChanges.find((c) => c.type === "created" && c.objectType.includes(n))?.objectId;

async function conservativeUsd(m) {
  const ora = applyOraclePolicy(await fetchPythPrice(m.feedId), { nowMs: Date.now(), maxConfBps: 100, assetClass: m.assetClass });
  return ora.ok ? (Number(ora.price) - 2 * Number(ora.conf)) / 100 : null;
}

async function tick() {
  const pool = await readPool(client, POOL);
  const idx = accrueIndex(pool, BigInt(Math.floor(Date.now() / 1000)));
  const positions = await allOpenPositions(client, LENDING);
  console.log(`scan: ${positions.length} open position(s)`);
  for (const p of positions) {
    const m = byType[p.collateralType];
    if (!m) { console.log(`  ${p.id.slice(0, 8)}… unknown collateral, skip`); continue; }
    const debt = Number(currentDebt(p, idx)) / STABLE_UNIT;
    const px = await conservativeUsd(m);
    if (px == null) { console.log(`  ${m.sym} ${p.id.slice(0, 8)}… oracle stale/off-hours, skip (fail-closed)`); continue; }
    const collVal = (Number(p.collateral) / 10 ** m.decimals) * px;
    const health = debt > 0 ? (collVal * (m.liqBps / 10000)) / debt : 99;
    console.log(`  ${m.sym} ${p.id.slice(0, 8)}…: collateral $${collVal.toFixed(2)} · debt $${debt.toFixed(2)} · health ${health.toFixed(2)} ${health < 1 ? "🔴 UNDERWATER" : "🟢 ok"}`);
    if (health < 1) {
      const owed = currentDebt(p, idx); // exact on a rate=0 pool
      const tx = new Transaction();
      const pay = await exactCoin(tx, client, me, STABLE, owed);
      ptb.liquidate(tx, { pkg: LENDING, collType: p.collateralType, stableType: STABLE, cap: OPCAP, pool: POOL, position: p.id, paymentCoin: pay, recipient: me });
      const r = await exec(tx);
      console.log(`    ⚡ LIQUIDATED — paid $${(Number(owed) / STABLE_UNIT).toFixed(2)}, seized ${Number(p.collateral) / 10 ** m.decimals} ${m.sym}  tx ${r.digest}`);
    }
  }
}

if (DEMO) {
  const capOwner = Ed25519Keypair.fromSecretKey(readFileSync(new URL("../../../app/operator-api/.operator-sui.key", import.meta.url), "utf8").trim());
  const COINS = "0x537ba694cf26744a208ac69001a2102f12258e2999834ed8ea0b0cc941667d1f", CAP_USDC = "0x6ac4c50740c98fc78057c62efb00bc96ca7e0201f7c854f5d86bb906cafe6446";
  const sol = markets.markets.find((m) => m.sym === "SOL"), solType = ctOf(sol);
  await exec((() => { const t = new Transaction(); t.moveCall({ target: `${COINS}::tusdc::mint`, arguments: [t.object(CAP_USDC), t.pure.u64(300_000_000n), t.pure.address(me)] }); return t; })(), capOwner);
  await exec((() => { const t = new Transaction(); t.moveCall({ target: sol.mintTarget, arguments: [t.object(sol.cap), t.pure.u64(1_000_000_000n), t.pure.address(me)] }); return t; })(), capOwner);
  { const t = new Transaction(); ptb.initPool(t, { pkg: LENDING, stableType: STABLE, curve: { baseBps: 0, slope1Bps: 0, slope2Bps: 0, kinkBps: 8000, reserveBps: 0 }, cap: 1_000_000_000_000n, perCollateralCap: 0n, vk: VK, operatorPubkey: new Uint8Array(32) });
    const r = await exec(t); POOL = created(r, "async_lending::Pool"); OPCAP = created(r, "async_lending::OperatorCap"); }
  { const t = new Transaction(); const c = await exactCoin(t, client, me, STABLE, 200_000_000n); ptb.deposit(t, { pkg: LENDING, stableType: STABLE, pool: POOL, coin: c }); await exec(t); }
  // underwater by construction: 1 SOL (~$77) collateral, $70 debt → threshold $77·72% = $55 < $70
  { const t = new Transaction(); const coll = await exactCoin(t, client, me, solType, 1_000_000_000n);
    t.moveCall({ target: `${LENDING}::async_lending::disburse_entry`, typeArguments: [solType, STABLE], arguments: [t.object(OPCAP), t.object(POOL), coll, t.pure.u64(70_000_000n), t.pure.address(me), t.pure.u256(1n), t.object("0x6")] }); await exec(t); }
  console.log(`demo: staged pool ${POOL} with an underwater 1-SOL / $70 loan\n`);
}

if (LOOP) { for (;;) { try { await tick(); } catch (e) { console.error("tick err:", e.message || e); } await sleep(INTERVAL); } }
else await tick();
