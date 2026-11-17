// Grants a Core role. Roles: MultiplierScheduler, Pauser, Unpauser, Freezer, Unfreezer, MetadataOps, MintRegistrar.
//   tsx scripts/grant-role.ts --payer <keypair> --admin <keypair.json|squads multisig> --role Freezer \
//     --member <pubkey|squads multisig> [--squads-member <keypair.json>]
// --admin is the admin that governs the role: the compliance admin for Pauser, Unpauser, Freezer,
// Unfreezer (and revoking a retired Clawback), the admin for the others. Clawback can no longer be
// granted: clawback.ts is signed by the compliance admin.
import { adminAddress, resolveAdmin, sendOrPrint, signerAddress } from "./lib/admin.ts";
import { configPda, coreInstruction, concat, encodePubkey, encodeU8, roleIndex, rolePda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required } from "./lib/env.ts";

const args = parseArgs();
const payer = await loadKeypair(required(args, "payer"));
const admin = await resolveAdmin(required(args, "admin"));
const role = required(args, "role");
// A Squads multisig member is granted through its vault, the address that signs.
const member = await signerAddress(required(args, "member"));

const ix = coreInstruction(
  "grant_role",
  // In a Squads proposal only the vault signs, so the vault (admin) also pays rent.
  { payer: typeof admin === "string" ? admin : payer, admin, config: await configPda(), role_entry: await rolePda(role, member) },
  concat(encodeU8(roleIndex(role)), encodePubkey(member)),
);
await sendOrPrint(payer, admin, ix, `grant ${role} to ${member} (admin ${adminAddress(admin)})`);
