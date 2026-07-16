// GOVERNANCE: retune the interest-rate curve on a live pool (no redeploy). The OperatorCap holder
// signs. Env: SUI_PRIVKEY LENDING POOL OPCAP STABLE   Args: <base> <slope1> <slope2> <kink> <reserve> (bps)
//   e.g.  node --import tsx scripts/set-curve.mjs 0 2000 30000 8000 1000   (→ 20% APR at 80% kink)
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { ptb, readPool, borrowRateBps, supplyApyPct, utilization } from "../src/index.ts";

const { LENDING, POOL, OPCAP, STABLE } = process.env;
const [base, slope1, slope2, kink, reserve] = process.argv.slice(2).map(Number);
if ([base, slope1, slope2, kink, reserve].some((n) => !Number.isFinite(n))) {
  console.error("usage: set-curve.mjs <base> <slope1> <slope2> <kink> <reserve> (bps)"); process.exit(1);
}
const kp = Ed25519Keypair.fromSecretKey(process.env.SUI_PRIVKEY.trim());
const client = new SuiClient({ url: getFullnodeUrl("devnet") });

const tx = new Transaction();
ptb.setRateCurve(tx, { pkg: LENDING, stableType: STABLE, cap: OPCAP, pool: POOL, curve: { baseBps: base, slope1Bps: slope1, slope2Bps: slope2, kinkBps: kink, reserveBps: reserve } });
tx.setSender(kp.toSuiAddress());
const r = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true } });
await client.waitForTransaction({ digest: r.digest });
console.log("set_rate_curve:", r.effects?.status?.status, r.digest);
const p = await readPool(client, POOL);
console.log(`new curve → utilization ${(utilization(p) * 100).toFixed(1)}% · borrow APR ${(borrowRateBps(p) / 100).toFixed(2)}% · supply APY ${supplyApyPct(p).toFixed(2)}%`);
