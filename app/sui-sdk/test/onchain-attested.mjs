// On-chain validation of @assay/sui-sdk against the live devnet contract: the full
// NON-CUSTODIAL attested flow — init_pool → deposit → disburse_attested (operator ed25519
// attestation, verified in-Move) → repay. Signs with the sui CLI's active keypair.
// Env: SUI_PRIVKEY LENDING COINS CAP_USDC CAP_SSPX
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { readFileSync } from "node:fs";
import os from "node:os";
import { ptb, exactCoin, signAttestation, operatorPubkeyBytes, findPositions } from "../src/index.ts";

const LENDING = process.env.LENDING, COINS = process.env.COINS;
const CAP_USDC = process.env.CAP_USDC, CAP_SSPX = process.env.CAP_SSPX;
const TUSDC = `${COINS}::tusdc::TUSDC`, SSPX = `${COINS}::sspx::SSPX`;
const vkLine = readFileSync(new URL("../../../perloan-prep/proof_A_sui_hex.txt", import.meta.url), "utf8")
  .split("\n").find((l) => l.startsWith("VK_HEX=")).slice(7);
const VK = Uint8Array.from(vkLine.match(/../g).map((h) => parseInt(h, 16)));

const kp = Ed25519Keypair.fromSecretKey(process.env.SUI_PRIVKEY.trim());
const me = kp.toSuiAddress();
// the test-coin caps live with the deployed operator (for the faucet) — mint via that key
const capOwner = Ed25519Keypair.fromSecretKey(readFileSync(new URL("../../../app/operator-api/.operator-sui.key", import.meta.url), "utf8").trim());
const client = new SuiClient({ url: getFullnodeUrl("devnet") });

async function exec(tx, label, signer = kp) {
  tx.setSender(signer.toSuiAddress());
  const r = await client.signAndExecuteTransaction({
    signer, transaction: tx,
    options: { showEffects: true, showObjectChanges: true },
  });
  await client.waitForTransaction({ digest: r.digest });
  const status = r.effects?.status?.status;
  console.log(`${status === "success" ? "✅" : "❌"} ${label}  ${r.digest}`);
  if (status !== "success") { console.log(JSON.stringify(r.effects?.status)); process.exit(1); }
  return r;
}
const created = (r, needle) => r.objectChanges.find((c) => c.type === "created" && c.objectType.includes(needle))?.objectId;

console.log("signer:", me);

// 1. mint test coins
{ const tx = new Transaction(); tx.moveCall({ target: `${COINS}::tusdc::mint`, arguments: [tx.object(CAP_USDC), tx.pure.u64(1_000_000_000n), tx.pure.address(me)] }); await exec(tx, "mint 1000 TUSDC", capOwner); }
{ const tx = new Transaction(); tx.moveCall({ target: `${COINS}::sspx::mint`, arguments: [tx.object(CAP_SSPX), tx.pure.u64(10_000_000_000n), tx.pure.address(me)] }); await exec(tx, "mint 100 SSPX", capOwner); }

// 2. init pool with operator_pubkey = my ed25519 pubkey
let pool;
{ const tx = new Transaction();
  ptb.initPool(tx, { pkg: LENDING, stableType: TUSDC, curve: { baseBps: 0, slope1Bps: 0, slope2Bps: 0, kinkBps: 8000, reserveBps: 0 }, cap: 1_000_000_000_000n, perCollateralCap: 0n, vk: VK, operatorPubkey: operatorPubkeyBytes(kp) });
  const r = await exec(tx, "init_pool (operator = me)");
  pool = created(r, "async_lending::Pool");
  console.log("   pool:", pool); }

// 3. deposit 1000
{ const tx = new Transaction(); const coin = await exactCoin(tx, client, me, TUSDC, 1_000_000_000n);
  ptb.deposit(tx, { pkg: LENDING, stableType: TUSDC, pool, coin }); await exec(tx, "deposit 1000 TUSDC"); }

// 4. disburse_attested — operator (me) signs the exact terms; contract verifies ed25519 in-Move
const debt = 500_000_000n, collAmt = 10_000_000_000n, commit = 999n;
const attestation = await signAttestation(kp, me, debt, collAmt, commit, SSPX);
let position;
{ const tx = new Transaction(); const coll = await exactCoin(tx, client, me, SSPX, collAmt);
  ptb.disburseAttested(tx, { pkg: LENDING, collType: SSPX, stableType: TUSDC, pool, collateralCoin: coll, debt, loanCommit: commit, attestation });
  const r = await exec(tx, "disburse_attested (non-custodial borrow)");
  position = created(r, "async_lending::Position");
  console.log("   position:", position); }

// 5. repay (rate 0 → owed == principal); collateral returns to me, position closes
{ const tx = new Transaction(); const pay = await exactCoin(tx, client, me, TUSDC, debt);
  ptb.repay(tx, { pkg: LENDING, collType: SSPX, stableType: TUSDC, pool, position, paymentCoin: pay, recipient: me });
  await exec(tx, "repay 500 TUSDC → collateral back"); }

const remaining = await findPositions(client, LENDING, me);
console.log(`\npositions after repay: ${remaining.length} ${remaining.length === 0 ? "(closed ✓)" : "(!!)"}`);
console.log(remaining.length === 0 ? "✅ SDK attested loop GREEN on devnet" : "❌ position not closed");
process.exit(remaining.length === 0 ? 0 : 1);
