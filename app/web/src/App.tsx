import { useMemo, useState, useEffect } from "react";
import { ConnectButton, useCurrentAccount } from "@mysten/dapp-kit";
import { MARKETS, chip, type Market } from "./markets";
import { usePythPrices, isUsMarketHours } from "./pyth";
import { usePool, usePositions, useBorrow, useFaucet, useGovernance } from "./pool";
import { marked } from "marked";
import { DOCS, type Doc } from "./docs.generated";

const usd = (n: number, d = 2) => "$" + n.toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });

// A short, curated set shown by default; everything else is one search away (scales as we add assets).
const FEATURED = ["BTC", "ETH", "SOL", "SUI", "HYPE", "NVDA", "AAPL", "TSLA", "SPY", "COIN"];
const ETF = new Set(["SPY", "QQQ", "VTI", "VOO", "GLD"]);
type Cat = "all" | "crypto" | "stocks" | "etfs";
const CATS: { id: Cat; label: string }[] = [
  { id: "all", label: "All" }, { id: "crypto", label: "Crypto" }, { id: "stocks", label: "Stocks" }, { id: "etfs", label: "ETFs" },
];
const featuredMarkets = () => FEATURED.map((s) => MARKETS.find((m) => m.symbol === s)).filter(Boolean) as Market[];
const inCat = (m: Market, c: Cat) =>
  c === "all" ? true : c === "crypto" ? m.assetClass === "crypto" : c === "etfs" ? ETF.has(m.symbol) : m.assetClass === "equity" && !ETF.has(m.symbol);
function filterMarkets(q: string, c: Cat): Market[] {
  const Q = q.trim().toUpperCase();
  if (!Q && c === "all") return featuredMarkets();
  return MARKETS.filter((m) => inCat(m, c) && (!Q || m.symbol.includes(Q) || m.name.toUpperCase().includes(Q)));
}
const uniqueFeeds = (ms: Market[]) => [...new Set(ms.map((m) => m.feedId))];

export default function App() {
  const connected = !!useCurrentAccount();
  const session = isUsMarketHours();
  const net = (import.meta.env.VITE_SUI_NETWORK || "devnet").toLowerCase();
  const cluster = "Sui " + (net.charAt(0).toUpperCase() + net.slice(1));

  const [selSym, setSel] = useState<string>("BTC");
  const sel = MARKETS.find((m) => m.symbol === selSym) ?? MARKETS[0];

  // markets search/filter — short featured list by default, search to find any of the {MARKETS.length}
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<Cat>("all");
  const shown = useMemo(() => filterMarkets(query, category), [query, category]);

  // poll prices ONLY for what's on screen (featured + selected + current results) — bounded as we scale
  const feedIds = useMemo(() => uniqueFeeds([sel, ...featuredMarkets(), ...shown]), [sel, shown]);
  const { prices, ok } = usePythPrices(feedIds);
  const selPx = prices[sel.feedId]?.price ?? 0;
  const selConf = prices[sel.feedId]?.conf ?? 0;
  const [menuOpen, setMenuOpen] = useState(false);
  const NAV = [["markets", "Markets"], ["borrow", "Borrow"], ["earn", "Earn"], ["governance", "Governance"], ["docs", "Docs"], ["proof", "Proof"]];

  return (
    <>
      <header className="nav">
        <div className="wrap nav-in">
          <a className="brand" href="#top"><Hallmark /> <span><b>Assay</b></span></a>
          <nav className="nav-links">
            {NAV.map(([id, label]) => <a key={id} href={`#${id}`}>{label}</a>)}
          </nav>
          <div className="nav-right">
            <span className="net"><span className="dot" style={{ background: ok ? "var(--good)" : "var(--warn)" }} />{cluster}</span>
            {connected && <FaucetButton />}
            <ConnectButton />
            <button className="nav-burger" aria-label="menu" aria-expanded={menuOpen} onClick={() => setMenuOpen((o) => !o)}>{menuOpen ? "✕" : "☰"}</button>
          </div>
        </div>
        {menuOpen && (
          <nav className="nav-mobile" onClick={() => setMenuOpen(false)}>
            {NAV.map(([id, label]) => <a key={id} href={`#${id}`}>{label}</a>)}
          </nav>
        )}
      </header>

      <main id="top">
        {/* HERO */}
        <section className="hero">
          <div className="wrap hero-grid">
            <div>
              <span className="badge"><Shield /> Every loan assayed · proof-gated settlement</span>
              <h1>Borrow against your <em>onchain assets</em> — proven safe, not promised.</h1>
              <p className="lede">Post 68 markets of collateral — crypto (BTC, ETH, SOL, SUI…) or tokenized stocks (xStocks) — and draw USDC in one transaction. Each borrow is authorized by a formally-verified risk kernel and settled against a proof.</p>
              <div className="hero-cta">
                <a className="btn btn-gold" href="#borrow">Open a position</a>
                <a className="btn btn-ghost" href="#markets">View markets</a>
              </div>
            </div>
            <aside className="plate">
              <div className="plate-top">
                <span className="eyebrow">Collateral · Pyth oracle</span>
                <span className="status-pill"><span className="bar" />{session ? "US markets open" : "US markets closed"}</span>
              </div>
              <div className="ticker">
                {MARKETS.slice(0, 5).map((m) => {
                  const p = prices[m.feedId];
                  return (
                    <div className="ticker-row" key={m.symbol}>
                      <span className="sym">{m.symbol}<span>{m.name}</span></span>
                      <span className="px num">{p ? usd(p.price, m.assetClass === "crypto" && p.price > 1000 ? 0 : 2) : "…"}</span>
                      <span className="chg" style={{ color: "var(--tx-faint)" }}>{p ? `${p.ageSec}s` : ""}</span>
                    </div>
                  );
                })}
              </div>
            </aside>
          </div>
        </section>

        {/* MARKETS */}
        <section className="band" id="markets">
          <div className="wrap">
            <div className="band-head">
              <div>
                <span className="eyebrow">Markets</span>
                <h2>Collateral, priced live</h2>
                <p>{MARKETS.length} markets on Sui, priced by Pyth. LTV is conservative for equities (24/7 token vs. session underlying), higher for crypto.</p>
              </div>
              <div className="status-pill" style={{ color: "var(--tx-mut)", fontSize: 12.5 }}>
                <span className="bar" style={{ background: "var(--gold)" }} />{ok ? "Prices stream from Pyth" : "reconnecting…"}
              </div>
            </div>
            <div className="mkt-controls">
              <div className="search">
                <SearchIcon />
                <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder={`Search ${MARKETS.length} markets…`} spellCheck={false} />
                {query && <button className="clear" onClick={() => setQuery("")} aria-label="clear">×</button>}
              </div>
              <div className="chips">
                {CATS.map((c) => (
                  <button key={c.id} className={"chip-btn" + (category === c.id ? " on" : "")} onClick={() => setCategory(c.id)}>{c.label}</button>
                ))}
              </div>
            </div>
            <div className="table-card">
              <div className="tbl-scroll">
                <table className="mkt">
                  <thead><tr><th>Collateral</th><th>Oracle price</th><th>Max LTV</th><th>Class</th><th>Status</th></tr></thead>
                  <tbody>
                    {shown.map((m) => {
                      const p = prices[m.feedId];
                      return (
                        <tr key={m.symbol} onClick={() => (setSel(m.symbol), scrollTo("borrow"))} style={{ cursor: "pointer" }}>
                          <td><div className="asset"><TokenIcon sym={m.symbol} cls={m.assetClass} />
                            <div className="nm"><b>{m.symbol}</b><span>{m.name}{m.gap ? <i className="flag" title="24/7 token vs. session underlying — gap risk, LTV capped low.">gap-risk</i> : <i className="flag idx">{m.assetClass}</i>}</span></div></div></td>
                          <td><span className="big">{p ? usd(p.price, m.assetClass === "crypto" && p.price > 1000 ? 0 : 2) : "…"}</span></td>
                          <td><span className="big muted-cell">{m.ltvBps / 100}%</span></td>
                          <td><span className="big muted-cell">{m.assetClass}</span></td>
                          <td><span className="apr-supply">live</span></td>
                        </tr>
                      );
                    })}
                    {shown.length === 0 && <tr><td colSpan={5} style={{ textAlign: "center", padding: "30px", color: "var(--tx-mut)" }}>No markets match “{query}”.</td></tr>}
                  </tbody>
                </table>
              </div>
              <div className="mkt-foot">
                {!query && category === "all"
                  ? <>Showing {shown.length} featured — <button className="linklike" onClick={() => setCategory("crypto")}>browse all {MARKETS.length}</button> or search above</>
                  : <>Showing {shown.length} of {MARKETS.length} markets</>}
              </div>
            </div>
          </div>
        </section>

        {/* MONEY MOMENT */}
        <section className="band" id="borrow" style={{ paddingTop: 8 }}>
          <div className="wrap">
            <div className="band-head"><div><span className="eyebrow">Borrow &amp; Earn</span><h2>The money moment</h2>
              <p>Draw a loan against collateral you keep. Move the slider — health updates from the live price before you ever sign.</p></div></div>
            <div className="money">
              <BorrowPanel sel={sel} selPx={selPx} selConf={selConf} setSel={setSel} connected={connected} />
              <EarnPanel connected={connected} />
            </div>
          </div>
        </section>

        {/* POSITIONS */}
        <Positions connected={connected} />
        <GovernanceLog />
        <DocsSection />

        {/* PROOF */}
        <section className="band proof" id="proof">
          <div className="wrap">
            <div className="band-head"><div><span className="eyebrow">Why it's safe</span><h2>Four gates between you and bad debt</h2>
              <p>The rules are machine-checked, and money only moves when the math verifies.</p></div></div>
            <div className="flow">
              {[["01", "Kernel authorizes", "dregg checks LTV, a conservative Pyth price, and freshness. Over-limit borrows are refused before money moves."],
                ["02", "Borrow lands instantly", "USDC arrives the moment the kernel signs off."],
                ["03", "A zk-proof settles", "A Groth16 proof of the authorization verifies on-chain."],
                ["04", "Proven in Lean 4", "The safety rules are formally verified by a machine, not asserted in a doc."]].map(([no, h, p]) => (
                <div className="step" key={no}><span className="no">{no}</span><h3>{h}</h3><p>{p}</p></div>
              ))}
            </div>
          </div>
        </section>

        <footer><div className="wrap"><p className="disclaim">Assay is a devnet demonstration. Tokenized equities (xStocks) are securities issued by Backed Finance and carry issuer, custody, and market-gap risk; the issuer retains a permanent delegate over the collateral. Not an offer of securities. Nothing here is financial advice.</p></div></footer>
      </main>
    </>
  );
}

// Real token logo (crypto icon CDN / stock-logo API) with the mono-chip as a graceful fallback.
function TokenIcon({ sym, cls, sm }: { sym: string; cls?: "crypto" | "equity"; sm?: boolean }) {
  const [failed, setFailed] = useState(false);
  const assetClass = cls ?? MARKETS.find((m) => m.symbol === sym)?.assetClass ?? "equity";
  const src = assetClass === "crypto"
    ? `https://raw.githubusercontent.com/spothq/cryptocurrency-icons/master/128/color/${sym.toLowerCase()}.png`
    : `https://financialmodelingprep.com/image-stock/${encodeURIComponent(sym)}.png`;
  if (failed || !sym) return <div className={"mono-chip" + (sm ? " sm" : "")}>{chip(sym)}</div>;
  return <img className={"tok-img" + (sm ? " sm" : "")} src={src} onError={() => setFailed(true)} alt={sym} loading="lazy" />;
}

const SearchIcon = () => <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" /></svg>;
const Caret = () => <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" style={{ marginLeft: "auto", opacity: .6 }}><path d="m6 9 6 6 6-6" /></svg>;

// Searchable token picker — scales to any number of markets (replaces a giant <select>).
function TokenPicker({ value, onChange }: { value: string; onChange: (s: string) => void }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const results = useMemo(() => {
    const Q = q.trim().toUpperCase();
    return (Q ? MARKETS.filter((m) => m.symbol.includes(Q) || m.name.toUpperCase().includes(Q)) : MARKETS).slice(0, 80);
  }, [q]);
  return (
    <div className="picker">
      <button className="picker-btn" onClick={() => setOpen((o) => !o)}>
        <TokenIcon sym={value} sm />{value}<Caret />
      </button>
      {open && <>
        <div className="picker-backdrop" onClick={() => { setOpen(false); setQ(""); }} />
        <div className="picker-pop">
          <div className="picker-search"><SearchIcon /><input autoFocus value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search token…" spellCheck={false} /></div>
          <div className="picker-list">
            {results.map((m) => (
              <button key={m.symbol} className={"picker-item" + (m.symbol === value ? " on" : "")} onClick={() => { onChange(m.symbol); setOpen(false); setQ(""); }}>
                <TokenIcon sym={m.symbol} cls={m.assetClass} sm />
                <span className="pi-nm"><b>{m.symbol}</b><span>{m.name}</span></span>
                <span className="pi-ltv">{m.ltvBps / 100}%</span>
              </button>
            ))}
            {results.length === 0 && <div className="picker-empty">No token matches “{q}”.</div>}
          </div>
        </div>
      </>}
    </div>
  );
}

// Docs — renders the repo docs (bundled at build) in a reader modal.
function DocsSection() {
  const [open, setOpen] = useState<Doc | null>(null);
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(null); };
    window.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden"; // lock scroll behind the reader
    return () => { window.removeEventListener("keydown", onKey); document.body.style.overflow = ""; };
  }, [open]);
  return (
    <section className="band" id="docs" style={{ paddingTop: 8 }}>
      <div className="wrap">
        <div className="band-head"><div><span className="eyebrow">Docs</span><h2>How it works</h2>
          <p>The design, the risk framework, the interest-rate model, and the full security audit — read the details.</p></div></div>
        <div className="docs-grid">
          {DOCS.map((d) => (
            <button key={d.slug} className="doc-card" onClick={() => setOpen(d)}>
              <div className="doc-t">{d.title}</div>
              <div className="doc-d">{d.desc}</div>
              <div className="doc-r">Read →</div>
            </button>
          ))}
        </div>
      </div>
      {open && (
        <div className="doc-modal" onClick={() => setOpen(null)}>
          <div className="doc-reader" onClick={(e) => e.stopPropagation()}>
            <div className="doc-reader-h"><span>{open.title}</span><button onClick={() => setOpen(null)} aria-label="close">×</button></div>
            <div className="doc-md" dangerouslySetInnerHTML={{ __html: marked.parse(open.md) }} />
          </div>
        </div>
      )}
    </section>
  );
}

// Governance transparency: on-chain rate-change history + protocol reserves + isolation cap.
function GovernanceLog() {
  const { events, reserves, perCollateralCap } = useGovernance();
  const fmtTime = (ts: number) => (ts ? new Date(ts).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "—");
  return (
    <section className="band" id="governance" style={{ paddingTop: 8 }}>
      <div className="wrap">
        <div className="band-head"><div><span className="eyebrow">Governance</span><h2>Rate policy &amp; reserves</h2>
          <p>Every rate change is an on-chain event, publicly auditable. The protocol reserve is a transparent cut of borrow interest; the per-collateral cap isolates risk so no single asset can drain the pool.</p></div></div>
        <div className="gov-grid">
          <div className="gov-stat"><div className="gk">Protocol reserves</div><div className="gv num">{usd(reserves)}</div><div className="gsub">accrued from borrow interest</div></div>
          <div className="gov-stat"><div className="gk">Per-collateral cap</div><div className="gv num">{perCollateralCap > 0 ? usd(perCollateralCap) : "∞"}</div><div className="gsub">max borrow per collateral (isolation)</div></div>
          <div className="gov-stat"><div className="gk">Rate changes</div><div className="gv num">{events.length}</div><div className="gsub">on-chain governance actions</div></div>
        </div>
        <div className="table-card" style={{ marginTop: 16 }}>
          <div className="tbl-scroll"><table className="mkt">
            <thead><tr><th>When</th><th>Borrow APR @ kink</th><th>Kink</th><th>Reserve factor</th><th>Tx</th></tr></thead>
            <tbody>{events.length === 0
              ? <tr><td colSpan={5} style={{ textAlign: "center", padding: "28px", color: "var(--tx-mut)" }}>No rate changes recorded yet.</td></tr>
              : events.map((e, i) => (
                <tr key={e.digest + i}>
                  <td style={{ textAlign: "left" }}>{fmtTime(e.ts)}</td>
                  <td><span className="big">{((e.base + e.slope1) / 100).toFixed(2)}%</span></td>
                  <td><span className="big muted-cell">{(e.kink / 100).toFixed(0)}%</span></td>
                  <td><span className="big muted-cell">{(e.reserve / 100).toFixed(0)}%</span></td>
                  <td><a className="linklike" href={`https://suiscan.xyz/devnet/tx/${e.digest}`} target="_blank" rel="noreferrer">{e.digest.slice(0, 6)}…</a></td>
                </tr>
              ))}</tbody>
          </table></div>
        </div>
      </div>
    </section>
  );
}

function FaucetButton() {
  const { drip, busy } = useFaucet();
  const [msg, setMsg] = useState<string | null>(null);
  const go = async () => {
    setMsg(null);
    try { await drip(); setMsg("✓ coins sent"); setTimeout(() => setMsg(null), 3000); }
    catch (e: any) { setMsg(e?.message || "failed"); setTimeout(() => setMsg(null), 4000); }
  };
  return (
    <button className="btn btn-ghost" style={{ opacity: busy ? .6 : 1 }} disabled={busy} onClick={go} title="Mint test USDC + collateral to your wallet">
      {busy ? "…" : msg || "Get test coins"}
    </button>
  );
}

function BorrowPanel({ sel, selPx, selConf, setSel, connected }: { sel: Market; selPx: number; selConf: number; setSel: (s: string) => void; connected: boolean }) {
  const { borrow: doBorrow, busy, canBorrow } = useBorrow();
  const { drip, busy: faucetBusy } = useFaucet();
  const { view: poolView } = usePool();
  const [coll, setColl] = useState(1);
  const [ltv, setLtv] = useState(Math.min(30, sel.ltvBps / 100));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const maxLtv = sel.ltvBps / 100;
  const liqPct = sel.liqBps / 100;
  // value the collateral at the CONSERVATIVE price (price − 2·conf) — matches what the kernel
  // authorizes, so the displayed borrow won't be refused at max LTV (audit UI #1).
  const conservative = Math.max(0, selPx - 2 * selConf);
  const value = coll * conservative;
  // the pool can only lend what's idle — cap the offer at available liquidity so the preview matches reality
  const available = poolView.ready ? poolView.cash : Infinity;
  const borrowUsd = Math.min(value * (ltv / 100), available);
  const cappedByLiquidity = poolView.ready && value * (ltv / 100) > available + 0.01;
  const hf = borrowUsd > 0 ? (value * (liqPct / 100)) / borrowUsd : 99;
  const liqPrice = coll > 0 ? borrowUsd / (coll * (liqPct / 100)) : 0;
  const risk = hf >= 1.5 ? ["Comfortable", "var(--good)"] : hf >= 1.15 ? ["Moderate", "var(--warn)"] : ["At risk", "var(--crit)"];

  const review = async () => {
    setMsg(null);
    try {
      const sig = await doBorrow({ collateralType: sel.coinType, collateralDecimals: sel.decimals, collateralUnits: coll, debtUsdc: Math.floor(borrowUsd * 100) / 100 });
      setMsg({ ok: true, text: `borrowed ${sig.slice(0, 8)}… — see Your positions` });
    } catch (e: any) { setMsg({ ok: false, text: e?.message || String(e) }); }
  };

  return (
    <div className="panel">
      <div className="panel-h"><span className="t">Borrow USDC</span>
        <TokenPicker value={sel.symbol} onChange={setSel} />
      </div>
      <div className="panel-b">
        <div className="field"><div className="row"><label>Collateral</label><span className="bal">{sel.symbol} @ {usd(selPx, selPx > 1000 ? 0 : 2)}</span></div>
          <div className="row" style={{ marginTop: 6 }}>
            <input className="amt num" style={{ background: "transparent", border: 0, color: "var(--tx)", width: 140 }} type="number" min={0} step={0.1} value={coll} onChange={(e) => setColl(Math.max(0, +e.target.value))} />
            <span className="assetpick"><TokenIcon sym={sel.symbol} cls={sel.assetClass} />{sel.symbol}</span>
          </div>
          <div className="sub-usd">≈ {usd(value)} collateral value</div>
        </div>
        <div className="field"><div className="row"><label>You borrow</label><span className="bal">at {ltv}% LTV</span></div>
          <div className="row" style={{ marginTop: 6 }}><span className="amt num">{usd(borrowUsd)}</span><span className="assetpick"><span className="mono-chip">USD</span>USDC</span></div>
          {cappedByLiquidity && <div className="sub-usd" style={{ color: "var(--warn)" }}>capped by pool liquidity ({usd(available)} available)</div>}
        </div>
        <div className="slider-wrap">
          <div className="slider-top"><label style={{ fontSize: 12, color: "var(--tx-faint)", fontWeight: 600, textTransform: "uppercase", letterSpacing: ".08em" }}>Loan-to-value</label><span className="ltv-val">{ltv}%</span></div>
          <input type="range" min={5} max={maxLtv} step={1} value={ltv} onChange={(e) => setLtv(+e.target.value)} />
          <div className="ticks"><span>5%</span><span>{Math.round(maxLtv / 2)}%</span><span className="max">{maxLtv}% max</span></div>
        </div>
        <div className="gauge-wrap">
          <Gauge hf={hf} color={risk[1]} />
          <div className="readouts">
            <div className="ro"><span className="k">Status</span><span className="risk-tag" style={{ color: risk[1] }}>{risk[0]}</span></div>
            <div className="ro"><span className="k">Liquidation price</span><span className="v">{usd(liqPrice, liqPrice > 1000 ? 0 : 2)}</span></div>
            <div className="ro"><span className="k">Current {sel.symbol}</span><span className="v">{usd(selPx, selPx > 1000 ? 0 : 2)}</span></div>
          </div>
        </div>
        {connected
          ? <button className="btn btn-gold" style={{ width: "100%", marginTop: 20, padding: 13, opacity: busy || !canBorrow || coll <= 0 || borrowUsd <= 0 ? .6 : 1 }} disabled={busy || !canBorrow || coll <= 0 || borrowUsd <= 0} onClick={review}>
              {busy ? "authorizing + confirming…" : "Review & borrow"}</button>
          : <div style={{ marginTop: 20 }}><ConnectButton /></div>}
        {connected && !canBorrow && <div className="fine" style={{ marginTop: 8 }}>Borrow needs the pool configured (<code>VITE_PKG</code>/<code>VITE_POOL</code>).</div>}
        {connected && canBorrow && <div className="fine" style={{ marginTop: 8 }}>
          Need test coins?{" "}
          <a style={{ color: "var(--gold)", cursor: faucetBusy ? "default" : "pointer" }} onClick={() => !faucetBusy && drip(sel.coinType).then(() => setMsg({ ok: true, text: `sent test USDC + ${sel.symbol}` })).catch((e) => setMsg({ ok: false, text: e?.message || "faucet failed" }))}>
            {faucetBusy ? "sending…" : `Get test USDC + ${sel.symbol}`}</a>
        </div>}
        {msg && <div className="fine" style={{ marginTop: 8, color: msg.ok ? "var(--good)" : "var(--crit)" }}>{msg.ok ? "✓ " : "✗ "}{msg.text}</div>}
        <div className="fine"><Shield /> Authorized in-kernel by dregg, then the operator co-signs the disbursement</div>
      </div>
    </div>
  );
}

// Transparency: the live interest-rate curve (borrow APR vs utilization) + where the pool sits now.
function RateModel({ view }: { view: import("./pool").PoolView }) {
  if (!view.ready) return null;
  const c = view.curve, kink = c.kinkBps / 10000;
  const rateAt = (u: number) => (u <= kink ? c.baseBps + (c.slope1Bps * u) / kink : c.baseBps + c.slope1Bps + (c.slope2Bps * (u - kink)) / (1 - kink)) / 100;
  const W = 260, H = 84, pad = 5, maxR = Math.max(rateAt(1), 1);
  const x = (u: number) => pad + u * (W - 2 * pad);
  const y = (r: number) => H - pad - (r / maxR) * (H - 2 * pad);
  const pts = Array.from({ length: 41 }, (_, i) => `${x(i / 40).toFixed(1)},${y(rateAt(i / 40)).toFixed(1)}`).join(" ");
  const u = view.utilization;
  return (
    <div className="ratemodel">
      <div className="rm-head"><span>Interest-rate curve</span><span className="rm-sub">kink {(kink * 100).toFixed(0)}% · reserve {(c.reserveBps / 100).toFixed(0)}%</span></div>
      <svg viewBox={`0 0 ${W} ${H}`} className="rm-chart" preserveAspectRatio="none">
        <line x1={x(kink)} y1={pad} x2={x(kink)} y2={H - pad} className="rm-kink" />
        <polyline points={pts} className="rm-curve" />
        <circle cx={x(u)} cy={y(rateAt(u))} r="4" className="rm-dot" />
      </svg>
      <div className="rm-legend">
        <span>Borrow APR <b>{view.borrowApr.toFixed(2)}%</b></span>
        <span>Supply APY <b className="rm-good">{view.apyPct.toFixed(2)}%</b></span>
        <span>Utilization <b>{(u * 100).toFixed(0)}%</b></span>
      </div>
    </div>
  );
}

function EarnPanel({ connected }: { connected: boolean }) {
  const { view, busy, deposit, withdraw } = usePool();
  const [mode, setMode] = useState<"supply" | "withdraw">("supply");
  const [amt, setAmt] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const n = parseFloat(amt) || 0;

  const act = async () => {
    setMsg(null);
    try {
      const sig = mode === "supply" ? await deposit(n) : await withdraw(n);
      setMsg({ ok: true, text: `confirmed ${sig.slice(0, 8)}…` }); setAmt("");
    } catch (e: any) { setMsg({ ok: false, text: e?.message || String(e) }); }
  };

  return (
    <div className="panel" id="earn">
      <div className="panel-h"><span className="t">Earn on USDC</span>
        <div className="seg" role="tablist">
          <button aria-selected={mode === "supply"} onClick={() => setMode("supply")}>Supply</button>
          <button aria-selected={mode === "withdraw"} onClick={() => setMode("withdraw")}>Withdraw</button>
        </div>
      </div>
      <div className="panel-b">
        <div className="earn-hero"><div className="apy num">{view.ready ? view.apyPct.toFixed(2) + "%" : "—"}</div><div className="apyl">Net supply APY · USDC pool</div></div>
        <div className="field"><div className="row"><label>{mode === "supply" ? "You supply" : "You withdraw"}</label>
          <span className="bal">{mode === "withdraw" && view.ready ? `your shares ${view.myShares.toFixed(2)}` : "USDC"}</span></div>
          <div className="row" style={{ marginTop: 6 }}>
            <input className="amt num" style={{ background: "transparent", border: 0, color: "var(--tx)", width: 160 }} type="number" min={0} placeholder="0" value={amt} onChange={(e) => setAmt(e.target.value)} />
            <span className="assetpick"><span className="mono-chip">USD</span>USDC</span>
          </div>
        </div>
        <div className="earn-stats" style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 1, background: "var(--line)", border: "1px solid var(--line)", borderRadius: 12, overflow: "hidden", marginTop: 14 }}>
          {[["Pool liquidity", view.ready ? usd(view.cash) : "—"], ["Utilization", view.ready ? (view.utilization * 100).toFixed(0) + "%" : "—"],
            ["Total assets", view.ready ? usd(view.totalAssets) : "—"], ["Your position", view.ready ? usd(view.myValue) : "—"]].map(([k, v]) => (
            <div key={k} style={{ background: "var(--s2)", padding: "14px 16px" }}><div style={{ fontSize: 11, color: "var(--tx-faint)", textTransform: "uppercase", letterSpacing: ".08em", fontWeight: 600 }}>{k}</div><div className="num" style={{ fontSize: 18, marginTop: 5 }}>{v}</div></div>
          ))}
        </div>
        <RateModel view={view} />
        {!view.ready && <div className="fine" style={{ marginTop: 14 }}>Pool not live on this network — publish the package + set <code>VITE_PKG</code>/<code>VITE_POOL</code>.</div>}
        {connected
          ? <button className="btn btn-gold" style={{ width: "100%", marginTop: 18, padding: 13, opacity: busy || !view.ready || n <= 0 ? .6 : 1 }} disabled={busy || !view.ready || n <= 0} onClick={act}>
              {busy ? "confirming…" : mode === "supply" ? "Supply USDC" : "Withdraw"}</button>
          : <div style={{ marginTop: 18 }}><ConnectButton /></div>}
        {msg && <div className="fine" style={{ marginTop: 10, color: msg.ok ? "var(--good)" : "var(--crit)" }}>{msg.ok ? "✓ " : "✗ "}{msg.text}</div>}
        <div className="fine">Interest accrues per second via a borrow-index. Withdraw anytime liquidity allows.</div>
      </div>
    </div>
  );
}

function Positions({ connected }: { connected: boolean }) {
  const { positions, busy, repay } = usePositions();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  if (!connected) return null;
  const short = (s: string) => s.slice(0, 6) + "…" + s.slice(-4);
  const doRepay = async (pos: any) => {
    setMsg(null);
    try { const sig = await repay(pos); setMsg({ ok: true, text: `repaid ${sig.slice(0, 8)}…` }); }
    catch (e: any) { setMsg({ ok: false, text: e?.message || String(e) }); }
  };
  return (
    <section className="band" id="positions" style={{ paddingTop: 8 }}>
      <div className="wrap">
        <div className="band-head"><div><span className="eyebrow">Your positions</span><h2>Open loans</h2>
          <p>Collateral you've locked and the USDC you owe. Repay to reclaim your collateral.</p></div></div>
        <div className="table-card">
          {positions.length === 0
            ? <div style={{ padding: "34px 22px", color: "var(--tx-mut)", textAlign: "center" }}>No open positions. Borrow against collateral to open one.</div>
            : <div className="tbl-scroll"><table className="mkt">
                <thead><tr><th>Collateral</th><th>Amount</th><th>Debt (USDC)</th><th></th></tr></thead>
                <tbody>{positions.map((pos) => (
                  <tr key={pos.id}>
                    <td><div className="asset"><TokenIcon sym={pos.symbol} /><div className="nm"><b>{pos.symbol}</b><span>{short(pos.id)}</span></div></div></td>
                    <td><span className="big muted-cell">{(Number(pos.collateralRaw) / 10 ** pos.collateralDecimals).toLocaleString()}</span></td>
                    <td><span className="big">{usd(pos.debt)}</span></td>
                    <td><button className="btn btn-gold" style={{ opacity: busy ? .6 : 1 }} disabled={busy} onClick={() => doRepay(pos)}>{busy ? "…" : "Repay"}</button></td>
                  </tr>
                ))}</tbody>
              </table></div>}
        </div>
        {msg && <div className="fine" style={{ marginTop: 10, color: msg.ok ? "var(--good)" : "var(--crit)" }}>{msg.ok ? "✓ " : "✗ "}{msg.text}</div>}
      </div>
    </section>
  );
}

function Gauge({ hf, color }: { hf: number; color: string }) {
  const pct = Math.max(0, Math.min(1, (hf - 1) / 1.5)); // 1.0→empty, 2.5→full
  const r = 52, C = 2 * Math.PI * r;
  return (
    <div className="gauge">
      <svg viewBox="0 0 132 132" width="132" height="132">
        <circle cx="66" cy="66" r={r} fill="none" stroke="var(--s4)" strokeWidth="11" />
        <circle cx="66" cy="66" r={r} fill="none" stroke={color} strokeWidth="11" strokeLinecap="round"
          strokeDasharray={C} strokeDashoffset={C * (1 - pct)} transform="rotate(-90 66 66)" />
      </svg>
      <div className="center"><div><div className="hf num">{hf >= 99 ? "∞" : hf.toFixed(2)}</div><div className="hfl">Health</div></div></div>
    </div>
  );
}

const scrollTo = (id: string) => document.getElementById(id)?.scrollIntoView({ behavior: "smooth" });

const Hallmark = () => (
  <svg className="hallmark" viewBox="0 0 32 32" fill="none" aria-hidden><path d="M16 2.5 28.5 9v14L16 29.5 3.5 23V9L16 2.5Z" stroke="var(--gold)" strokeWidth="1.6" fill="var(--gold-dim)" /><path d="M11 16.2l3.4 3.4L21.4 12" stroke="var(--gold)" strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
const Shield = () => (
  <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden><path d="M12 3l7 3v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6l7-3Z" /><path d="M9 12l2 2 4-4" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
