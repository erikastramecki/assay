// Operator attestation for the non-custodial `disburse_attested` path.
//
// The Move contract verifies an ed25519 signature over the EXACT loan terms:
//   bcs(borrower:address) ‖ bcs(debt:u64) ‖ bcs(collateral_amount:u64) ‖ bcs(loan_commit:u256)
// = 32 + 8 + 8 + 32 = 80 bytes. This module builds that message byte-for-byte and
// signs/verifies it, so on-chain and off-chain agree. The operator signs ONLY after
// dregg authorizes the loan, so a signature can never disburse un-approved terms.
import { bcs } from "@mysten/sui/bcs";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Ed25519PublicKey } from "@mysten/sui/keypairs/ed25519";
import { normalizeSuiAddress, normalizeStructTag } from "@mysten/sui/utils";

/** The Move `type_name` canonical form of a coin type: the struct tag with the 0x stripped. */
export function moveTypeName(coinType: string): string {
  const norm = normalizeStructTag(coinType);
  return norm.startsWith("0x") ? norm.slice(2) : norm;
}

export function attestationMessage(
  borrower: string,
  debt: bigint,
  collateralAmount: bigint,
  loanCommit: bigint,
  collateralType: string,
): Uint8Array {
  const a = bcs.Address.serialize(normalizeSuiAddress(borrower)).toBytes(); // 32
  const d = bcs.u64().serialize(debt).toBytes(); // 8 LE
  const c = bcs.u64().serialize(collateralAmount).toBytes(); // 8 LE
  const k = bcs.u256().serialize(loanCommit).toBytes(); // 32 LE
  const t = new TextEncoder().encode(moveTypeName(collateralType)); // ASCII bytes of the type name
  const out = new Uint8Array(a.length + d.length + c.length + k.length + t.length);
  let o = 0;
  for (const part of [a, d, c, k, t]) { out.set(part, o); o += part.length; }
  return out;
}

/** Raw ed25519 signature (64 bytes) over the attestation message (binds the collateral TYPE). */
export async function signAttestation(
  operator: Ed25519Keypair,
  borrower: string,
  debt: bigint,
  collateralAmount: bigint,
  loanCommit: bigint,
  collateralType: string,
): Promise<Uint8Array> {
  return operator.sign(attestationMessage(borrower, debt, collateralAmount, loanCommit, collateralType));
}

/** The 32-byte raw ed25519 pubkey to pin in the pool (`operator_pubkey`). */
export function operatorPubkeyBytes(operator: Ed25519Keypair): Uint8Array {
  return operator.getPublicKey().toRawBytes();
}

/** Local verify (mirrors the on-chain `ed25519_verify`) — used in tests + defense-in-depth. */
export async function verifyAttestation(
  pubkey: Uint8Array,
  signature: Uint8Array,
  borrower: string,
  debt: bigint,
  collateralAmount: bigint,
  loanCommit: bigint,
  collateralType: string,
): Promise<boolean> {
  const msg = attestationMessage(borrower, debt, collateralAmount, loanCommit, collateralType);
  return new Ed25519PublicKey(pubkey).verify(msg, signature);
}
