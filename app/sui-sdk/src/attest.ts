// Operator attestation for the non-custodial `disburse_attested` path.
//
// The Move contract verifies an ed25519 signature over the EXACT loan terms. This module
// builds that message byte-for-byte so on-chain and off-chain agree. The layout mirrors
// `async_lending::attest_msg` exactly — change one, change both:
//
//   bcs("ASSAY_DISBURSE_V1")  ULEB-prefixed domain tag (audit F3 — two message types now exist)
// ‖ bcs(borrower:address)   32
// ‖ bcs(debt:u64)            8
// ‖ bcs(coll_amt:u64)        8
// ‖ bcs(loan_commit:u256)   32
// ‖ bcs(expiry_s:u64)        8   (audit F2.1 — temporal binding)
// ‖ bcs(pool_id:ID)         32   (audit F2.3 — domain separation across pools)
// ‖ bcs(collateral_type)   ULEB-prefixed ascii::String
// ‖ bcs(stable_type)       ULEB-prefixed ascii::String  (audit F2.3)
//
// The operator signs ONLY after dregg authorizes the loan, so a signature can never disburse
// un-approved terms — and now can only disburse them once, at one pool, within ~2 minutes.
import { bcs } from "@mysten/sui/bcs";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Ed25519PublicKey } from "@mysten/sui/keypairs/ed25519";
import { normalizeSuiAddress, normalizeStructTag } from "@mysten/sui/utils";

/** Must match `MAX_ATTEST_WINDOW_S` in async_lending.move. */
export const MAX_ATTEST_WINDOW_S = 120;

/** Domain tags — must match DOMAIN_DISBURSE / DOMAIN_LIQUIDATE in async_lending.move. Two
 *  different things are signed by the same operator key; without distinct prefixes a disburse
 *  attestation and a liquidation attestation could be reinterpreted as one another. */
const DOMAIN_DISBURSE = "ASSAY_DISBURSE_V1";
const DOMAIN_LIQUIDATE = "ASSAY_LIQUIDATE_V1";

/** bcs-encoded byte-vector (ULEB length prefix + bytes), matching Move's bcs::to_bytes(&vector<u8>). */
const tag = (s: string) => bcs.vector(bcs.u8()).serialize(Array.from(new TextEncoder().encode(s))).toBytes();

/** The Move `type_name` canonical form of a coin type: the struct tag with the 0x stripped. */
export function moveTypeName(coinType: string): string {
  const norm = normalizeStructTag(coinType);
  return norm.startsWith("0x") ? norm.slice(2) : norm;
}

export interface AttestationTerms {
  poolId: string;
  borrower: string;
  debt: bigint;
  collateralAmount: bigint;
  loanCommit: bigint;
  /** Unix seconds. The contract rejects `now > expiryS` and `expiryS > now + MAX_ATTEST_WINDOW_S`. */
  expiryS: bigint;
  collateralType: string;
  stableType: string;
}

export function attestationMessage(t: AttestationTerms): Uint8Array {
  const parts = [
    tag(DOMAIN_DISBURSE),
    bcs.Address.serialize(normalizeSuiAddress(t.borrower)).toBytes(), // 32
    bcs.u64().serialize(t.debt).toBytes(), // 8 LE
    bcs.u64().serialize(t.collateralAmount).toBytes(), // 8 LE
    bcs.u256().serialize(t.loanCommit).toBytes(), // 32 LE
    bcs.u64().serialize(t.expiryS).toBytes(), // 8 LE
    bcs.Address.serialize(normalizeSuiAddress(t.poolId)).toBytes(), // 32 — ID is a 32-byte address
    // Length-prefixed, NOT raw-appended: two variable-length tails concatenated are ambiguous
    // ("AB","C") == ("A","BC"), which would let one signature authorize a different type pair.
    bcs.string().serialize(moveTypeName(t.collateralType)).toBytes(),
    bcs.string().serialize(moveTypeName(t.stableType)).toBytes(),
  ];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

/** Raw ed25519 signature (64 bytes) over the attestation message. */
export async function signAttestation(
  operator: Ed25519Keypair,
  terms: AttestationTerms,
): Promise<Uint8Array> {
  return operator.sign(attestationMessage(terms));
}

/** The 32-byte raw ed25519 pubkey to pin in the pool (`operator_pubkey`). */
export function operatorPubkeyBytes(operator: Ed25519Keypair): Uint8Array {
  return operator.getPublicKey().toRawBytes();
}

/** Local verify (mirrors the on-chain `ed25519_verify`) — used in tests + defense-in-depth. */
export async function verifyAttestation(
  pubkey: Uint8Array,
  signature: Uint8Array,
  terms: AttestationTerms,
): Promise<boolean> {
  return new Ed25519PublicKey(pubkey).verify(attestationMessage(terms), signature);
}

/** Terms of ONE authorised liquidation. The operator decides health/price off-chain and signs the
 *  exact amount of collateral that may be seized; the contract refunds any surplus to the borrower. */
export interface LiquidationTerms {
  poolId: string;
  positionId: string;
  /** Base units of collateral the liquidator may take. The rest goes back to the borrower. */
  seizeAmount: bigint;
  expiryS: bigint;
  collateralType: string;
  stableType: string;
}

export function liquidationMessage(t: LiquidationTerms): Uint8Array {
  const parts = [
    tag(DOMAIN_LIQUIDATE),
    bcs.Address.serialize(normalizeSuiAddress(t.poolId)).toBytes(),
    bcs.Address.serialize(normalizeSuiAddress(t.positionId)).toBytes(),
    bcs.u64().serialize(t.seizeAmount).toBytes(),
    bcs.u64().serialize(t.expiryS).toBytes(),
    bcs.string().serialize(moveTypeName(t.collateralType)).toBytes(),
    bcs.string().serialize(moveTypeName(t.stableType)).toBytes(),
  ];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

export async function signLiquidation(operator: Ed25519Keypair, terms: LiquidationTerms): Promise<Uint8Array> {
  return operator.sign(liquidationMessage(terms));
}
