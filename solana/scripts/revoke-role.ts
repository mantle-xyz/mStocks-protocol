// Revokes a Core role (admin; the role account's rent returns to the admin).
//   tsx scripts/revoke-role.ts --payer <keypair> --admin <keypair.json|squads multisig> --role Freezer \
//     --member <pubkey|squads multisig> [--squads-member <keypair.json>]
// --admin is the admin that governs the role: the compliance admin for Pauser, Unpauser, Freezer,
// Unfreezer and the retired Clawback, the admin for the others.
import { adminAddress, resolveAdmin, sendOrPrint, signerAddress } from "./lib/admin.ts";
import { assertRoleAdmin, configPda, coreInstruction, concat, encodePubkey, encodeU8, roleIndex, rolePda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required } from "./lib/env.ts";

const args = parseArgs();
const payer = await loadKeypair(required(args, "payer"));
const admin = await resolveAdmin(required(args, "admin"));
const role = required(args, "role");
await assertRoleAdmin(role, adminAddress(admin)); // fail now, not when a multisig proposal executes
const member = await signerAddress(required(args, "member"));

const ix = coreInstruction(
  "revoke_role",
  { admin, config: await configPda(), role_entry: await rolePda(role, member) },
  concat(encodeU8(roleIndex(role)), encodePubkey(member)),
);
await sendOrPrint(payer, admin, ix, `revoke ${role} from ${member} (admin ${adminAddress(admin)})`);
