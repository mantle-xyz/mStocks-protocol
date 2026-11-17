// Moves tokens out of a (blacklisted) account into custody as the permanent delegate. Signed by the
// compliance admin: a keypair signs and sends (devnet / local); a Squads multisig address creates
// the Squads proposal with --squads-member, or prints the instruction (mainnet). The source always
// ends frozen; freeze it first.
//   tsx scripts/clawback.ts [--payer <keypair>] [--compliance-admin <keypair.json|squads multisig>] --mint <mint>
//     --source <token account> --destination <custody token account> --amount <raw> [--squads-member <keypair.json>]
import { address } from "@solana/kit";
import { adminAddress, optionalPayer, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { setting } from "./lib/config.ts";
import { authorityPda, configPda, coreInstruction, encodeU64, mintStatePda } from "./lib/core.ts";
import { parseArgs, required } from "./lib/env.ts";

const args = parseArgs();
const complianceAdmin = await resolveAdmin(setting(args["compliance-admin"], "admins.compliance_admin", "compliance-admin"));
const payer = await optionalPayer(args.payer, complianceAdmin);
const mint = address(required(args, "mint"));

const ix = coreInstruction(
  "clawback",
  {
    compliance_admin: complianceAdmin,
    config: await configPda(),
    mint,
    mint_state: await mintStatePda(mint),
    source: address(required(args, "source")),
    destination: address(required(args, "destination")),
    authority: await authorityPda(),
  },
  encodeU64(BigInt(required(args, "amount"))),
);
await sendOrPrint(payer, complianceAdmin, ix, `clawback (compliance admin ${adminAddress(complianceAdmin)})`);
