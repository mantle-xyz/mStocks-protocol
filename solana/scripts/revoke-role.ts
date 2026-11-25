// Revokes a Core role (admin; the role account's rent returns to the admin).
//   tsx scripts/revoke-role.ts [--payer <keypair>] [--admin <keypair.json|squads multisig>] --role Freezer \
//     --member <pubkey|squads multisig>
// --admin (default: from the network config) is the admin that governs the role: the compliance
// admin for Pauser, Unpauser, Freezer, Unfreezer and the retired Clawback, the admin for the others.
import { adminAddress, optionalPayer, resolveAdmin, revokeRoleIx, roleAdminSetting, sendOrPrint, signerAddress } from "./lib/admin.ts";
import { assertRoleAdmin } from "./lib/core.ts";
import { parseArgs, required } from "./lib/env.ts";

const args = parseArgs(["admin", "payer", "role", "member"]);
const role = required(args, "role");
const admin = await resolveAdmin(roleAdminSetting(role, args.admin));
const payer = await optionalPayer(args.payer, admin);
await assertRoleAdmin(role, adminAddress(admin)); // fail now, not when a multisig proposal executes
const member = await signerAddress(required(args, "member"));
await sendOrPrint(payer, admin, await revokeRoleIx(role, member, admin), `revoke ${role} from ${member} (admin ${adminAddress(admin)})`);
