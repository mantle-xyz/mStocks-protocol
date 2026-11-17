// Grants a Core role. Roles: MultiplierScheduler, Pauser, Unpauser, Freezer, Unfreezer, MetadataOps, MintRegistrar.
//   tsx scripts/grant-role.ts [--payer <keypair>] [--admin <keypair.json|squads multisig>] --role Freezer \
//     --member <pubkey|squads multisig>
// --admin (default: from the network config) is the admin that governs the role: the compliance
// admin for Pauser, Unpauser, Freezer, Unfreezer (and revoking a retired Clawback), the admin for
// the others. Clawback can no longer be granted: clawback.ts is signed by the compliance admin.
import { adminAddress, grantRoleIx, optionalPayer, resolveAdmin, roleAdminSetting, sendOrPrint, signerAddress } from "./lib/admin.ts";
import { assertRoleAdmin } from "./lib/core.ts";
import { parseArgs, required } from "./lib/env.ts";

const args = parseArgs();
const role = required(args, "role");
const admin = await resolveAdmin(roleAdminSetting(role, args.admin));
const payer = await optionalPayer(args.payer, admin);
await assertRoleAdmin(role, adminAddress(admin)); // fail now, not when a multisig proposal executes
// A Squads multisig member is granted through its vault, the address that signs.
const member = await signerAddress(required(args, "member"));
await sendOrPrint(payer, admin, await grantRoleIx(role, member, admin, payer), `grant ${role} to ${member} (admin ${adminAddress(admin)})`);
