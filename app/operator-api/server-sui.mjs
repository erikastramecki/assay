// The Operator API — SUI edition. Same job as the Solana operator, Sui-native mechanism:
// fetch a live Pyth price, ask the dregg kernel to AUTHORIZE (LTV + oracle discipline), and
// — only if authorized — return an ed25519 ATTESTATION over the exact loan terms. The
// borrower's own wallet then sends `disburse_attested` (providing their collateral); the Move
// contract verifies the attestation on-chain. The operator authorizes; it never holds funds,
// never co-signs a tx, never custodies collateral. Non-custodial by construction.
//
//   COLLATERAL_REGISTRY=… OPERATOR_KEY=…/.operator-sui.key npm run start-sui
import express from "express";
import cors from "cors";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync, existsSync } from "node:fs";
import { randomBytes } from "node:crypto";
import os from "node:os";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { toHex } from "@mysten/sui/utils";
import { signAttestation, operatorPubkeyBytes } from "../sui-sdk/src/index.ts";
import { fetchPythPrice, applyOraclePolicy } from "../../operator/pyth.mjs";

const exec = promisify(execFile);
const PORT = Number(process.env.PORT || 8788);
const DREGG = process.env.DREGG || `${os.homedir()}/Developer/dregg-lab/dregg`;
// key from env (hosted) or file (local). OPERATOR_KEY_INLINE = the suiprivkey1… string.
const operatorSecret = process.env.OPERATOR_KEY_INLINE
  ? process.env.OPERATOR_KEY_INLINE.trim()
  : readFileSync(process.env.OPERATOR_KEY || new URL(".operator-sui.key", import.meta.url).pathname, "utf8").trim();
const operator = Ed25519Keypair.fromSecretKey(operatorSecret);
const OPERATOR_PUBKEY_HEX = toHex(operatorPubkeyBytes(operator));

// Optional test-coin faucet (devnet demo): operator holds the TreasuryCaps + a little gas.
// FAUCET_MINTS (JSON): [{ "target":"<pkg>::<mod>::mint", "cap":"0x…", "amount":"5000000000" }, …]
// mints the stable + every collateral coin to a visitor in one PTB.
const NETWORK = process.env.SUI_NETWORK || "devnet";
const FAUCET_MINTS = JSON.parse(process.env.FAUCET_MINTS || "[]"); // [0] = stable, rest = collateral
const faucetOn = FAUCET_MINTS.length > 0;
const faucetByTarget = new Map(FAUCET_MINTS.map((m) => [m.target, m]));
const mintTargetFor = (coinType) => coinType.split("::").slice(0, 2).join("::") + "::mint";
const suiClient = new SuiClient({ url: process.env.SUI_RPC || getFullnodeUrl(NETWORK) });
const faucetSeen = new Map(); // address → last mint ms (rate limit)

// Server owns the risk params (audit CRITICAL-2). On Sui a "collateral mint" is a Coin TYPE.
//   COLLATERAL_REGISTRY = { "<pkg>::<mod>::<TYPE>": { "feedId":"0x…", "ltvBps":4000, "decimals":8 } }
const REGISTRY = JSON.parse(process.env.COLLATERAL_REGISTRY || "{}");
function assetFor(coinType) {
  const a = REGISTRY[coinType];
  if (!a) throw new Error(`collateral ${coinType} is not an allowed market`);
  return a;
}
const posFinite = (n) => typeof n === "number" && Number.isFinite(n) && n > 0;

// The dregg kernel authorizer needs the Rust workspace + cargo (local/box deploy). On a plain
// Node host it isn't present, so we fall back to the equivalent in-operator LTV+oracle check
// (the same inequality dregg enforces; the caller has already re-checked max-LTV, and the
// on-chain contract enforces the attestation + cap + borrower guards regardless). The response
// carries an honest `authMode` so it's never misrepresented as kernel-enforced.
let dreggAvailable = existsSync(DREGG);

/** dregg kernel authorization (LTV + oracle caveats in-kernel), or an honest in-operator fallback. */
async function dreggAuthorize({ collateral, priceCents, confCents, ltvBps, debtCents, age, marketHours, withinMax }) {
  if (dreggAvailable) {
    try {
      const { stdout } = await exec("cargo", ["run", "-q", "-p", "dregg-sdk", "--example", "dregg_borrow", "--",
        String(collateral), String(priceCents), String(confCents), String(ltvBps), String(debtCents),
        "2", String(age), String(marketHours ? 60 : 15), "100"], { cwd: DREGG, maxBuffer: 1 << 20 });
      return { ok: /AUTHORIZED/.test(stdout), line: stdout.trim().split("\n").pop(), authMode: "dregg-kernel" };
    } catch (e) {
      if (e.code === "ENOENT") dreggAvailable = false; // cargo missing → switch to fallback for the rest of the process
      else return { ok: false, line: (e.stdout || "").trim().split("\n").pop() || "REFUSED", authMode: "dregg-kernel" };
    }
  }
  // fallback: oracle freshness is already enforced by priceFor(); LTV by the caller's max-check
  return { ok: !!withinMax, line: withinMax ? "AUTHORIZED (operator LTV+oracle; dregg kernel in full deploy)" : "REFUSED over-LTV", authMode: "operator-fallback" };
}

async function priceFor(feedId, assetClass = "equity") {
  const ora = applyOraclePolicy(await fetchPythPrice(feedId), { nowMs: Date.now(), maxConfBps: 100, assetClass });
  if (!ora.ok) throw new Error(`oracle: ${ora.reason}`);
  return ora;
}

// a BN254-field-safe u256 loan commit (< 2^248 << the field prime, so poseidon accepts it)
const freshCommit = () => BigInt("0x" + Buffer.from(randomBytes(31)).toString("hex"));

const app = express();
const corsCfg = process.env.CORS_ORIGINS || "http://localhost:5173,http://127.0.0.1:5173";
app.use(cors({ origin: corsCfg.trim() === "*" ? true : corsCfg.split(",") }));
app.use(express.json({ limit: "8kb" }));

app.get("/health", (_req, res) => res.json({ ok: true, chain: "sui", network: NETWORK, operatorPubkey: OPERATOR_PUBKEY_HEX, markets: Object.keys(REGISTRY), faucet: faucetOn, authMode: dreggAvailable ? "dregg-kernel" : "operator-fallback" }));

// devnet demo faucet: mint test stable + ONE requested collateral (bounded gas at any market count)
app.post("/faucet", async (req, res) => {
  try {
    if (!faucetOn) throw new Error("faucet not configured");
    const { address, coinType } = req.body;
    if (typeof address !== "string" || !/^0x[0-9a-fA-F]{1,64}$/.test(address)) throw new Error("bad address");
    const last = faucetSeen.get(address) || 0;
    if (Date.now() - last < 20_000) return res.status(429).json({ error: "wait a moment between drips" });
    faucetSeen.set(address, Date.now());
    // always the stable, plus the requested collateral (or the first one if none/unknown)
    const mints = [FAUCET_MINTS[0]];
    const coll = (coinType && faucetByTarget.get(mintTargetFor(coinType))) || FAUCET_MINTS[1];
    if (coll) mints.push(coll);
    const tx = new Transaction();
    for (const m of mints)
      tx.moveCall({ target: m.target, arguments: [tx.object(m.cap), tx.pure.u64(BigInt(m.amount)), tx.pure.address(address)] });
    tx.setSender(operator.toSuiAddress());
    const r = await suiClient.signAndExecuteTransaction({ signer: operator, transaction: tx, options: { showEffects: true } });
    await suiClient.waitForTransaction({ digest: r.digest });
    if (r.effects?.status?.status !== "success") throw new Error("mint failed: " + JSON.stringify(r.effects?.status));
    res.json({ ok: true, digest: r.digest, minted: mints.map((m) => m.target.split("::").slice(-2, -1)[0]) });
  } catch (e) { res.status(400).json({ error: String(e.message || e) }); }
});

// live terms for a prospective loan (server registry owns feed/ltv/decimals)
app.post("/quote", async (req, res) => {
  try {
    const { collateralMint, collateralWhole } = req.body;
    if (!posFinite(collateralWhole)) throw new Error("bad collateral amount");
    const asset = assetFor(collateralMint);
    const ora = await priceFor(asset.feedId, asset.assetClass);
    const conservative = Number(ora.price) - 2 * Number(ora.conf);
    const maxBorrowCents = Math.max(0, Math.floor(collateralWhole * conservative * asset.ltvBps / 10000));
    res.json({ priceCents: Number(ora.price), confCents: Number(ora.conf), age: ora.age, marketHours: ora.marketHours, ltvBps: asset.ltvBps, maxBorrowUsdc: maxBorrowCents / 100 });
  } catch (e) { res.status(400).json({ error: String(e.message || e) }); }
});

// authorize + ATTEST: returns the operator ed25519 signature over the exact terms. The borrower
// builds `disburse_attested` with these terms + this attestation and signs it in their wallet.
app.post("/borrow", async (req, res) => {
  try {
    const { borrower, collateralMint, collateralAmount, debtUsdc } = req.body;
    const asset = assetFor(collateralMint);
    if (!posFinite(collateralAmount) || !posFinite(debtUsdc)) throw new Error("bad amounts");
    if (typeof borrower !== "string" || !borrower.startsWith("0x")) throw new Error("bad borrower");
    const ora = await priceFor(asset.feedId, asset.assetClass);
    const collateralWhole = collateralAmount / 10 ** asset.decimals;
    const collateralScaled = Math.round(collateralWhole * 1000); // fractional-safe (0.5 units, not 1)
    const debtCents = Math.round(debtUsdc * 100);
    if (collateralScaled <= 0) throw new Error("collateral too small");
    const conservative = Number(ora.price) - 2 * Number(ora.conf);
    const maxCents = Math.floor(collateralWhole * conservative * asset.ltvBps / 10000);
    if (debtCents > maxCents) return res.status(403).json({ error: "over max LTV", detail: `debt $${debtUsdc} > max $${(maxCents / 100).toFixed(2)}` });

    const auth = await dreggAuthorize({ collateral: collateralScaled, priceCents: Number(ora.price), confCents: Number(ora.conf), ltvBps: asset.ltvBps, debtCents: debtCents * 1000, age: ora.age, marketHours: ora.marketHours, withinMax: debtCents <= maxCents });
    if (!auth.ok) return res.status(403).json({ error: "authorization refused", detail: auth.line });

    // exact on-chain base units the borrower will pass to disburse_attested
    const debtBase = BigInt(Math.round(debtUsdc * 1e6)); // TUSDC/USDC 6-dec
    const collateralBase = BigInt(Math.round(collateralAmount));
    const loanCommit = freshCommit();
    // bind the collateral TYPE into the attestation (audit CRITICAL: prevents collateral substitution)
    const attestation = await signAttestation(operator, borrower, debtBase, collateralBase, loanCommit, collateralMint);

    res.json({
      attestation: toHex(attestation),
      operatorPubkey: OPERATOR_PUBKEY_HEX,
      debtBase: debtBase.toString(),
      collateralBase: collateralBase.toString(),
      loanCommit: loanCommit.toString(),
      authorized: auth.line,
      authMode: auth.authMode,
      priceUsd: Number(ora.price) / 100,
    });
  } catch (e) { res.status(400).json({ error: String(e.message || e) }); }
});

// Local: start a listener. Hosted (serverless): the app is imported + exported instead.
if (!process.env.VERCEL) app.listen(PORT, () => console.log(`operator-api (SUI) on :${PORT}  operator ${OPERATOR_PUBKEY_HEX}  markets ${Object.keys(REGISTRY).join(",") || "(none)"}`));

export default app;
