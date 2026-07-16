// Borrow-index interest math — mirrors the Move `accrue` / `borrow_rate_bps` / `debt_now`, for UI.
import type { PoolView, PositionView } from "./objects.js";

const BPS = 10_000n;
const SECS_PER_YEAR = 31_536_000n;

type Curve = Pick<PoolView, "baseBps" | "slope1Bps" | "slope2Bps" | "kinkBps">;
type Util = Pick<PoolView, "liquidity" | "totalBorrows">;

/** Utilization in bps: U = borrows / (cash + borrows). */
export function utilizationBps(pool: Util): bigint {
  const assets = pool.liquidity + pool.totalBorrows;
  return assets === 0n ? 0n : (pool.totalBorrows * BPS) / assets;
}

/** Current borrow APR in bps from the kinked curve (mirrors the on-chain `borrow_rate_bps`). */
export function borrowRateBps(pool: Curve & Util): number {
  const u = utilizationBps(pool);
  const kink = BigInt(pool.kinkBps);
  if (u <= kink) return Number(BigInt(pool.baseBps) + (BigInt(pool.slope1Bps) * u) / kink);
  const span = BPS - kink;
  return Number(BigInt(pool.baseBps) + BigInt(pool.slope1Bps) + (BigInt(pool.slope2Bps) * (u - kink)) / span);
}

/** Supply APY (%) = borrowAPR · utilization · (1 − reserveFactor). */
export function supplyApyPct(pool: Curve & Util & Pick<PoolView, "reserveBps">): number {
  const borrowApr = borrowRateBps(pool) / 10_000; // fraction
  const u = Number(utilizationBps(pool)) / 10_000;
  return borrowApr * u * (1 - pool.reserveBps / 10_000) * 100;
}

/** Project the borrow index forward to `nowS` at the CURRENT utilization-based rate. */
export function accrueIndex(pool: Curve & Util & Pick<PoolView, "borrowIndex" | "lastAccrualS">, nowS: bigint): bigint {
  if (nowS > pool.lastAccrualS && pool.totalBorrows > 0n) {
    const dt = nowS - pool.lastAccrualS;
    const denom = BPS * SECS_PER_YEAR;
    const num = denom + BigInt(borrowRateBps(pool)) * dt;
    return (pool.borrowIndex * num) / denom;
  }
  return pool.borrowIndex;
}

/** Current debt owed = principal · indexNow / indexSnapshot. */
export function currentDebt(pos: Pick<PositionView, "principal" | "indexSnapshot">, indexNow: bigint): bigint {
  return (pos.principal * indexNow) / pos.indexSnapshot;
}

/** Value of `shares` in stable base units against current lender assets. */
export function sharesToAssets(shares: bigint, totalShares: bigint, totalAssets: bigint): bigint {
  if (totalShares === 0n) return 0n;
  return (shares * totalAssets) / totalShares;
}

/** Lenders' claim on the pool = cash + borrows − reserves (mirrors on-chain `total_assets`). */
export function lenderAssets(pool: Pick<PoolView, "liquidity" | "totalBorrows" | "totalReserves">): bigint {
  const claim = pool.liquidity + pool.totalBorrows;
  return claim > pool.totalReserves ? claim - pool.totalReserves : 0n;
}

export function utilization(pool: Util): number {
  return Number(utilizationBps(pool)) / 10_000;
}
