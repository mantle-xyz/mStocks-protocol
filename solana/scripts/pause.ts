// Pauses (Pauser role) or resumes (Unpauser role) one mint. --operator is a keypair file (signs and
// sends) or, for a multisig role holder such as the mainnet Unpauser, its Squads multisig address
// (the action is printed as a base58 transaction message for the Squads app).
//   tsx scripts/pause.ts --operator <keypair.json|squads multisig> --mint <mint> [--resume]
// With --resume and no --operator, the network config's unpauser (the multisig) is used.
import { address } from "@solana/kit";
import { resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { config } from "./lib/config.ts";
import { coreInstruction, mintOpAccounts } from "./lib/core.ts";
import { parseArgs, required } from "./lib/env.ts";

const args = parseArgs(["operator", "mint", "resume"]);
const resume = args.resume === "true";
const unpausers = config?.roles.unpauser ?? [];
const operator = await resolveAdmin(
  args.operator ?? (resume && unpausers.length === 1 ? unpausers[0] : required(args, "operator")),
);
const mint = address(required(args, "mint"));
const label = resume ? "resume" : "pause";

const ix = coreInstruction(
  label,
  await mintOpAccounts(resume ? "Unpauser" : "Pauser", operator, mint),
  new Uint8Array(),
);
await sendOrPrint(null, operator, ix, label);
