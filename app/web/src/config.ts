// Sui config. All on-chain ids are set from the environment after publishing + init
// (see app/sui-harness/dev-up-sui.sh which writes .env.local). Null/empty until then:
// the app runs read-only (live prices) and gates on-chain actions.

export const NETWORK = import.meta.env.VITE_SUI_NETWORK || "devnet";

// Published dregg_lending_async package id.
export const PKG: string | null = import.meta.env.VITE_PKG || null;
// The shared Pool<Stable> object id.
export const POOL_ID: string | null = import.meta.env.VITE_POOL || null;

// Stable coin (the lent asset) — fully-qualified Coin type, e.g. 0x…::tusdc::TUSDC.
export const STABLE_TYPE: string = import.meta.env.VITE_STABLE_TYPE || "";
export const STABLE_DECIMALS = Number(import.meta.env.VITE_STABLE_DECIMALS || 6);
export const STABLE_UNIT = 10 ** STABLE_DECIMALS;

// The Operator API (dregg authorize + ed25519 attestation for the non-custodial borrow).
export const OPERATOR_API = import.meta.env.VITE_OPERATOR_API || "http://127.0.0.1:8788";

// Collateral markets are self-contained in markets.ts (each carries its own full coinType, so they
// can span any number of coin packages). Multi-collateral: the borrow flow uses whichever market the
// user selects, all against the one shared USDC pool.
export const poolReady = () => !!(PKG && POOL_ID && STABLE_TYPE);
export const borrowReady = () => poolReady();
