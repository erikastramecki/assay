// Regenerate src/RobinhoodFeeds.sol from Chainlink's feed directory.
// Grounded in the directory rather than a docs page, so heartbeats cannot drift silently.
const URL = "https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json";
const feeds = await (await fetch(URL)).json();
const eq = feeds.filter((f) => (f.name || "").includes("Robinhood"));
const hb = [...new Set(eq.map((f) => f.heartbeat))];
const dev = [...new Set(eq.map((f) => f.threshold))];
console.log(`${eq.length} Robinhood equity feeds | heartbeats: ${hb} | deviation: ${dev}%`);
if (hb.length !== 1 || hb[0] !== 86400) {
  console.error("HEARTBEAT CHANGED — StaleFeedGuard.FEED_HEARTBEAT and every configured");
  console.error("maxStaleness must be revisited before deploying.");
  process.exit(1);
}
for (const f of eq.sort((a, b) => a.name.localeCompare(b.name)))
  console.log(`  ${f.name.padEnd(28)} ${f.proxyAddress} dec=${f.decimals}`);
