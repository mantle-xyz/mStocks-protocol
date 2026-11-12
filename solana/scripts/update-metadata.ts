// Updates one token metadata field (MetadataOps role): name, symbol, uri, or any additional key
// such as isin. Token-2022 grows the mint but does not add rent, so the operator tops it up first.
//   tsx scripts/update-metadata.ts --operator <keypair> --mint <mint> --field name|symbol|uri|<key> --value <value>
import { address, fetchEncodedAccount, lamports } from "@solana/kit";
import { getTransferSolInstruction } from "@solana-program/system";
import { coreInstruction, concat, encodeMetadataField, encodeString, mintOpAccounts } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send } from "./lib/env.ts";

const args = parseArgs();
const operator = await loadKeypair(required(args, "operator"));
const mint = address(required(args, "mint"));
const field = required(args, "field");
const value = required(args, "value");

// Worst case the field is new: key + value + two length prefixes.
const account = await fetchEncodedAccount(rpc, mint);
if (!account.exists) throw new Error(`mint ${mint} not found`);
const grownSize = BigInt(account.data.length + field.length + value.length + 8);
const needed = await rpc.getMinimumBalanceForRentExemption(grownSize).send();
const topUp = needed > account.lamports ? needed - account.lamports : 0n;

const ix = coreInstruction("update_metadata", await mintOpAccounts("MetadataOps", operator, mint), concat(encodeMetadataField(field), encodeString(value)));
const ixs = topUp > 0n ? [getTransferSolInstruction({ source: operator, destination: mint, amount: lamports(topUp) }), ix] : [ix];
console.log(`update_metadata ${field}: ${await send(operator, ixs)}`);
