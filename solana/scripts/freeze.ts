// Freezes (Freezer role) or thaws (Unfreezer role) token accounts of one mint. Pass explicit
// `--accounts a,b,c`, or `--owner <wallet>` to act on every token account the wallet owns for this
// mint (ATA and non-ATA) — what the backend does when it blacklists a wallet.
//   tsx scripts/freeze.ts --operator <keypair> --mint <mint> (--owner <wallet> | --accounts a,b) [--thaw]
import { address, type Address } from "@solana/kit";
import { coreInstruction, mintOpAccounts, withRemaining } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send } from "./lib/env.ts";

/** Token accounts per transaction; keeps the transaction well under the size limit. */
const BATCH = 20;

const args = parseArgs();
const operator = await loadKeypair(required(args, "operator"));
const mint = address(required(args, "mint"));
const thaw = args.thaw === "true";

let accounts: Address[];
if (args.owner) {
  const { value } = await rpc
    .getTokenAccountsByOwner(address(args.owner), { mint }, { encoding: "base64" })
    .send();
  accounts = value.map((a) => a.pubkey);
  console.log(`${accounts.length} token account(s) of ${args.owner} for ${mint}`);
} else {
  accounts = required(args, "accounts").split(",").map((a) => address(a.trim()));
}
if (accounts.length === 0) process.exit(0);

const base = coreInstruction(thaw ? "thaw" : "freeze", await mintOpAccounts(thaw ? "Unfreezer" : "Freezer", operator, mint), new Uint8Array());
for (let i = 0; i < accounts.length; i += BATCH) {
  const batch = accounts.slice(i, i + BATCH);
  console.log(`${thaw ? "thaw" : "freeze"} ${batch.length}: ${await send(operator, [withRemaining(base, batch)])}`);
}
