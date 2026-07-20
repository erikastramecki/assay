// PTB builders for dregg_lending_async. Each adds Move call(s) to a Transaction.
// KEY: functions returning a Coin (withdraw/repay/liquidate) MUST transfer the result,
// or the PTB fails `UnusedValueWithoutDrop`. These builders do that for you.
import type { Transaction, TransactionArgument } from "@mysten/sui/transactions";
import { CLOCK_ID, target } from "./constants.js";

export interface RateCurve { baseBps: number; slope1Bps: number; slope2Bps: number; kinkBps: number; reserveBps: number }

export function initPool(
  tx: Transaction,
  o: { pkg: string; stableType: string; curve: RateCurve; cap: bigint; perCollateralCap: bigint; vk: Uint8Array; operatorPubkey: Uint8Array },
) {
  const c = o.curve;
  tx.moveCall({
    target: target(o.pkg, "init_pool"),
    typeArguments: [o.stableType],
    arguments: [
      tx.pure.u64(c.baseBps), tx.pure.u64(c.slope1Bps), tx.pure.u64(c.slope2Bps), tx.pure.u64(c.kinkBps), tx.pure.u64(c.reserveBps),
      tx.pure.u64(o.cap), tx.pure.u64(o.perCollateralCap),
      tx.pure.vector("u8", Array.from(o.vk)),
      tx.pure.vector("u8", Array.from(o.operatorPubkey)),
      tx.object(CLOCK_ID),
    ],
  });
}

/** Governance: retune the interest curve on a live pool (OperatorCap-gated). */
export function setRateCurve(
  tx: Transaction,
  o: { pkg: string; stableType: string; cap: string; pool: string; curve: RateCurve },
) {
  const c = o.curve;
  tx.moveCall({
    target: target(o.pkg, "set_rate_curve"),
    typeArguments: [o.stableType],
    arguments: [
      tx.object(o.cap), tx.object(o.pool),
      tx.pure.u64(c.baseBps), tx.pure.u64(c.slope1Bps), tx.pure.u64(c.slope2Bps), tx.pure.u64(c.kinkBps), tx.pure.u64(c.reserveBps),
      tx.object(CLOCK_ID),
    ],
  });
}

export function deposit(
  tx: Transaction,
  o: { pkg: string; stableType: string; pool: string; coin: TransactionArgument },
) {
  tx.moveCall({
    target: target(o.pkg, "deposit"),
    typeArguments: [o.stableType],
    arguments: [tx.object(o.pool), o.coin, tx.object(CLOCK_ID)],
  });
}

export function withdraw(
  tx: Transaction,
  o: { pkg: string; stableType: string; pool: string; shares: bigint; recipient: string },
) {
  const out = tx.moveCall({
    target: target(o.pkg, "withdraw"),
    typeArguments: [o.stableType],
    arguments: [tx.object(o.pool), tx.pure.u64(o.shares), tx.object(CLOCK_ID)],
  });
  tx.transferObjects([out], o.recipient);
}

export function disburseAttested(
  tx: Transaction,
  o: {
    pkg: string; collType: string; stableType: string; pool: string;
    collateralCoin: TransactionArgument; debt: bigint; loanCommit: bigint;
    /** Unix seconds; must match the signed attestation and be within MAX_ATTEST_WINDOW_S. */
    expiryS: bigint; attestation: Uint8Array;
  },
) {
  tx.moveCall({
    target: target(o.pkg, "disburse_attested"),
    typeArguments: [o.collType, o.stableType],
    arguments: [
      tx.object(o.pool),
      o.collateralCoin,
      tx.pure.u64(o.debt),
      tx.pure.u256(o.loanCommit),
      tx.pure.u64(o.expiryS),
      tx.pure.vector("u8", Array.from(o.attestation)),
      tx.object(CLOCK_ID),
    ],
  });
}

export function repay(
  tx: Transaction,
  o: { pkg: string; collType: string; stableType: string; pool: string; position: string; paymentCoin: TransactionArgument; recipient: string },
) {
  const coll = tx.moveCall({
    target: target(o.pkg, "repay"),
    typeArguments: [o.collType, o.stableType],
    arguments: [tx.object(o.pool), tx.object(o.position), o.paymentCoin, tx.object(CLOCK_ID)],
  });
  tx.transferObjects([coll], o.recipient);
}

/** Operator-attested liquidation of an underwater position. Returns the seized collateral to the caller. */
export function liquidate(
  tx: Transaction,
  o: { pkg: string; collType: string; stableType: string; cap: string; pool: string; position: string; paymentCoin: TransactionArgument; recipient: string },
) {
  const coll = tx.moveCall({
    target: target(o.pkg, "liquidate"),
    typeArguments: [o.collType, o.stableType],
    arguments: [tx.object(o.cap), tx.object(o.pool), tx.object(o.position), o.paymentCoin, tx.object(CLOCK_ID)],
  });
  tx.transferObjects([coll], o.recipient);
}

export function settleBatch(
  tx: Transaction,
  o: { pkg: string; stableType: string; pool: string; proof: Uint8Array },
) {
  tx.moveCall({
    target: target(o.pkg, "settle_batch"),
    typeArguments: [o.stableType],
    arguments: [tx.object(o.pool), tx.pure.vector("u8", Array.from(o.proof))],
  });
}
