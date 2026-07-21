// Liveness keeper for Robinhood Chain.
//
// Posts a heartbeat to LivenessOracle on a schedule. Liquidations on Assay require a recent
// heartbeat, so if this process — or the chain — stops, liquidations disable themselves with no
// transaction needed. That inversion is deliberate: a keeper that tries to PAUSE on an outage
// cannot send its pause transaction, because the chain it would send it to is down. It could only
// act after restart, racing the same backlog as the liquidation bots, and it would lose.
//
//   RH_RPC=... KEEPER_PRIVKEY=0x... LIVENESS_ORACLE=0x... node keeper/liveness-keeper.mjs
//
// Run it under a supervisor (systemd / pm2 / a container restart policy). Alert on the WARN lines:
// a keeper that dies silently degrades to "liquidations off", which is safe but is an outage of
// its own and should page someone.
import { createWalletClient, createPublicClient, http, defineChain } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = process.env.RH_RPC || "https://rpc.mainnet.chain.robinhood.com";
const ORACLE = process.env.LIVENESS_ORACLE;
const PK = process.env.KEEPER_PRIVKEY;
if (!ORACLE || !PK) {
  console.error("LIVENESS_ORACLE and KEEPER_PRIVKEY are required");
  process.exit(1);
}

// Beat at 1/3 of maxHeartbeatAge, so two consecutive failures still leave margin.
const MAX_AGE = Number(process.env.MAX_HEARTBEAT_AGE || 900);
const INTERVAL = Math.floor((MAX_AGE / 3) * 1000);

const rhChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const abi = [
  { type: "function", name: "heartbeat", inputs: [], outputs: [], stateMutability: "nonpayable" },
  { type: "function", name: "lastHeartbeat", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
  { type: "function", name: "liquidationsAllowed", inputs: [], outputs: [{ type: "bool" }], stateMutability: "view" },
  { type: "function", name: "secondsUntilLiquidationsAllowed", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
];

const account = privateKeyToAccount(PK);
const pub = createPublicClient({ chain: rhChain, transport: http(RPC) });
const wallet = createWalletClient({ account, chain: rhChain, transport: http(RPC) });

const ts = () => new Date().toISOString();
let consecutiveFailures = 0;

async function beat() {
  try {
    const hash = await wallet.writeContract({ address: ORACLE, abi, functionName: "heartbeat" });
    await pub.waitForTransactionReceipt({ hash, timeout: 60_000 });
    const [allowed, until] = await Promise.all([
      pub.readContract({ address: ORACLE, abi, functionName: "liquidationsAllowed" }),
      pub.readContract({ address: ORACLE, abi, functionName: "secondsUntilLiquidationsAllowed" }),
    ]);
    consecutiveFailures = 0;
    const state = allowed ? "liquidations ENABLED" : `liquidations DISABLED (${until}s of grace left)`;
    console.log(`${ts()}  beat ok  ${state}  ${hash}`);
    // A gap the keeper itself caused is worth surfacing loudly — it is indistinguishable
    // on-chain from a chain outage, and someone should know which one it actually was.
    if (!allowed && until > 0) console.warn(`${ts()}  WARN post-gap grace in effect for ${until}s`);
  } catch (e) {
    consecutiveFailures++;
    console.error(`${ts()}  WARN heartbeat failed (${consecutiveFailures}x): ${e.shortMessage || e.message}`);
    if (consecutiveFailures >= 2) {
      console.error(`${ts()}  ALERT two consecutive failures — liquidations will disable in ~${MAX_AGE}s`);
    }
  }
}

console.log(`${ts()}  liveness keeper up  oracle=${ORACLE}  signer=${account.address}  every ${INTERVAL / 1000}s`);
await beat();
setInterval(beat, INTERVAL);
