// Brings the on-chain role holders in line with the network config: grants every configured holder
// that is missing and revokes every holder the config does not list (including any holder of the
// retired Clawback). The changes are grouped by the admin that governs them, so each admin signs
// once: one transaction for a keypair admin; for a multisig, one base58 transaction message for the
// Squads app (a member imports it, the members approve it with their Ledgers). A group too large for
// one transaction is split, in order, into "<admin> roles 1/n", "2/n", …: import each. The vault pays
// the rent of new role accounts, so keep a little SOL in it.
//   NETWORK=mainnet tsx scripts/sync-roles.ts [--dry-run]
//     [--admin <keypair.json|squads multisig>] [--compliance-admin <keypair.json|squads multisig>]
// --admin / --compliance-admin default to the config's; pass a keypair file on a test network where
// an admin is a plain key.
import { type Instruction } from "@solana/kit";
import { adminAddress, configuredRoles, grantRoleIx, resolveAdmin, revokeRoleIx, sendOrPrintBatches, signerAddress, type Admin } from "./lib/admin.ts";
import { config, setting } from "./lib/config.ts";
import { COMPLIANCE_ROLES, fetchConfig, ROLE_NAMES_IN_ORDER, roleHolders } from "./lib/core.ts";
import { parseArgs, RPC_URL } from "./lib/env.ts";

const args = parseArgs(["admin", "compliance-admin", "roles-rpc", "dry-run"]);
if (!config) throw new Error("set NETWORK=mainnet|testnet: sync-roles works from the network config");
const admins: Record<"admin" | "compliance", Admin> = {
  admin: await resolveAdmin(setting(args.admin, "admins.admin", "admin")),
  compliance: await resolveAdmin(setting(args["compliance-admin"], "admins.compliance_admin", "compliance-admin")),
};

// The admins on chain must be the ones that will sign, or every change would fail when it executes.
const onChain = await fetchConfig();
if (!onChain) throw new Error("Core is not initialized; run init-core.ts first");
const expected = { admin: await signerAddress(config.admins.admin), compliance: await signerAddress(config.admins.compliance_admin) };
for (const [k, chainValue] of [["admin", onChain.admin], ["compliance", onChain.complianceAdmin]] as const) {
  if (adminAddress(admins[k]) !== chainValue) throw new Error(`${k} admin on chain is ${chainValue}, not ${adminAddress(admins[k])}`);
  if (expected[k] !== chainValue) console.log(`warning: config ${k} admin resolves to ${expected[k]}, chain has ${chainValue}`);
}

const want = await configuredRoles(config.roles);
const have = await roleHolders(args["roles-rpc"] ?? config.solana.roles_rpc ?? RPC_URL);
const changes: Record<"admin" | "compliance", { ixs: Instruction[]; lines: string[] }> = {
  admin: { ixs: [], lines: [] },
  compliance: { ixs: [], lines: [] },
};
for (const role of ROLE_NAMES_IN_ORDER) {
  const group = COMPLIANCE_ROLES.includes(role) ? "compliance" : "admin";
  const signer = admins[group];
  const wanted = want.get(role) ?? new Set();
  const held = have.get(role) ?? new Set();
  for (const member of wanted)
    if (!held.has(member)) {
      changes[group].ixs.push(await grantRoleIx(role, member, signer, null));
      changes[group].lines.push(`grant ${role} → ${member}`);
    }
  for (const member of held)
    if (!wanted.has(member)) {
      changes[group].ixs.push(await revokeRoleIx(role, member, signer));
      changes[group].lines.push(`revoke ${role} ← ${member}`);
    }
}

for (const group of ["admin", "compliance"] as const) {
  const { ixs, lines } = changes[group];
  const who = `${group === "admin" ? "admin" : "compliance admin"} ${adminAddress(admins[group])}`;
  if (!ixs.length) {
    console.log(`${who}: roles match the config`);
    continue;
  }
  console.log(`${who}: ${lines.length} change(s)\n${lines.map((l) => `  ${l}`).join("\n")}`);
  if (args["dry-run"] !== "true") await sendOrPrintBatches(null, admins[group], ixs, `${group} roles`);
}
