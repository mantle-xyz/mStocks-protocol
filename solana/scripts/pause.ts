// Pauses (Pauser role) or resumes (Unpauser role) one mint.
//   tsx scripts/pause.ts --operator <keypair> --mint <mint> [--resume]
import { address } from "@solana/kit";
import { coreInstruction, mintOpAccounts } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const operator = await loadKeypair(required(args, "operator"));
const mint = address(required(args, "mint"));
const resume = args.resume === "true";

const ix = coreInstruction(resume ? "resume" : "pause", await mintOpAccounts(resume ? "Unpauser" : "Pauser", operator, mint), new Uint8Array());
console.log(`${resume ? "resume" : "pause"}: ${await send(operator, [ix])}`);
