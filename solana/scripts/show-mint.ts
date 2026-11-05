// Prints the on-chain configuration of an mStocks mint.
//   tsx scripts/show-mint.ts --mint <mint>
import { address, fetchEncodedAccount } from "@solana/kit";
import { getMintDecoder } from "@solana-program/token-2022";
import { parseArgs, required, rpc } from "./lib/env.ts";

const mint = address(required(parseArgs(), "mint"));
const account = await fetchEncodedAccount(rpc, mint);
if (!account.exists) throw new Error(`mint ${mint} not found`);
const decoded = getMintDecoder().decode(account.data);
const show = (v: unknown) => JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString() : x instanceof Map ? Object.fromEntries(x) : x));

console.log(`mint            ${mint}`);
console.log(`decimals        ${decoded.decimals}`);
console.log(`supply          ${decoded.supply}`);
console.log(`mintAuthority   ${show(decoded.mintAuthority)}`);
console.log(`freezeAuthority ${show(decoded.freezeAuthority)}`);
for (const ext of decoded.extensions.__option === "Some" ? decoded.extensions.value : []) {
  const { __kind, ...rest } = ext;
  console.log(`${__kind.padEnd(15)} ${show(rest)}`);
}
