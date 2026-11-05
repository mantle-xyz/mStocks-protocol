// Moves tokens out of a (blacklisted) account into custody as the permanent delegate (Clawback role).
// The source always ends frozen.
//   tsx scripts/clawback.ts --operator <keypair> --mint <mint> --source <token account> --destination <custody token account> --amount <raw>
import { address } from "@solana/kit";
import { coreInstruction, encodeU64, mintOpAccounts } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const operator = await loadKeypair(required(args, "operator"));
const mint = address(required(args, "mint"));

const ix = coreInstruction(
  "clawback",
  {
    ...(await mintOpAccounts("Clawback", operator, mint)),
    source: address(required(args, "source")),
    destination: address(required(args, "destination")),
  },
  encodeU64(BigInt(required(args, "amount"))),
);
console.log(`clawback: ${await send(operator, [ix])}`);
