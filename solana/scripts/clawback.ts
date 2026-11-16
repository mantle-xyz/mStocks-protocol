// Moves tokens out of a (blacklisted) account into custody as the permanent delegate. Signed by the
// compliance admin: a keypair signs and sends (devnet / local), a Squads address prints the
// instruction for a Squads proposal (mainnet). The source always ends frozen; freeze it first.
//   tsx scripts/clawback.ts --payer <keypair> --compliance-admin <keypair.json|squads pubkey> --mint <mint>
//     --source <token account> --destination <custody token account> --amount <raw>
import { address } from "@solana/kit";
import { adminAddress, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { authorityPda, configPda, coreInstruction, encodeU64, mintStatePda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required } from "./lib/env.ts";

const args = parseArgs();
const payer = await loadKeypair(required(args, "payer"));
const complianceAdmin = await resolveAdmin(required(args, "compliance-admin"));
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
