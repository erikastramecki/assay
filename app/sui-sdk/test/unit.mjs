// Unit tests for @assay/sui-sdk — attestation (security-critical), math, PTB builders.
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import assert from "node:assert";
import {
  attestationMessage, signAttestation, operatorPubkeyBytes, verifyAttestation,
  currentDebt, sharesToAssets, ptb,
} from "../src/index.ts";

let pass = 0;
const t = async (name, fn) => { await fn(); console.log("  ✓", name); pass++; };

const BORROWER = "0x8f15b73cc91905a7eda7500e5142b990084ae5acfba4158b90566bddd5a72be3";
const PKG = "0xcb94061032948acf586f2f0930d2941ccd71b2ffcf4b16fa99592cddf65cfc4b";

const COLL = `${PKG}::tbtc::TBTC`, COLL2 = `${PKG}::tfake::TFAKE`;
const STABLE = `${PKG}::tusdc::TUSDC`, STABLE2 = `${PKG}::other::OTHER`;
const POOL = "0x00000000000000000000000000000000000000000000000000000000000000aa";
const POOL2 = "0x00000000000000000000000000000000000000000000000000000000000000bb";

/** Baseline terms; spread-and-override to vary exactly one field per assertion. */
const TERMS = {
  poolId: POOL, borrower: BORROWER, debt: 500_000_000n, collateralAmount: 10_000_000_000n,
  loanCommit: 999n, expiryS: 1_700_000_060n, collateralType: COLL, stableType: STABLE,
};

console.log("attestation:");
await t("message binds addr+debt+coll+commit+expiry+pool+TYPEs at correct offsets", () => {
  const m = attestationMessage(TERMS);
  assert.ok(m.length > 120, "120 fixed bytes + two length-prefixed type names");
  const at = (off) => new DataView(m.buffer, m.byteOffset + off, 8).getBigUint64(0, true);
  assert.equal(at(32), 500_000_000n);    // debt
  assert.equal(at(40), 10_000_000_000n); // collateral amount
  assert.equal(at(80), 1_700_000_060n);  // expiry (after the 32-byte loan_commit)
});

await t("sign → verify roundtrip succeeds", async () => {
  const op = new Ed25519Keypair();
  const sig = await signAttestation(op, TERMS);
  assert.equal(sig.length, 64);
  assert.equal(operatorPubkeyBytes(op).length, 32);
  assert.equal(await verifyAttestation(operatorPubkeyBytes(op), sig, TERMS), true);
});

await t("tampering ANY term breaks verification", async () => {
  const op = new Ed25519Keypair();
  const sig = await signAttestation(op, TERMS);
  const pk = operatorPubkeyBytes(op);
  const breaks = async (over, label) =>
    assert.equal(await verifyAttestation(pk, sig, { ...TERMS, ...over }), false, label);
  await breaks({ debt: 999_000_000n }, "debt");
  await breaks({ collateralAmount: 1n }, "collateral amount");
  await breaks({ borrower: "0x1" }, "borrower");
  await breaks({ loanCommit: 1n }, "commit");
  await breaks({ expiryS: 1_700_009_999n }, "expiry");        // audit F2.1
  await breaks({ poolId: POOL2 }, "pool");                    // audit F2.3
  await breaks({ collateralType: COLL2 }, "collateral type"); // collateral substitution
  await breaks({ stableType: STABLE2 }, "stable type");       // audit F2.3
});

await t("type names are length-prefixed, so no (collateral,stable) split is ambiguous", async () => {
  // Raw concatenation would make ("ab","c") and ("a","bc") identical bytes, letting one signature
  // authorize a different type pair. Length prefixes must make these two messages differ.
  const a = attestationMessage({ ...TERMS, collateralType: `${PKG}::ab::AB`, stableType: `${PKG}::c::C` });
  const b = attestationMessage({ ...TERMS, collateralType: `${PKG}::a::A`, stableType: `${PKG}::bc::BC` });
  assert.notDeepEqual(Array.from(a), Array.from(b));
});

await t("a different operator's signature does not verify", async () => {
  const op1 = new Ed25519Keypair(), op2 = new Ed25519Keypair();
  const sig = await signAttestation(op1, TERMS);
  assert.equal(await verifyAttestation(operatorPubkeyBytes(op2), sig, TERMS), false);
});

console.log("math:");
await t("currentDebt applies the index ratio", () => {
  // principal 500e6, index doubled since snapshot → owed 1000e6
  assert.equal(currentDebt({ principal: 500_000_000n, indexSnapshot: 1_000000000000000000n }, 2_000000000000000000n), 1_000_000_000n);
});
await t("sharesToAssets is proportional", () => {
  assert.equal(sharesToAssets(500n, 1000n, 1_050_000_000n), 525_000_000n);
});

console.log("ptb builders (produce valid tx data, no throw):");
await t("deposit + withdraw + disburse + repay + settle build cleanly", () => {
  const tx = new Transaction();
  const [c1] = tx.splitCoins(tx.gas, [1000n]);
  ptb.deposit(tx, { pkg: PKG, stableType: `${PKG}::tusdc::TUSDC`, pool: "0x2", coin: c1 });
  ptb.withdraw(tx, { pkg: PKG, stableType: `${PKG}::tusdc::TUSDC`, pool: "0x2", shares: 100n, recipient: BORROWER });
  const [c2] = tx.splitCoins(tx.gas, [500n]);
  ptb.disburseAttested(tx, { pkg: PKG, collType: `${PKG}::sspx::SSPX`, stableType: `${PKG}::tusdc::TUSDC`, pool: "0x2", collateralCoin: c2, debt: 500n, loanCommit: 999n, expiryS: 1_700_000_060n, attestation: new Uint8Array(64) });
  const [c3] = tx.splitCoins(tx.gas, [500n]);
  ptb.repay(tx, { pkg: PKG, collType: `${PKG}::sspx::SSPX`, stableType: `${PKG}::tusdc::TUSDC`, pool: "0x2", position: "0x3", paymentCoin: c3, recipient: BORROWER });
  ptb.settleBatch(tx, { pkg: PKG, stableType: `${PKG}::tusdc::TUSDC`, cap: "0x3", pool: "0x2", proof: new Uint8Array(128) });
  const data = tx.getData();
  const calls = data.commands.filter((c) => c.MoveCall).map((c) => c.MoveCall.function);
  for (const fn of ["deposit", "withdraw", "disburse_attested", "repay", "settle_batch"])
    assert.ok(calls.includes(fn), `missing ${fn}`);
});

console.log(`\n${pass} passed`);
