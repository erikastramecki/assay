// Object readers: decode the on-chain Pool + Positions for the UI.
import type { SuiClient } from "@mysten/sui/client";
import { normalizeSuiAddress } from "@mysten/sui/utils";
import { MODULE } from "./constants.js";

export interface PoolView {
  id: string;
  liquidity: bigint; // idle cash (stable base units)
  totalShares: bigint;
  totalBorrows: bigint;
  totalReserves: bigint;
  borrowIndex: bigint; // 1e18 fixed
  // utilization-based ("kinked") interest curve, all in bps
  baseBps: number;
  slope1Bps: number;
  slope2Bps: number;
  kinkBps: number;
  reserveBps: number;
  lastAccrualS: bigint;
  cap: bigint;
  perCollateralCap: bigint;
  totalPending: bigint;
  batchRoot: bigint;
  sharesTableId: string;
}

export interface PositionView {
  id: string;
  /** The pool this position is bound to. repay/liquidate abort with EWrongPool against any other. */
  poolId: string;
  borrower: string;
  principal: bigint;
  indexSnapshot: bigint;
  batchId: bigint;
  collateral: bigint;
  collateralType: string; // the Collateral type param, e.g. 0x…::tbtc::TBTC (for repay + display)
}

const fields = (o: any): any => o?.data?.content?.fields;

export async function readPool(client: SuiClient, poolId: string): Promise<PoolView> {
  const o = await client.getObject({ id: poolId, options: { showContent: true } });
  const f = fields(o);
  if (!f) throw new Error(`pool ${poolId} not found`);
  const shares = f.shares?.fields?.id?.id ?? f.shares?.id?.id ?? f.shares?.id;
  return {
    id: poolId,
    liquidity: BigInt(f.liquidity),
    totalShares: BigInt(f.total_shares),
    totalBorrows: BigInt(f.total_borrows),
    totalReserves: BigInt(f.total_reserves),
    borrowIndex: BigInt(f.borrow_index),
    baseBps: Number(f.base_bps),
    slope1Bps: Number(f.slope1_bps),
    slope2Bps: Number(f.slope2_bps),
    kinkBps: Number(f.kink_bps),
    reserveBps: Number(f.reserve_bps),
    lastAccrualS: BigInt(f.last_accrual_s),
    cap: BigInt(f.cap),
    perCollateralCap: BigInt(f.per_collateral_cap),
    totalPending: BigInt(f.total_pending),
    batchRoot: BigInt(f.batch_root),
    sharesTableId: shares,
  };
}

/** A lender's shares from the pool's `shares` Table (a dynamic field keyed by address). */
export async function sharesOf(client: SuiClient, sharesTableId: string, addr: string): Promise<bigint> {
  try {
    const r = await client.getDynamicFieldObject({
      parentId: sharesTableId,
      name: { type: "address", value: normalizeSuiAddress(addr) },
    });
    const f = fields(r);
    return f ? BigInt(f.value) : 0n;
  } catch {
    return 0n;
  }
}

/** ALL live positions in the pool (for the liquidation keeper) — every LoanOpened, still-open. */
export async function allOpenPositions(client: SuiClient, pkg: string, poolId?: string): Promise<PositionView[]> {
  return positionsFromEvents(client, pkg, null, poolId);
}

/** Discover a borrower's live positions via the `LoanOpened` event (positions are shared). */
export async function findPositions(client: SuiClient, pkg: string, borrower: string, poolId?: string): Promise<PositionView[]> {
  return positionsFromEvents(client, pkg, normalizeSuiAddress(borrower), poolId);
}

// `poolId` filters to one pool. Positions are bound to their pool on-chain (repay/liquidate abort
// with EWrongPool against any other), so listing across pools yields entries the caller can only
// fail to act on. Optional so existing all-pools callers (the keeper) keep working.
async function positionsFromEvents(client: SuiClient, pkg: string, borrower: string | null, poolId?: string): Promise<PositionView[]> {
  const evs = await client.queryEvents({
    query: { MoveEventType: `${pkg}::${MODULE}::LoanOpened` },
    limit: 500,
    order: "descending",
  });
  const ids = [
    ...new Set(
      evs.data
        .filter((e) => borrower === null || normalizeSuiAddress((e.parsedJson as any).borrower) === borrower)
        .filter((e) => !poolId || normalizeSuiAddress((e.parsedJson as any).pool) === normalizeSuiAddress(poolId))
        .map((e) => (e.parsedJson as any).position as string),
    ),
  ];
  const out: PositionView[] = [];
  for (const id of ids) {
    const o = await client.getObject({ id, options: { showContent: true, showType: true } });
    const f = fields(o);
    if (!f) continue; // repaid/liquidated → object deleted
    // Position<Collateral, Stable> — pull the Collateral type param for repay + display
    const t = (o.data as any)?.type || (o.data as any)?.content?.type || "";
    const collateralType = t.match(/Position<([^,]+),/)?.[1]?.trim() ?? "";
    out.push({
      id,
      borrower: normalizeSuiAddress(f.borrower),
      poolId: normalizeSuiAddress(f.pool_id),
      principal: BigInt(f.principal),
      indexSnapshot: BigInt(f.index_snapshot),
      batchId: BigInt(f.batch_id),
      collateral: BigInt(f.collateral),
      collateralType,
    });
  }
  return out;
}
