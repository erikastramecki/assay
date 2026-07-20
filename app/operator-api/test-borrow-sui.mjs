// Integration test: Sui Operator API /health + /quote + /borrow (ed25519 attestation) →
// on-chain disburse_attested. Proves the operator's attestation is verified + accepted by the
// live contract, and that the borrow is NON-CUSTODIAL (borrower sends the tx, supplies collateral).
// Env: SUI_PRIVKEY LENDING COINS CAP_USDC CAP_SSPX API_URL
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { fromHex } from "@mysten/sui/utils";
import { readFileSync } from "node:fs";
import os from "node:os";
import { ptb, exactCoin, findPositions, operatorPubkeyBytes } from "../sui-sdk/src/index.ts";

const API = process.env.API_URL || "http://127.0.0.1:8788";
const LENDING = process.env.LENDING, COINS = process.env.COINS;
const CAP_USDC = process.env.CAP_USDC, CAP_SSPX = process.env.CAP_SSPX;
const TUSDC = `${COINS}::tusdc::TUSDC`, SSPX = `${COINS}::sspx::SSPX`;
const vkLine = readFileSync(new URL("../../perloan-prep/proof_A_sui_hex.txt", import.meta.url), "utf8")
  .split("\n").find((l) => l.startsWith("VK_HEX=")).slice(7);
const VK = Uint8Array.from(vkLine.match(/../g).map((h) => parseInt(h, 16)));
const kp = Ed25519Keypair.fromSecretKey(process.env.SUI_PRIVKEY.trim());
const me = kp.toSuiAddress();
const client = new SuiClient({ url: getFullnodeUrl("devnet") });
const post = async (p, b) => { const r = await fetch(API + p, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(b) }); const j = await r.json(); if (!r.ok) throw new Error(p + " " + JSON.stringify(j)); return j; };
async function exec(tx, label) {
  tx.setSender(me);
  const r = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, options: { showEffects: true, showObjectChanges: true } });
  await client.waitForTransaction({ digest: r.digest });
  const st = r.effects?.status?.status;
  console.log(`${st === "success" ? "✅" : "❌"} ${label}  ${r.digest}`);
  if (st !== "success") { console.log(JSON.stringify(r.effects?.status)); process.exit(1); }
  return r;
}
const created = (r, needle) => r.objectChanges.find((c) => c.type === "created" && c.objectType.includes(needle))?.objectId;

// TWO PHASES. The attestation now binds the pool id (audit F2.3), so the operator must know its
// pool at boot — but the pool must pin the operator's pubkey. The cycle is broken by deriving the
// pubkey from the operator's keyfile here, creating the pool FIRST, then booting the operator
// with POOL_ID. Phase is selected by argv: `init` (mint+pool+deposit) then `borrow`.
const PHASE = process.argv[2] || "borrow";

if (PHASE === "init") {
  const opKeyfile = process.env.OPERATOR_KEY || new URL(".operator-sui.key", import.meta.url).pathname;
  const opPubkey = operatorPubkeyBytes(Ed25519Keypair.fromSecretKey(readFileSync(opKeyfile, "utf8").trim()));
  { const tx = new Transaction(); tx.moveCall({ target: `${COINS}::tusdc::mint`, arguments: [tx.object(CAP_USDC), tx.pure.u64(1_000_000_000n), tx.pure.address(me)] }); await exec(tx, "mint 1000 TUSDC"); }
  { const tx = new Transaction(); tx.moveCall({ target: `${COINS}::sspx::mint`, arguments: [tx.object(CAP_SSPX), tx.pure.u64(10_000_000_000n), tx.pure.address(me)] }); await exec(tx, "mint 100 SSPX"); }
  let pool;
  { const tx = new Transaction();
    ptb.initPool(tx, { pkg: LENDING, stableType: TUSDC, curve: { baseBps: 0, slope1Bps: 0, slope2Bps: 0, kinkBps: 8000, reserveBps: 0 }, cap: 1_000_000_000_000n, perCollateralCap: 0n, vk: VK, operatorPubkey: opPubkey });
    const r = await exec(tx, "init_pool (operator = keyfile key)"); pool = created(r, "async_lending::Pool"); }
  { const tx = new Transaction(); const coin = await exactCoin(tx, client, me, TUSDC, 1_000_000_000n); ptb.deposit(tx, { pkg: LENDING, stableType: TUSDC, pool, coin }); await exec(tx, "deposit 1000"); }
  console.log("POOL=" + pool); // consumed by test-borrow-sui.sh
  process.exit(0);
}

const pool = process.env.POOL;
if (!pool) { console.error("POOL must be set (run the `init` phase first)"); process.exit(1); }
const health = await (await fetch(API + "/health")).json();
console.log("operator pubkey (from API):", health.operatorPubkey);

const q = await post("/quote", { collateralMint: SSPX, collateralWhole: 100 });
console.log(`quote: price $${(q.priceCents / 100).toFixed(2)}  maxBorrow $${q.maxBorrowUsdc}  (mktHours=${q.marketHours})`);

const b = await post("/borrow", { borrower: me, collateralMint: SSPX, collateralAmount: 10_000_000_000, debtUsdc: 500 });
console.log(`/borrow → dregg ${b.authorized.includes("AUTHORIZED") ? "AUTHORIZED" : b.authorized}; attestation ${b.attestation.slice(0, 20)}…`);

{ const tx = new Transaction(); const coll = await exactCoin(tx, client, me, SSPX, BigInt(b.collateralBase));
  ptb.disburseAttested(tx, { pkg: LENDING, collType: SSPX, stableType: TUSDC, pool, collateralCoin: coll, debt: BigInt(b.debtBase), loanCommit: BigInt(b.loanCommit), expiryS: BigInt(b.expiryS), attestation: fromHex(b.attestation) });
  await exec(tx, "disburse_attested (with API attestation)"); }

const pos = await findPositions(client, LENDING, me);
console.log(pos.length > 0 ? `\n✅ operator-API attestation ACCEPTED on-chain — position ${pos[0].id} open (non-custodial borrow)` : "\n❌ no position opened");
process.exit(pos.length > 0 ? 0 : 1);
