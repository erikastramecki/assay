import { useCallback, useEffect, useState } from "react";
import { useSuiClient, useCurrentAccount, useSignAndExecuteTransaction } from "@mysten/dapp-kit";
import { Transaction } from "@mysten/sui/transactions";
import { fromHex } from "@mysten/sui/utils";
import {
  ptb, exactCoin, readPool, sharesOf, findPositions,
  accrueIndex, currentDebt, sharesToAssets, utilization, supplyApyPct, borrowRateBps, lenderAssets,
} from "@assay/sui-sdk";
import { PKG, POOL_ID, STABLE_TYPE, STABLE_UNIT, OPERATOR_API, poolReady, borrowReady } from "./config";
import { marketByCoinType } from "./markets";
import { normalizeSuiAddress } from "@mysten/sui/utils";

// ---- Governance transparency: on-chain rate-change history + protocol reserves + isolation cap ----
export interface CurveEvent { base: number; slope1: number; slope2: number; kink: number; reserve: number; ts: number; digest: string }
export function useGovernance() {
  const client = useSuiClient();
  const [events, setEvents] = useState<CurveEvent[]>([]);
  const [reserves, setReserves] = useState(0);
  const [perCollateralCap, setPerCollateralCap] = useState(0);
  const refresh = useCallback(async () => {
    if (!poolReady()) return;
    try {
      const evs = await client.queryEvents({ query: { MoveEventType: `${PKG}::async_lending::CurveUpdated` }, limit: 50, order: "descending" });
      const mine = normalizeSuiAddress(POOL_ID!);
      setEvents(evs.data.filter((e) => normalizeSuiAddress((e.parsedJson as any).pool) === mine).map((e) => {
        const j = e.parsedJson as any;
        return { base: +j.base_bps, slope1: +j.slope1_bps, slope2: +j.slope2_bps, kink: +j.kink_bps, reserve: +j.reserve_bps, ts: Number(e.timestampMs || 0), digest: e.id.txDigest };
      }));
      const p = await readPool(client, POOL_ID!);
      setReserves(Number(p.totalReserves) / STABLE_UNIT);
      setPerCollateralCap(Number(p.perCollateralCap) / STABLE_UNIT);
    } catch { /* keep last */ }
  }, [client]);
  useEffect(() => { refresh(); const t = setInterval(refresh, 15000); window.addEventListener("assay:refresh", refresh); return () => { clearInterval(t); window.removeEventListener("assay:refresh", refresh); }; }, [refresh]);
  return { events, reserves, perCollateralCap };
}

export interface RateCurveView { baseBps: number; slope1Bps: number; slope2Bps: number; kinkBps: number; reserveBps: number }
export interface PoolView {
  ready: boolean;
  cash: number; borrows: number; totalAssets: number; reserves: number;
  utilization: number; apyPct: number; borrowApr: number;
  curve: RateCurveView;
  myShares: number; myValue: number;
}
const ZERO_CURVE: RateCurveView = { baseBps: 0, slope1Bps: 0, slope2Bps: 0, kinkBps: 8000, reserveBps: 0 };
const EMPTY: PoolView = { ready: false, cash: 0, borrows: 0, totalAssets: 0, reserves: 0, utilization: 0, apyPct: 0, borrowApr: 0, curve: ZERO_CURVE, myShares: 0, myValue: 0 };

const nowS = () => BigInt(Math.floor(Date.now() / 1000));

export function usePool() {
  const client = useSuiClient();
  const account = useCurrentAccount();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const [view, setView] = useState<PoolView>(EMPTY);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(async () => {
    if (!poolReady()) { setView(EMPTY); return; }
    try {
      const pool = await readPool(client, POOL_ID!);
      const assets = lenderAssets(pool); // cash + borrows − reserves (lenders' claim)
      let myShares = 0n;
      if (account) myShares = await sharesOf(client, pool.sharesTableId, account.address);
      setView({
        ready: true,
        cash: Number(pool.liquidity) / STABLE_UNIT,
        borrows: Number(pool.totalBorrows) / STABLE_UNIT,
        totalAssets: Number(assets) / STABLE_UNIT,
        reserves: Number(pool.totalReserves) / STABLE_UNIT,
        utilization: utilization(pool),
        apyPct: supplyApyPct(pool),        // net supply APY (borrowAPR · util · (1−reserve))
        borrowApr: borrowRateBps(pool) / 100,
        curve: { baseBps: pool.baseBps, slope1Bps: pool.slope1Bps, slope2Bps: pool.slope2Bps, kinkBps: pool.kinkBps, reserveBps: pool.reserveBps },
        myShares: Number(myShares) / STABLE_UNIT,
        myValue: Number(sharesToAssets(myShares, pool.totalShares, assets)) / STABLE_UNIT,
      });
    } catch { setView(EMPTY); }
  }, [client, account]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 8000);
    window.addEventListener("assay:refresh", refresh);
    return () => { clearInterval(t); window.removeEventListener("assay:refresh", refresh); };
  }, [refresh]);

  const run = useCallback(async (build: (tx: Transaction) => Promise<void> | void) => {
    if (!account) throw new Error("connect a wallet");
    setBusy(true);
    try {
      const tx = new Transaction();
      await build(tx);
      const r = await signAndExecute({ transaction: tx });
      await client.waitForTransaction({ digest: r.digest });
      window.dispatchEvent(new Event("assay:refresh"));
      return r.digest;
    } finally { setBusy(false); }
  }, [account, client, signAndExecute]);

  const deposit = useCallback((amountUi: number) => run(async (tx) => {
    const coin = await exactCoin(tx, client, account!.address, STABLE_TYPE, BigInt(Math.round(amountUi * STABLE_UNIT)));
    ptb.deposit(tx, { pkg: PKG!, stableType: STABLE_TYPE, pool: POOL_ID!, coin });
  }), [run, client, account]);

  const withdraw = useCallback((sharesUi: number) => run((tx) => {
    ptb.withdraw(tx, { pkg: PKG!, stableType: STABLE_TYPE, pool: POOL_ID!, shares: BigInt(Math.round(sharesUi * STABLE_UNIT)), recipient: account!.address });
  }), [run, account]);

  return { view, busy, refresh, deposit, withdraw };
}

/** Borrow via the Operator API: it dregg-authorizes + returns an ed25519 attestation; the
 *  borrower's wallet sends `disburse_attested` supplying their own collateral (non-custodial). */
export function useBorrow() {
  const client = useSuiClient();
  const account = useCurrentAccount();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const [busy, setBusy] = useState(false);
  const canBorrow = borrowReady();

  const borrow = useCallback(async (args: { collateralType: string; collateralDecimals: number; collateralUnits: number; debtUsdc: number }) => {
    if (!account) throw new Error("connect a wallet");
    if (!borrowReady()) throw new Error("borrow not configured (missing markets/pool)");
    setBusy(true);
    try {
      const res = await fetch(OPERATOR_API + "/borrow", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({
          borrower: account.address, collateralMint: args.collateralType,
          collateralAmount: Math.round(args.collateralUnits * 10 ** args.collateralDecimals),
          debtUsdc: args.debtUsdc,
        }),
      });
      const j = await res.json();
      if (!res.ok) throw new Error(j.detail || j.error || "borrow refused");
      const tx = new Transaction();
      const coll = await exactCoin(tx, client, account.address, args.collateralType, BigInt(j.collateralBase));
      // The attestation is short-lived (audit F2): the operator prices it at signing time and the
      // contract rejects it past `expiryS`. If the user sits on the wallet prompt it expires and
      // the tx aborts with EAttestExpired — surface that as a retry rather than a cryptic failure.
      const expiryS = BigInt(j.expiryS);
      if (BigInt(Math.floor(Date.now() / 1000)) >= expiryS) {
        throw new Error("quote expired before signing — please try again");
      }
      ptb.disburseAttested(tx, {
        pkg: PKG!, collType: args.collateralType, stableType: STABLE_TYPE, pool: POOL_ID!,
        collateralCoin: coll, debt: BigInt(j.debtBase), loanCommit: BigInt(j.loanCommit),
        expiryS, attestation: fromHex(j.attestation),
      });
      const r = await signAndExecute({ transaction: tx });
      await client.waitForTransaction({ digest: r.digest });
      window.dispatchEvent(new Event("assay:refresh"));
      return r.digest;
    } finally { setBusy(false); }
  }, [account, client, signAndExecute]);

  return { borrow, busy, canBorrow };
}

/** Devnet faucet: mint test USDC + every collateral coin to the connected wallet. */
export function useFaucet() {
  const account = useCurrentAccount();
  const [busy, setBusy] = useState(false);
  const drip = useCallback(async (coinType?: string) => {
    if (!account) throw new Error("connect a wallet");
    setBusy(true);
    try {
      const r = await fetch(OPERATOR_API + "/faucet", {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ address: account.address, coinType }),
      });
      const j = await r.json();
      if (!r.ok) throw new Error(j.error || "faucet failed");
      window.dispatchEvent(new Event("assay:refresh"));
      return j.digest as string;
    } finally { setBusy(false); }
  }, [account]);
  return { drip, busy, ready: !!account };
}

export interface PositionView {
  id: string;
  collateralType: string;
  collateralDecimals: number;
  symbol: string;
  collateralRaw: bigint;
  debt: number; // current debt in stable (human)
}

/** The connected borrower's open positions + a wallet-signed repay. */
export function usePositions() {
  const client = useSuiClient();
  const account = useCurrentAccount();
  const { mutateAsync: signAndExecute } = useSignAndExecuteTransaction();
  const [positions, setPositions] = useState<PositionView[]>([]);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(async () => {
    if (!poolReady() || !account) { setPositions([]); return; }
    try {
      const pool = await readPool(client, POOL_ID!);
      const idx = accrueIndex(pool, nowS());
      const found = await findPositions(client, PKG!, account.address);
      setPositions(found.map((f) => ({
        id: f.id,
        collateralType: f.collateralType,
        collateralDecimals: marketByCoinType(f.collateralType)?.decimals ?? 8,
        symbol: marketByCoinType(f.collateralType)?.symbol ?? f.collateralType.split("::").pop() ?? "collateral",
        collateralRaw: f.collateral,
        debt: Number(currentDebt(f, idx)) / STABLE_UNIT,
      })));
    } catch { setPositions([]); }
  }, [client, account]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 8000);
    window.addEventListener("assay:refresh", refresh);
    return () => { clearInterval(t); window.removeEventListener("assay:refresh", refresh); };
  }, [refresh]);

  const repay = useCallback(async (pos: PositionView) => {
    if (!account || !poolReady()) throw new Error("connect a wallet");
    setBusy(true);
    try {
      const pool = await readPool(client, POOL_ID!);
      const idx = accrueIndex(pool, nowS());
      // exact owed (rate=0 demo pool → owed == principal, deterministic)
      const owed = BigInt(Math.round(pos.debt * STABLE_UNIT));
      const tx = new Transaction();
      const pay = await exactCoin(tx, client, account.address, STABLE_TYPE, owed);
      ptb.repay(tx, { pkg: PKG!, collType: pos.collateralType, stableType: STABLE_TYPE, pool: POOL_ID!, position: pos.id, paymentCoin: pay, recipient: account.address });
      const r = await signAndExecute({ transaction: tx });
      await client.waitForTransaction({ digest: r.digest });
      await refresh();
      window.dispatchEvent(new Event("assay:refresh"));
      return r.digest;
    } finally { setBusy(false); }
  }, [account, client, signAndExecute, refresh]);

  return { positions, busy, repay, refresh };
}
