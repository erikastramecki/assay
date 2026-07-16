import { useEffect, useState } from "react";

const HERMES = "https://hermes.pyth.network/v2/updates/price/latest";

export interface Price {
  price: number; // human units (price · 10^expo)
  conf: number;
  publishTime: number;
  ageSec: number;
}

/** One-shot fetch of latest prices for a set of feed ids. */
export async function fetchPrices(feedIds: string[]): Promise<Record<string, Price>> {
  const qs = feedIds.map((id) => `ids[]=${id.startsWith("0x") ? id.slice(2) : id}`).join("&");
  const res = await fetch(`${HERMES}?${qs}`);
  if (!res.ok) throw new Error(`Hermes ${res.status}`);
  const j = await res.json();
  const now = Date.now() / 1000;
  const out: Record<string, Price> = {};
  for (const p of j.parsed ?? []) {
    const expo = p.price.expo as number;
    const scale = Math.pow(10, expo);
    out["0x" + p.id] = {
      price: Number(p.price.price) * scale,
      conf: Number(p.price.conf) * scale,
      publishTime: p.price.publish_time,
      ageSec: Math.max(0, Math.floor(now - p.price.publish_time)),
    };
  }
  return out;
}

/** Poll live prices for the given feed ids every `ms`. Keyed by feed id. */
export function usePythPrices(feedIds: string[], ms = 4000): { prices: Record<string, Price>; ok: boolean } {
  const [prices, setPrices] = useState<Record<string, Price>>({});
  const [ok, setOk] = useState(true);
  const key = feedIds.join(",");
  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try { const p = await fetchPrices(feedIds); if (alive) { setPrices(p); setOk(true); } }
      catch { if (alive) setOk(false); }
    };
    tick();
    const t = setInterval(tick, ms);
    return () => { alive = false; clearInterval(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, ms]);
  return { prices, ok };
}

/** US equity regular session (≈9:30–16:00 ET, Mon–Fri) — for the market-hours pill. */
export function isUsMarketHours(d = new Date()): boolean {
  const et = new Date(d.getTime() - 4 * 3600_000); // EDT approx
  const dow = et.getUTCDay();
  if (dow === 0 || dow === 6) return false;
  const mins = et.getUTCHours() * 60 + et.getUTCMinutes();
  return mins >= 9 * 60 + 30 && mins <= 16 * 60;
}
