// Pyth oracle for the RWA operator — fetch + discipline (audit Part A).
//
// The oracle is the solvency trust root: the proof attests authorization integrity,
// not price honesty. This module is the operator's FAIL-CLOSED pre-kernel gate; the
// dregg borrow turn ALSO enforces conf-ceiling + freshness as provable caveats, so
// these two layers agree (defense in depth). Pyth is a first-party aggregated oracle
// (publishers sign) — no DEX-TWAP flash-loan surface — but RWA equity feeds carry the
// 24/7-token-vs-9:30–16:00-underlying GAP risk, so staleness is the real killer.
//
// Hermes REST: GET /v2/updates/price/latest?ids[]=<feedId>  → parsed[].price
//   { price (i64 string), conf (u64 string), expo (i32), publish_time (unix secs) }

const HERMES = "https://hermes.pyth.network/v2/updates/price/latest";

/** Fetch the latest Pyth price for a feed id (0x… 32-byte hex). Throws on network/absence. */
export async function fetchPythPrice(feedId, { timeoutMs = 4000 } = {}) {
  const id = feedId.startsWith("0x") ? feedId.slice(2) : feedId;
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(`${HERMES}?ids[]=${id}`, { signal: ctl.signal });
    if (!res.ok) throw new Error(`Hermes ${res.status}`);
    const j = await res.json();
    const p = j?.parsed?.[0]?.price;
    if (!p) throw new Error("no price in Hermes response");
    return { price: BigInt(p.price), conf: BigInt(p.conf), expo: p.expo, publishTime: p.publish_time };
  } finally {
    clearTimeout(t);
  }
}

/** US equity regular session ≈ 9:30–16:00 ET, Mon–Fri. Coarse (no holidays/DST edge);
 *  off-session we apply a TIGHTER staleness bound + wider gap buffer per Part A. */
export function isUsMarketHours(nowMs) {
  // ET = UTC−5 (EST) / −4 (EDT); use −4 as the conservative (wider-day) approximation.
  const et = new Date(nowMs - 4 * 3600_000);
  const dow = et.getUTCDay(); // 0 Sun … 6 Sat
  if (dow === 0 || dow === 6) return false;
  const mins = et.getUTCHours() * 60 + et.getUTCMinutes();
  return mins >= 9 * 60 + 30 && mins <= 16 * 60;
}

/**
 * The operator's oracle gate. Returns { ok, reason, price, conf, age, marketHours }.
 * Fail-closed on: absent/zero price, staleness (tighter off-hours), wide confidence,
 * and a large-move circuit breaker vs the last accepted price.
 * `price`/`conf` are returned as positive integer magnitudes at the feed's own scale
 * (expo folded out to whole units where possible) for handoff to dregg_borrow.
 */
export function applyOraclePolicy(feed, opts = {}) {
  const {
    nowMs = null,                    // caller injects (deterministic in tests)
    maxStaleSecs = 60,               // regular-session freshness
    maxStaleOffHoursSecs = 15,       // off-session: much tighter (gap risk)
    maxConfBps = 100,                // reject if conf/price > 1%
    breakerPct = 20,                 // reject if |move| vs last accepted > 20%
    lastPrice = null,                // last accepted price (same scale) or null
    assetClass = "equity",           // "crypto" = 24/7 (no off-hours tightening); "equity" = session-aware
  } = opts;
  const now = nowMs == null ? dateNow() : nowMs;
  const targetExpo = opts.targetExpo ?? -2; // fold to cents so the confidence band survives

  // rescale Pyth's (value, expo) to fixed target-scale integer units.
  const shift = feed.expo - targetExpo;
  const rescale = (v) => shift >= 0 ? v * 10n ** BigInt(shift) : v / 10n ** BigInt(-shift);
  const priceRaw = feed.price < 0n ? 0n : feed.price;
  const price = rescale(priceRaw);
  const conf = rescale(feed.conf);

  if (price <= 0n) return { ok: false, reason: "oracle price absent/zero (fail-closed)", price: 0n, conf, age: 0 };

  const age = Math.max(0, Math.floor(now / 1000) - Number(feed.publishTime));
  // crypto trades 24/7 → always "in session" (no off-hours gap to guard). Equity is session-aware:
  // off the US session the underlying is closed while the token trades, so tighten staleness.
  const marketHours = assetClass === "crypto" ? true : isUsMarketHours(now);
  const staleLimit = marketHours ? maxStaleSecs : maxStaleOffHoursSecs;
  if (age > staleLimit)
    return { ok: false, reason: `stale ${age}s > ${staleLimit}s (${marketHours ? "session" : "off-hours"})`, price, conf, age, marketHours };

  // confidence at bps precision (mirror the kernel caveat)
  if (conf * 10000n > price * BigInt(maxConfBps))
    return { ok: false, reason: `confidence ${conf}/${price} > ${maxConfBps}bps`, price, conf, age, marketHours };

  // large-move circuit breaker vs the last accepted price
  if (lastPrice != null && lastPrice > 0n) {
    const diff = price > lastPrice ? price - lastPrice : lastPrice - price;
    if (diff * 100n > lastPrice * BigInt(breakerPct))
      return { ok: false, reason: `circuit breaker: moved >${breakerPct}% vs last ${lastPrice}`, price, conf, age, marketHours };
  }
  return { ok: true, reason: "ok", price, conf, age, marketHours, staleLimit, maxConfBps };
}

// Date.now indirection so tests can stub deterministically.
function dateNow() { return Date.now(); }
