// Pauses (Pauser role) or resumes (Unpauser role) one mint. --operator is a keypair file (signs and
// sends) or, for a multisig role holder such as the mainnet Unpauser, its Squads multisig address
// (creates the Squads proposal with --squads-member, otherwise prints the instruction).
//   tsx scripts/pause.ts --operator <keypair.json|squads multisig> --mint <mint> [--resume]
//     [--squads-member <keypair.json>]
import { address } from "@solana/kit";
import { resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { coreInstruction, mintOpAccounts } from "./lib/core.ts";
import { parseArgs, required } from "./lib/env.ts";

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
await sendOrPrint(null, operator, ix, label);
