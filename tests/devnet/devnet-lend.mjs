// Live Sui DEVNET RWA borrow: one PTB — create a lender pool, then borrow against
// locked collateral, gated on the real dregg proof (verified on-chain). Uses SUI
// for both collateral and stable to avoid mock-coin infra; the mechanism (lock +
// proof-verify + disburse) is identical to a real RWA token.
//   node devnet-lend.mjs <LENDING_PKG>
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Transaction } from "@mysten/sui/transactions";
import { readFileSync } from "node:fs";

const PKG = process.argv[2];
const SUI = "0x2::sui::SUI";
const g = new SuiGrpcClient({ network: "devnet", baseUrl: "https://fullnode.devnet.sui.io:443" });
const keys = JSON.parse(readFileSync(new URL("../../../agent-company-demo/sui/.keys.json", import.meta.url), "utf8"));
const kp = Ed25519Keypair.fromSecretKey(keys.Treasury);
const me = kp.getPublicKey().toSuiAddress();

const FX = new URL("../../../onchain-solana/fixtures/", import.meta.url).pathname;
const bytes = (n) => [...Uint8Array.from(Buffer.from(readFileSync(`${FX}${n}.hex`, "utf8").trim().replace(/^0x/, ""), "hex"))];
const vk = bytes("vk"), pub = bytes("public"), proof = bytes("proof");

const POOL = 2_000_000_000n;   // 2 SUI lender liquidity
const COLL = 1_000_000_000n;   // 1 SUI collateral
const DEBT = 500_000_000n;     // borrow 0.5 SUI

(async () => {
  console.log(`borrower ${me}`);
  const tx = new Transaction();
  tx.setSender(me);
  const [funds, collateral] = tx.splitCoins(tx.gas, [POOL, COLL]);
  const pool = tx.moveCall({ target: `${PKG}::lending::create_pool`, typeArguments: [SUI], arguments: [funds] });
  const [loan, pos] = tx.moveCall({
    target: `${PKG}::lending::borrow`,
    typeArguments: [SUI, SUI],
    arguments: [pool, collateral, tx.pure.u64(DEBT), tx.pure.vector("u8", vk), tx.pure.vector("u8", pub), tx.pure.vector("u8", proof)],
  });
  tx.transferObjects([loan, pos], me);
  tx.moveCall({ target: "0x2::transfer::public_share_object", typeArguments: [`${PKG}::lending::Pool<${SUI}>`], arguments: [pool] });
  tx.setGasBudget(200_000_000);

  const r = await g.signAndExecuteTransaction({ transaction: tx, signer: kp });
  const t = r.Transaction || r;
  console.log("BORROW tx:", t.digest, JSON.stringify(t.status));
  await g.waitForTransaction({ digest: t.digest });
  const gt = await g.getTransaction({ digest: t.digest, include: { effects: true } });
  const eff = (gt.Transaction || gt).effects;
  const created = (eff?.changedObjects || []).filter((o) => o.idOperation === "Created");
  console.log(`created ${created.length} objects (loan Coin + Position + shared Pool)`);
  if (t.status?.success) {
    console.log("\n✅ LIVE DEVNET BORROW — dregg proof verified on-chain (borrow would abort EBadProof otherwise); 0.5 SUI disbursed against 1 SUI locked collateral");
    console.log(`   explorer: https://suiscan.xyz/devnet/tx/${t.digest}`);
  } else {
    console.log("❌ borrow failed:", JSON.stringify(t.status));
    process.exit(1);
  }
})().catch((e) => { console.error("ERR", e.message || e); process.exit(1); });
