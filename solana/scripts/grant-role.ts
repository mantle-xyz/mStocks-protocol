// Grants a Core role. Roles: MultiplierScheduler, Pauser, Unpauser, Freezer, Unfreezer, Clawback, MetadataOps.
//   tsx scripts/grant-role.ts --payer <keypair> --admin <keypair.json|squads pubkey> --role Freezer --member <pubkey>
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
  "grant_role",
  // In a Squads proposal only the vault signs, so the vault (admin) also pays rent.
  { payer: typeof admin === "string" ? admin : payer, admin, config: await configPda(), role_entry: await rolePda(role, member) },
  concat(encodeU8(roleIndex(role)), encodePubkey(member)),
);
await sendOrPrint(payer, admin, ix, `grant ${role} to ${member} (admin ${adminAddress(admin)})`);
