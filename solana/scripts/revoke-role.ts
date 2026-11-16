// Revokes a Core role (admin; the role account's rent returns to the admin).
//   tsx scripts/revoke-role.ts --payer <keypair> --admin <keypair.json|squads pubkey> --role Freezer --member <pubkey>
// --admin is the admin that governs the role: the compliance admin for Pauser, Unpauser, Freezer,
// Unfreezer and Clawback, the admin for the others.
import { address } from "@solana/kit";
import { adminAddress, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { configPda, coreInstruction, concat, encodePubkey, encodeU8, roleIndex, rolePda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required } from "./lib/env.ts";

const args = parseArgs();
const payer = await loadKeypair(required(args, "payer"));
const admin = await resolveAdmin(required(args, "admin"));
const role = required(args, "role");
const member = address(required(args, "member"));

const ix = coreInstruction(
  "revoke_role",
  { admin, config: await configPda(), role_entry: await rolePda(role, member) },
  concat(encodeU8(roleIndex(role)), encodePubkey(member)),
);
await sendOrPrint(payer, admin, ix, `revoke ${role} from ${member} (admin ${adminAddress(admin)})`);
