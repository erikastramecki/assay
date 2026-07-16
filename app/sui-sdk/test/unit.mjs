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

console.log("attestation:");
await t("message binds addr+debt+coll+commit+TYPE with correct offsets", () => {
  const m = attestationMessage(BORROWER, 500_000_000n, 10_000_000_000n, 999n, COLL);
  assert.ok(m.length > 80, "80 fixed + the collateral type name");
  const debt = new DataView(m.buffer, 32, 8).getBigUint64(0, true);
  assert.equal(debt, 500_000_000n);
  const coll = new DataView(m.buffer, 40, 8).getBigUint64(0, true);
  assert.equal(coll, 10_000_000_000n);
});

await t("sign → verify roundtrip succeeds", async () => {
  const op = new Ed25519Keypair();
  const sig = await signAttestation(op, BORROWER, 500_000_000n, 10_000_000_000n, 999n, COLL);
  assert.equal(sig.length, 64);
  assert.equal(operatorPubkeyBytes(op).length, 32);
  assert.equal(await verifyAttestation(operatorPubkeyBytes(op), sig, BORROWER, 500_000_000n, 10_000_000_000n, 999n, COLL), true);
});

await t("tampering ANY term breaks verification", async () => {
  const op = new Ed25519Keypair();
  const sig = await signAttestation(op, BORROWER, 500_000_000n, 10_000_000_000n, 999n, COLL);
  const pk = operatorPubkeyBytes(op);
  assert.equal(await verifyAttestation(pk, sig, BORROWER, 999_000_000n, 10_000_000_000n, 999n, COLL), false); // debt
  assert.equal(await verifyAttestation(pk, sig, BORROWER, 500_000_000n, 1n, 999n, COLL), false); // coll amount
  assert.equal(await verifyAttestation(pk, sig, "0x1", 500_000_000n, 10_000_000_000n, 999n, COLL), false); // borrower
  assert.equal(await verifyAttestation(pk, sig, BORROWER, 500_000_000n, 10_000_000_000n, 1n, COLL), false); // commit
});

await t("collateral-substitution is blocked (audit fix): same terms, different TYPE → no verify", async () => {
  const op = new Ed25519Keypair();
  const sig = await signAttestation(op, BORROWER, 500_000_000n, 10_000_000_000n, 999n, COLL);
  // an attacker presenting a worthless coin type of the same unit-count must NOT pass
  assert.equal(await verifyAttestation(operatorPubkeyBytes(op), sig, BORROWER, 500_000_000n, 10_000_000_000n, 999n, COLL2), false);
});

await t("a different operator's signature does not verify", async () => {
  const op1 = new Ed25519Keypair(), op2 = new Ed25519Keypair();
  const sig = await signAttestation(op1, BORROWER, 500_000_000n, 10_000_000_000n, 999n, COLL);
  assert.equal(await verifyAttestation(operatorPubkeyBytes(op2), sig, BORROWER, 500_000_000n, 10_000_000_000n, 999n, COLL), false);
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
  ptb.disburseAttested(tx, { pkg: PKG, collType: `${PKG}::sspx::SSPX`, stableType: `${PKG}::tusdc::TUSDC`, pool: "0x2", collateralCoin: c2, debt: 500n, loanCommit: 999n, attestation: new Uint8Array(64) });
  const [c3] = tx.splitCoins(tx.gas, [500n]);
  ptb.repay(tx, { pkg: PKG, collType: `${PKG}::sspx::SSPX`, stableType: `${PKG}::tusdc::TUSDC`, pool: "0x2", position: "0x3", paymentCoin: c3, recipient: BORROWER });
  ptb.settleBatch(tx, { pkg: PKG, stableType: `${PKG}::tusdc::TUSDC`, pool: "0x2", proof: new Uint8Array(128) });
  const data = tx.getData();
  const calls = data.commands.filter((c) => c.MoveCall).map((c) => c.MoveCall.function);
  for (const fn of ["deposit", "withdraw", "disburse_attested", "repay", "settle_batch"])
    assert.ok(calls.includes(fn), `missing ${fn}`);
});

console.log(`\n${pass} passed`);
