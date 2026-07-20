// Create real utilization on the LIVE pool so the demo shows a genuine (non-zero) supply APY:
// faucet BTC → borrow USDC against it via the hosted operator attestation. Env: SUI_PRIVKEY LENDING POOL STABLE BTC
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { fromHex } from "@mysten/sui/utils";
import { ptb, exactCoin, readPool, borrowRateBps, supplyApyPct, utilization } from "../src/index.ts";

const API = "https://assay-operator-sui.vercel.app";
const { LENDING, POOL, STABLE, BTC } = process.env;
const kp = Ed25519Keypair.fromSecretKey(process.env.SUI_PRIVKEY.trim());
const me = kp.toSuiAddress();
const client = new SuiClient({ url: getFullnodeUrl("devnet") });
const post = async (p, b) => { const r = await fetch(API + p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(b) }); const j = await r.json(); if (!r.ok) throw new Error(p + " " + JSON.stringify(j)); return j; };
async function exec(tx, label) { tx.setSender(me); const r = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } }); await client.waitForTransaction({ digest: r.digest }); console.log(`${label}: ${r.effects?.status?.status} ${r.digest}`); return r; }

await post("/faucet", { address: me, coinType: BTC });
await new Promise((r) => setTimeout(r, 2500));
// borrow 4000 USDC vs 1 BTC → utilization 4000/5000 = 80% (the kink) → ~14% borrow, ~10% supply APY
const b = await post("/borrow", { borrower: me, collateralMint: BTC, collateralAmount: 100_000_000, debtUsdc: 4000 });
const tx = new Transaction();
const coll = await exactCoin(tx, client, me, BTC, BigInt(b.collateralBase));
ptb.disburseAttested(tx, { pkg: LENDING, collType: BTC, stableType: STABLE, pool: POOL, collateralCoin: coll, debt: BigInt(b.debtBase), loanCommit: BigInt(b.loanCommit), expiryS: BigInt(b.expiryS), attestation: fromHex(b.attestation) });
await exec(tx, "borrow 4000 USDC vs 1 BTC");
const p = await readPool(client, POOL);
console.log(`\nLIVE pool now: utilization ${(utilization(p) * 100).toFixed(1)}% | borrow APR ${(borrowRateBps(p) / 100).toFixed(2)}% | supply APY ${supplyApyPct(p).toFixed(2)}%`);
