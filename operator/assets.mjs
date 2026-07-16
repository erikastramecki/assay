// RWA collateral registry — real on-chain tokens + their real Pyth equity feeds.
//
// These are LIVE Solana mainnet mints (Backed Finance / Kraken xStocks, 1:1 backed,
// held by regulated custodians) and the matching Pyth pull-oracle feed ids. The
// operator/keeper price these via Hermes (fetchPythPrice) + applyOraclePolicy, and the
// dregg borrow/liquidate kernel enforces LTV/health against that price.
//
// GAP-RISK NOTE (audit Part A): equity xStocks trade 24/7 but the underlying only during
// the US session, so RWA-equity collateral gets a LOW max-LTV and a TIGHT off-hours
// staleness bound — the oracle policy + kernel caveats enforce it.

// Classic SPL Token program (cbBTC, USDC, wSOL) vs Token-2022 (xStocks). Our collateral
// leg handles both via transfer_checked + the passed token program.
const TOKEN = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const TOKEN_2022 = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";

// `assetClass` drives oracle discipline: "crypto" = 24/7, no off-hours staleness tightening;
// "equity" = market-hours-aware (24/7 token vs session underlying = gap risk); "treasury" = slow.
export const RWA_ASSETS = {
  // ✅ FULLY VERIFIED + wire-ready (mint + program + decimals read on-chain; feed live).
  cbBTC: {
    symbol: "cbBTC",
    name: "Coinbase Wrapped BTC",
    mint: "cbbtcf3aa214zXHbiAZQwf4122FBYbraNdFqgw4iMij", // verified on forked mainnet 2026-07-14
    tokenProgram: TOKEN,   // classic SPL — 82-byte base mint, no extensions
    decimals: 8,           // verified on-chain
    // NO permanent delegate, NO transfer hook — cleanest collateral profile (unlike xStocks).
    pythFeedId: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43", // Crypto.BTC/USD
    assetClass: "crypto",  // 24/7 — needs the crypto branch in pyth.mjs (skip off-hours tightening)
    maxLtvBps: 7000,       // 70% — deep liquidity, robust oracle, no gap risk
    liqThresholdBps: 8000, // 80%
  },
  TSLAx: {
    symbol: "TSLAx",
    name: "Tesla xStock",
    mint: "XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB", // Solana mainnet mint (verified on-chain)
    tokenProgram: TOKEN_2022, // Token-2022 (verified)
    decimals: 8,
    // PermanentDelegate = issuer can move/claw back collateral (compliance) — disclose. Hook NULL. No fee.
    permanentDelegate: "5aMNNLQJwAEeoemTEMkv5NVjqKwvvefRYCQ5Z67HFvEq",
    pythFeedId: "0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1", // Equity.US.TSLA/USD
    assetClass: "equity",
    maxLtvBps: 4000,       // 40% — gap-risk buffer
    liqThresholdBps: 5000,
  },
  // ⏳ FEEDS VERIFIED LIVE (below), mints still to pull from Solscan (same Token-2022 family as TSLAx):
  //   SPYx  feed 0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5  (index → LTV 55/65)
  //   AAPLx feed 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688  (LTV 45/58)
  //   NVDAx feed 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593  (LTV 40/55)
  //   MSTRx feed 0xe1e80251e5f5184f2195008382538e847fafc36f751896889dd3d1b1f6111f09  (LTV 30/45)
  //   COINx feed 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245  (LTV 35/48)
  // Crypto adds (classic SPL, assetClass "crypto"): ETH 0xff61491a…d0ace, SOL 0xef0d8b6f…0b56d.
  // See docs/MARKETS-EXPANSION.md for the full plan.
};

// The stablecoin lenders supply / borrowers receive (classic SPL Token).
export const STABLE = {
  symbol: "USDC",
  mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", // Solana mainnet USDC
  decimals: 6,
};

export function getAsset(symbol) {
  const a = RWA_ASSETS[symbol];
  if (!a) throw new Error(`unknown RWA asset ${symbol}`);
  return a;
}
