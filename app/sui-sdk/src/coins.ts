// Coin selection helper: build a single Coin<T> argument of EXACTLY `amount` from the
// owner's coins of that type, inside a PTB (merge all, then split the exact amount).
import type { Transaction, TransactionArgument } from "@mysten/sui/transactions";
import type { SuiClient } from "@mysten/sui/client";

export async function exactCoin(
  tx: Transaction,
  client: SuiClient,
  owner: string,
  coinType: string,
  amount: bigint,
): Promise<TransactionArgument> {
  const { data } = await client.getCoins({ owner, coinType });
  if (data.length === 0) throw new Error(`no ${coinType} coins owned by ${owner}`);
  const total = data.reduce((s, c) => s + BigInt(c.balance), 0n);
  if (total < amount) throw new Error(`insufficient ${coinType}: have ${total}, need ${amount}`);
  const [primary, ...rest] = data.map((c) => c.coinObjectId);
  if (rest.length) tx.mergeCoins(tx.object(primary), rest.map((id) => tx.object(id)));
  const [split] = tx.splitCoins(tx.object(primary), [amount]);
  return split;
}
