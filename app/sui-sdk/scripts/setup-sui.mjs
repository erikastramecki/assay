// One-shot on-chain setup for the Assay Sui stack (devnet): init a Pool pinned to the operator
// API's ed25519 key, seed it with liquidity, and hand the test-coin faucet caps + a little gas
// to the operator address (so the hosted /faucet can mint TUSDC/SSPX to visitors). Prints JSON
// { pool, operatorAddress, operatorPubkey } for dev-up-sui.sh to write into .env.local.
// Env: SUI_PRIVKEY (admin/LP) LENDING COINS CAP_USDC CAP_SSPX OPERATOR_KEYFILE SEED_TUSDC
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { toHex } from "@mysten/sui/utils";
import { readFileSync } from "node:fs";
import os from "node:os";
import { ptb, exactCoin, operatorPubkeyBytes } from "../src/index.ts";

const { LENDING, COINS, CAP_USDC, CAP_SSPX } = process.env;
const OPERATOR_KEYFILE = process.env.OPERATOR_KEYFILE || new URL("../../../app/operator-api/.operator-sui.key", import.meta.url);
const SEED = BigInt(process.env.SEED_TUSDC || "1000") * 1_000_000n; // 1000 TUSDC default
const TUSDC = `${COINS}::tusdc::TUSDC`;
const vkLine = readFileSync(new URL("../../../perloan-prep/proof_A_sui_hex.txt", import.meta.url), "utf8").split("\n").find((l) => l.startsWith("VK_HEX=")).slice(7);
const VK = Uint8Array.from(vkLine.match(/../g).map((h) => parseInt(h, 16)));

const admin = Ed25519Keypair.fromSecretKey(process.env.SUI_PRIVKEY.trim());
const me = admin.toSuiAddress();
const operator = Ed25519Keypair.fromSecretKey(readFileSync(OPERATOR_KEYFILE, "utf8").trim());
const operatorAddress = operator.toSuiAddress();
const client = new SuiClient({ url: getFullnodeUrl("devnet") });

async function exec(tx, label, signer = admin) {
  tx.setSender(signer.toSuiAddress());
  const r = await client.signAndExecuteTransaction({ signer, transaction: tx, options: { showEffects: true, showObjectChanges: true } });
  await client.waitForTransaction({ digest: r.digest });
  if (r.effects?.status?.status !== "success") { console.error(`FAIL ${label}:`, JSON.stringify(r.effects?.status)); process.exit(1); }
  process.stderr.write(`  ✓ ${label} ${r.digest}\n`);
  return r;
}
const created = (r, needle) => r.objectChanges.find((c) => c.type === "created" && c.objectType.includes(needle))?.objectId;

// 1. keep the operator topped up with a little gas (for /faucet + mints)
{ const tx = new Transaction(); const [gas] = tx.splitCoins(tx.gas, [500_000_000n]); tx.transferObjects([gas], operatorAddress); await exec(tx, "fund operator 0.5 SUI"); }

// 2. mint seed liquidity to admin. The operator holds the TreasuryCaps (so the hosted /faucet can
// mint), so the operator signs this mint with admin as recipient. (On a first-ever run where admin
// still holds the caps, transfer them to the operator once beforehand.)
{ const tx = new Transaction(); tx.moveCall({ target: `${COINS}::tusdc::mint`, arguments: [tx.object(CAP_USDC), tx.pure.u64(SEED), tx.pure.address(me)] }); await exec(tx, `mint seed ${SEED} TUSDC`, operator); }

// 3. init the pool (operator pubkey pinned) + deposit the seed
let pool, opcap;
{ const tx = new Transaction();
  // live curve: 0 base, 14% APR at the 80% kink, steep 300% above it, 10% reserve factor
  // per-collateral isolation cap: any single collateral can borrow ≤ 4000 USDC from the shared pool
  ptb.initPool(tx, { pkg: LENDING, stableType: TUSDC, curve: { baseBps: 0, slope1Bps: 1400, slope2Bps: 30000, kinkBps: 8000, reserveBps: 1000 }, cap: 1_000_000_000_000n, perCollateralCap: 4_000_000_000n, vk: VK, operatorPubkey: operatorPubkeyBytes(operator) });
  const r = await exec(tx, "init_pool (operator pinned)"); pool = created(r, "async_lending::Pool"); opcap = created(r, "async_lending::OperatorCap"); }
{ const tx = new Transaction(); const coin = await exactCoin(tx, client, me, TUSDC, SEED); ptb.deposit(tx, { pkg: LENDING, stableType: TUSDC, pool, coin }); await exec(tx, "deposit seed liquidity"); }

console.log(JSON.stringify({ pool, opcap, operatorAddress, operatorPubkey: toHex(operatorPubkeyBytes(operator)) }));
