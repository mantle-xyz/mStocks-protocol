// Pauses (Pauser role) or resumes (Unpauser role) one mint. --operator is a keypair file (signs and
// sends) or, for a multisig role holder such as the mainnet Unpauser, its address (prints the
// instruction for a Squads proposal).
//   tsx scripts/pause.ts --operator <keypair.json|squads vault> --mint <mint> [--resume]
import { address } from "@solana/kit";
import { printForSquads, resolveAdmin } from "./lib/admin.ts";
import { coreInstruction, mintOpAccounts } from "./lib/core.ts";
import { parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const operator = await resolveAdmin(required(args, "operator"));
const mint = address(required(args, "mint"));
const resume = args.resume === "true";
const label = resume ? "resume" : "pause";

const ix = coreInstruction(
  label,
  await mintOpAccounts(resume ? "Unpauser" : "Pauser", operator, mint),
  new Uint8Array(),
);
if (typeof operator === "string") printForSquads(ix, label);
else console.log(`${label}: ${await send(operator, [ix])}`);
