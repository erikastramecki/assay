import { useMemo, useState, useEffect, useLayoutEffect, useRef, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { ConnectButton, useCurrentAccount } from "@mysten/dapp-kit";
import { MARKETS, chip, type Market } from "./markets";
import { usePythPrices, isUsMarketHours } from "./pyth";
import { usePool, usePositions, useBorrow, useFaucet, useGovernance } from "./pool";
import { marked } from "marked";
import DOMPurify from "dompurify";
import { DOCS, type Doc } from "./docs.generated";

const usd = (n: number, d = 2) => "$" + n.toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });

const REPO = "https://github.com/erikastramecki/assay";
const GROUPS = ["Protocol", "Risk", "Audits"];

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
  const NAV = [["markets", "Markets"], ["borrow", "Borrow"], ["earn", "Earn"], ["how", "How it works"], ["chains", "Chains"], ["governance", "Governance"], ["docs", "Docs"], ["proof", "Proof"]];

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
              <span className="badge"><Shield /> Every loan assayed · every audit published</span>
              <h1>Borrow against your <em>onchain assets</em>.</h1>
              <p className="lede">Post {MARKETS.length} markets of collateral — crypto (BTC, ETH, SOL, SUI…) or tokenized equities — and draw a stablecoin in one transaction, without giving up custody. Every borrow is checked against a conservative live price before it is authorized, and every adversarial audit round we run is published.</p>
              <div className="hero-cta">
                <a className="btn btn-gold" href="#borrow">Open a position</a>
                <a className="btn btn-ghost" href="#how">How the proof works</a>
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
        {/* Page order tracks the nav order above — anchors that jump backwards feel broken. */}
        <Positions connected={connected} />
        <Dregg />
        <Chains />
        <GovernanceLog />
        <DocsSection />
        <Proof />

        <footer>
          <div className="wrap foot-in">
            <div>
              <p className="disclaim"><b>Assay is a devnet demonstration.</b> Tokenized equities are securities and carry issuer, custody, and market-gap risk. On Robinhood Chain the Stock Token issuer holds an {""}<b>adminBurn</b>{" "}power — verified on-chain to sit with a plain EOA — that can destroy tokens at any address with no pause or block check; posted collateral can therefore cease to exist, and the loss is socialised pro-rata across borrowers. An issuer pause also makes repayment impossible until it is lifted. The Robinhood Chain deployment is fork-tested against real mainnet state but is <b>not yet deployed</b>. Not an offer of securities. Nothing here is financial advice.</p>
              <p className="disclaim" style={{ marginTop: 10 }}>Everything we know is unfinished is published in <a href={`${REPO}/blob/main/docs/OUTSTANDING.md`} target="_blank" rel="noreferrer">OUTSTANDING.md</a> — including the items that block mainnet.</p>
            </div>
            <div className="foot-links">
              <a href={REPO} target="_blank" rel="noreferrer">GitHub ↗</a>
              <a href={`${REPO}/tree/main/docs/audits`} target="_blank" rel="noreferrer">Audits ↗</a>
              <a href={`${REPO}/blob/main/docs/OUTSTANDING.md`} target="_blank" rel="noreferrer">Known-open ↗</a>
              <a href="#docs">Docs</a>
            </div>
          </div>
        </footer>
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

// The centrepiece. Everything else on this page is detail; this is the actual idea, and it has to
// land for someone who has never heard of a proof assistant. Plain words first, jargon second, and
// the honest status at the end rather than woven through — hedging every sentence makes the idea
// unreadable, and the idea is the point.
function Dregg() {
  return (
    <section className="band dregg" id="how">
      <div className="wrap">
        <div className="band-head"><div><span className="eyebrow">The core idea</span><h2>What "proven" actually means here</h2>
          <p>Every lending protocol lives or dies by a single rule. Here's that rule, how everyone else protects it, and the different thing we do — in plain English.</p></div></div>

        <div className="dr-steps">
          <div className="dr-step">
            <span className="dr-n">The one rule</span>
            <h3>Never lend more than the collateral covers</h3>
            <p>That's it. That's the whole game. Written as math it's <code>debt ≤ collateral × price × LTV</code>. If this rule ever breaks — a rounding slip, a bad price, an edge case nobody tried — the pool has debt nothing backs, and the people who supplied the money lose it.</p>
          </div>
          <div className="dr-step">
            <span className="dr-n">How it's normally protected</span>
            <h3>Smart people read the code</h3>
            <p>That's an audit, and it's genuinely valuable — we run them constantly and publish them all. But an audit is a very good code review, not a guarantee. Nearly every nine-figure DeFi hack happened to <em>audited</em> code that had a bug nobody spotted. You end up trusting that the reviewers thought of everything.</p>
          </div>
          <div className="dr-step">
            <span className="dr-n">What we do instead</span>
            <h3>Have a machine check every case</h3>
            <p>The rule is written in <b>Lean 4</b>, a language built for proving things. A proof assistant then verifies it holds for <b>every possible input</b> — not the hundred cases a tester imagined, all of them, including the ones nobody would ever think to try. That verified rule is <b>dregg</b>. A machine checking every case is a different kind of assurance than a person checking many.</p>
          </div>
        </div>

        <div className="dr-proof">
          <div>
            <h3>Then the blockchain re-checks the math itself</h3>
            <p>A proof you have to take our word for isn't worth much. So dregg also produces a <b>zero-knowledge proof</b> — a small piece of cryptographic evidence that a batch of loans really did follow the rule. Sui has a proof checker built into the chain itself (<code>sui::groth16</code>), and it verifies that evidence before the batch can settle. If the math doesn't check out, the transaction simply fails. No human judgment, no trusted middleman, no "we reviewed it and it looked fine."</p>
            <p className="dr-analogy"><b>The analogy:</b> an audit is a building inspector walking the site and signing off. A proof is the structural math showing the building cannot collapse under any load it was designed for. The zk proof is that math being re-run at the door, automatically, before anyone is let inside.</p>
          </div>
          <div className="dr-why">
            <div className="dr-why-h">Why you'd care</div>
            <ul>
              <li>You aren't trusting that we wrote perfect code.</li>
              <li>You aren't trusting that an auditor caught everything.</li>
              <li>You're trusting arithmetic that a machine checked exhaustively — and that the chain re-checks before money moves.</li>
            </ul>
            <p>It doesn't remove every risk. Oracles can be wrong, markets can gap, and ordinary software around the edges is still ordinary software. It removes <em>one specific category</em>: the protocol quietly lending more than it should.</p>
          </div>
        </div>

        <div className="dr-status">
          <div className="dr-status-h">Where this stands today</div>
          <p>The kernel is machine-checked and the proof checker is live on Sui. The circuits connecting them are still being re-proven, so proof-gated settlement is switched off until they are — meanwhile the operator authorizes loans with an LTV check equivalent to the kernel's, and reports which one ran via <code>authMode</code>. Robinhood Chain runs no dregg: there the limit is enforced by the Solidity contract against a Chainlink feed.</p>
          <p>Gate-by-gate status is below.</p>
        </div>
      </div>
    </section>
  );
}

// The two chains, and what is genuinely different about each. Every claim here is one a reader can
// go check: the addresses are real, the decimals were read off the deployed tokens, and the
// "no sequencer feed" line is why LivenessOracle exists at all.
const CHAINS = [
  {
    id: "sui", name: "Sui", sub: "devnet · the risk-kernel chain", state: "live" as const,
    lede: "Where the formally-verified path is being built. Move's type system and object model let a loan carry its own safety argument.",
    tech: [
      ["Program", "dregg_lending_async — Move package with per-position objects, dynamic rate curve, and per-collateral isolation caps"],
      ["Pricing", "Pyth Hermes. Collateral is valued at price − 2·confidence, so the number you see is the conservative one the kernel will accept"],
      ["Authorization", "Operator signs an ed25519 attestation domain-separated by purpose and bound to the pool, collateral type, and an expiry — a signature for one loan cannot be replayed into another"],
      ["Settlement", "sui::groth16 BN254 verifier is deployed and live on-chain"],
      ["Solvency gate", "No on-chain oracle in the live module — the attestation is the gate, which is why it is bound to a 120s expiry, one pool, and a one-shot nullifier"],
      ["Why this chain", "The collateral's Move type is hashed into the loan commitment, so a position cannot be reopened against a cheaper asset — the type system enforces it, not a check we remembered to write"],
    ],
    caveat: "Origination and settle_batch stay disabled until both circuits are re-proven and audited. The devnet package predates the round 1–6 fixes and holds test coins only — Pool, Position and OperatorCap changed layout, so it needs a republish rather than an upgrade.",
  },
  {
    id: "rh", name: "Robinhood Chain", sub: "Arbitrum Orbit L2 · chainId 4663", state: "fork" as const,
    lede: "Where the real tokenized equities are. A Solidity port that meets the assets where they already exist, so an agent can buy a stock and borrow against it without a bridge.",
    tech: [
      ["Program", "AssayPool (ERC-4626) + AssayMarkets, with a 2-day timelock on every risk parameter"],
      ["Collateral", "The real Stock Tokens — beacon proxies with an ERC-8056 uiMultiplier, and an issuer deny-list that can block a transfer"],
      ["Pricing", "Chainlink equity feeds on an 86,400s heartbeat. Borrowing is refused outside the US session, on a stale round, and on a holiday the calendar doesn't know about — the feed must have printed at or after today's open"],
      ["Risk", "The contract enforces one constant: a minimum 20-point gap between LTV and the liquidation threshold, sized to absorb a weekend the position cannot be liquidated into. The launch proposal is 35/55, which is a governed parameter rather than a protocol invariant. Fork-tested against the real feed at 35/55: survives −30%, underwater by −40% (the arithmetic break is −36.4%)"],
      ["Liveness", "We could not locate a Chainlink sequencer-uptime feed for this chain (their docs claim one exists; we could not find it, and their docs have been wrong here before), so a keeper heartbeat stands in — after an outage, liquidations stay disabled through a grace period rather than firing on stale prices. It gates liquidation only: borrowing is not blocked by an undetected outage"],
    ],
    caveat: "No dregg here — the limit is enforced on-chain against a Chainlink feed, the same guarantee Aave gives. The end-to-end path passes against forked mainnet state; those tests need --fork-url and do not run in normal CI. Not yet deployed.",
  },
];

function Chains() {
  return (
    <section className="band" id="chains" style={{ paddingTop: 8 }}>
      <div className="wrap">
        <div className="band-head"><div><span className="eyebrow">Chains</span><h2>One protocol, two very different chains</h2>
          <p>Assay is multi-chain because the collateral is. The tokenized equities worth borrowing against live on Robinhood Chain; the verified risk kernel lives on Sui. Each deployment is built for what its chain actually offers — including what it doesn't.</p></div></div>
        <div className="chain-grid">
          {CHAINS.map((c) => (
            <article className="chain-card" key={c.id}>
              <div className="chain-h">
                <div><h3>{c.name}</h3><span className="chain-sub">{c.sub}</span></div>
                <span className={"chain-state " + c.state}>{c.state === "live" ? "live · devnet" : "fork-tested"}</span>
              </div>
              <p className="chain-lede">{c.lede}</p>
              <dl className="chain-tech">
                {c.tech.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}
              </dl>
              <p className="chain-caveat"><b>Status:</b> {c.caveat}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

// The honest version of the old "four gates" pitch. The design goal is unchanged; what differs is
// that each gate now carries its real state, and the ones that aren't live say so on the page
// rather than in a doc nobody opens.
const GATES = [
  ["01", "Conservative valuation", "on", "Collateral is valued at a live Pyth price marked down by twice its own confidence interval, and a stale price is refused outright. Off-session the staleness bound tightens from 60s to 15s. This runs on every borrow today."],
  ["02", "On-chain LTV enforcement", "part", "On Robinhood Chain the contract holding the money checks the limit against Chainlink, and a borrow over the line reverts — but that chain is not deployed yet. On Sui the live module has no on-chain oracle: a short-lived, single-use operator attestation is the solvency gate, so the LTV decision is made off-chain."],
  ["03", "Formally-verified kernel", "part", "dregg is real and machine-checked in Lean 4. Today the operator falls back to an equivalent in-process LTV check when the kernel is absent — and reports which one ran via authMode."],
  ["04", "Proof-gated settlement", "off", "The Groth16 verifier is deployed on Sui. Settlement stays disabled until both circuits are re-proven and audited — so it is off, not quietly trusted."],
] as const;

function Proof() {
  return (
    <section className="band proof" id="proof">
      <div className="wrap">
        <div className="band-head"><div><span className="eyebrow">Why it's safe</span><h2>Four gates — and where each one actually stands</h2>
          <p>Two are enforced on every loan today. Two are still being built, and say so.</p></div></div>
        <div className="flow">
          {GATES.map(([no, h, state, p]) => (
            <div className={"step gate-" + state} key={no}>
              <div className="step-h"><span className="no">{no}</span><span className={"gate-pill " + state}>{state === "on" ? "enforced" : state === "part" ? "fallback active" : "not enabled"}</span></div>
              <h3>{h}</h3><p>{p}</p>
            </div>
          ))}
        </div>
        <div className="proof-cta">
          <div>
            <b>Every round is published, clean or not.</b>
            <p>Six adversarial rounds on the Move protocol: 66 confirmed findings, no round clean on the first pass. The Solidity port's first round found 19; its second sweep left ~50 mutations surviving a green suite — including the 20-point risk gap and the 2-day timelock, so those two constants are tested weakly and we say so. Findings, refutations, and open items are all in the repo.</p>
          </div>
          <div className="proof-links">
            <a className="btn btn-gold" href="#docs">Read the audits</a>
            <a className="btn btn-ghost" href={`${REPO}/blob/main/docs/OUTSTANDING.md`} target="_blank" rel="noreferrer">What's still open ↗</a>
          </div>
        </div>
      </div>
    </section>
  );
}

// EVERY overlay renders into <body>, never into the section that triggered it.
//
// `section { position: relative; z-index: 1 }` makes each section a stacking context, which caps
// everything inside it at that level no matter how high the child's own z-index is. The doc reader
// (z-index 100) and the token dropdown (41) were both nested in a section, so the sticky header
// (z-index 50, a root-level sibling) painted straight over them — the "clicked a thing and the
// stuff behind it still showed through" bug. Portalling to <body> is the fix; raising z-indexes
// would not have worked, because the cap is the parent context, not the number.
// The scroll lock is REFCOUNTED, not save/restore-per-overlay. Two overlays can be open at once
// (the picker is reachable by keyboard while the doc reader is up), and with save/restore the
// second one captures "hidden" as its "previous" value and re-applies it on close — freezing the
// page with nothing on screen, recoverable only by reload. Only lockScroll overlays touch body
// style at all; a dropdown must never restore a modal's lock.
let scrollLocks = 0;
const FOCUSABLE = 'a[href],button:not([disabled]),input:not([disabled]),select,textarea,[tabindex]:not([tabindex="-1"])';

function Overlay({ onClose, lockScroll = true, trapFocus = false, children }: { onClose: () => void; lockScroll?: boolean; trapFocus?: boolean; children: ReactNode }) {
  const close = useRef(onClose);
  useEffect(() => { close.current = onClose; });
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const restoreTo = document.activeElement as HTMLElement | null;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") { close.current(); return; }
      // aria-modal is a promise that the rest of the page is unreachable. Keep it by actually
      // cycling Tab inside the overlay — asserting it without the trap is worse than not asserting.
      if (!trapFocus || e.key !== "Tab") return;
      const f = box.current?.querySelectorAll<HTMLElement>(FOCUSABLE);
      if (!f?.length) return;
      const first = f[0], last = f[f.length - 1], a = document.activeElement;
      const out = !box.current?.contains(a) || a === box.current;
      if (e.shiftKey && (out || a === first)) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && (out || a === last)) { e.preventDefault(); first.focus(); }
    };
    window.addEventListener("keydown", onKey);
    if (lockScroll && scrollLocks++ === 0) document.body.style.overflow = "hidden";
    if (trapFocus) (box.current?.querySelector<HTMLElement>("[data-autofocus]") ?? box.current?.querySelector<HTMLElement>(FOCUSABLE))?.focus();
    return () => {
      window.removeEventListener("keydown", onKey);
      if (lockScroll && (scrollLocks = Math.max(0, scrollLocks - 1)) === 0) document.body.style.overflow = "";
      if (trapFocus) restoreTo?.focus?.();
    };
  }, [lockScroll, trapFocus]);

  // display:contents — the wrapper exists only to scope the focus trap, never to affect layout.
  return createPortal(<div ref={box} className="overlay-root">{children}</div>, document.body);
}

// Searchable token picker — scales to any number of markets (replaces a giant <select>).
function TokenPicker({ value, onChange }: { value: string; onChange: (s: string) => void }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const btnRef = useRef<HTMLButtonElement>(null);
  const [at, setAt] = useState<{ top: number; right: number; maxH: number } | null>(null);
  // `at` MUST be cleared on close: the scroll listener is detached while closed, so a stale
  // position would be painted for one frame on reopen — the dropdown appearing detached from
  // its button, or off-screen entirely, before snapping back.
  const close = () => { setOpen(false); setQ(""); setAt(null); btnRef.current?.focus(); };
  const results = useMemo(() => {
    const Q = q.trim().toUpperCase();
    return (Q ? MARKETS.filter((m) => m.symbol.includes(Q) || m.name.toUpperCase().includes(Q)) : MARKETS).slice(0, 80);
  }, [q]);

  // Portalled to <body>, so the popup can't inherit the button's offset parent — anchor it in
  // viewport coordinates instead, and keep it glued to the button as the page scrolls or resizes.
  // useLayoutEffect, not useEffect: position must be committed before the browser paints, or the
  // first frame of every open shows the popup at the wrong place.
  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const r = btnRef.current?.getBoundingClientRect();
      if (!r) return;
      // Fixed positioning means scrolling can no longer reveal a popup that opened past the
      // bottom edge — it tracks the button instead. So clamp here: flip above the button when
      // below is cramped, and cap the height to whatever room is actually available.
      const below = window.innerHeight - r.bottom - 12, above = r.top - 12;
      const flip = below < 260 && above > below;
      const maxH = Math.min(374, Math.max(120, flip ? above : below));
      const top = flip ? Math.max(8, r.top - 6 - maxH)
                       : Math.max(8, Math.min(r.bottom + 6, window.innerHeight - 8 - maxH));
      const right = Math.max(8, window.innerWidth - r.right);
      // Scroll fires per frame; re-rendering 80 rows on an unchanged position is pure waste.
      setAt((p) => (p && p.top === top && p.right === right && p.maxH === maxH ? p : { top, right, maxH }));
    };
    place();
    window.addEventListener("scroll", place, true);
    window.addEventListener("resize", place);
    return () => { window.removeEventListener("scroll", place, true); window.removeEventListener("resize", place); };
  }, [open]);

  return (
    <div className="picker">
      <button ref={btnRef} className="picker-btn" aria-expanded={open} onClick={() => (open ? close() : setOpen(true))}>
        <TokenIcon sym={value} sm />{value}<Caret />
      </button>
      {open && at && (
        <Overlay onClose={close} lockScroll={false}>
          <div className="picker-backdrop" onClick={close} />
          <div className="picker-pop" style={{ top: at.top, right: at.right, maxHeight: at.maxH }}>
            <div className="picker-search"><SearchIcon /><input autoFocus value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search token…" spellCheck={false} /></div>
            <div className="picker-list">
              {results.map((m) => (
                <button key={m.symbol} className={"picker-item" + (m.symbol === value ? " on" : "")} onClick={() => { onChange(m.symbol); close(); }}>
                  <TokenIcon sym={m.symbol} cls={m.assetClass} sm />
                  <span className="pi-nm"><b>{m.symbol}</b><span>{m.name}</span></span>
                  <span className="pi-ltv">{m.ltvBps / 100}%</span>
                </button>
              ))}
              {results.length === 0 && <div className="picker-empty">No token matches “{q}”.</div>}
            </div>
          </div>
        </Overlay>
      )}
    </div>
  );
}

// Docs — renders the repo docs (bundled at build) in a reader modal.
function DocsSection() {
  const [open, setOpen] = useState<Doc | null>(null);
  return (
    <section className="band" id="docs" style={{ paddingTop: 8 }}>
      <div className="wrap">
        <div className="band-head"><div><span className="eyebrow">Docs</span><h2>Read the whole thing</h2>
          <p>The design, the risk framework, the rate model, every adversarial audit round, and the list of what is still unfinished. These are the repo's own files, rendered here — not a marketing summary of them.</p></div></div>
        {GROUPS.map((g) => {
          const inGroup = DOCS.filter((d) => d.group === g);
          if (inGroup.length === 0) return null;
          return (
            <div className="doc-group" key={g}>
              <div className="doc-group-h">{g}<span>{inGroup.length}</span></div>
              <div className="docs-grid">
                {inGroup.map((d) => (
                  <div key={d.slug} className="doc-card">
                    <button className="doc-card-hit" onClick={() => setOpen(d)} aria-label={`Read ${d.title}`}>
                      <span className="doc-t">{d.title}</span>
                      <span className="doc-d">{d.desc}</span>
                      <span className="doc-r">Read →</span>
                    </button>
                    <div className="doc-foot">
                      <a className="doc-src" href={`${REPO}/blob/main/docs/${d.file}`} target="_blank" rel="noreferrer">source ↗</a>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          );
        })}
      </div>
      {open && (
        <Overlay onClose={() => setOpen(null)} trapFocus>
          <div className="doc-modal" onClick={() => setOpen(null)}>
            {/* key: switching documents must remount the scroll container, or the next doc opens
                at the previous one's scroll offset and looks truncated. role/aria-modal belong on
                the reader, not on the backdrop — the backdrop is a dismiss surface, not the dialog. */}
            <div className="doc-reader" key={open.slug} tabIndex={-1} data-autofocus
                 role="dialog" aria-modal="true" aria-label={open.title} onClick={(e) => e.stopPropagation()}>
              <div className="doc-reader-h"><span>{open.title}</span><button onClick={() => setOpen(null)} aria-label="close">×</button></div>
              <div className="doc-md" dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(marked.parse(open.md) as string) }} />
            </div>
          </div>
        </Overlay>
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
        <div className="fine"><Shield /> Authorized off-chain against a conservative price, then verified in-Move against a single-use operator attestation. The operator never co-signs and never holds your funds. The hosted demo runs the fallback LTV check, not the dregg kernel — the response labels which one ran.</div>
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
