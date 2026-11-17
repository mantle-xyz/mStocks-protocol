// Admin actions are signed by a Squads multisig on mainnet. An admin argument is one of:
//   <keypair.json>        signs and sends directly (devnet / local);
//   <multisig address>    a Squads v4 multisig: its vault (index 0) is the signer; the script prints
//                         the action as a base58 transaction for the Squads app, where a member
//                         imports it and the members approve it with their Ledgers;
//   <any other address>   e.g. the vault itself: the same, printed for that address as signer.
import { address, type Address, type Instruction, type KeyPairSigner } from "@solana/kit";
import { asSquadsMultisig, squadsImport, vaultAddress } from "./squads.ts";
import { describeInstruction } from "./describe.ts";
import { ROLE_NAMES, setting } from "./config.ts";
import { COMPLIANCE_ROLES, concat, configPda, coreInstruction, encodePubkey, encodeU8, roleIndex, rolePda } from "./core.ts";
import { loadKeypair, send } from "./env.ts";
import type { PublicKey } from "@solana/web3.js";

export type Admin = KeyPairSigner | Address;

const multisigOfVault = new Map<Address, PublicKey>();

export async function resolveAdmin(value: string): Promise<Admin> {
  return value.endsWith(".json") ? loadKeypair(value) : signerAddress(value);
}

/**
 * The address that signs on chain for `value`: a Squads multisig resolves to its vault, any other
 * address is itself. Use it wherever an address is stored as a signer (admins, role members, hook
 * authority): a multisig account cannot sign, so storing one would brick that authority.
 */
export async function signerAddress(value: string): Promise<Address> {
  const given = address(value);
  const multisig = await asSquadsMultisig(given);
  if (!multisig) return given;
  const vault = vaultAddress(multisig);
  if (!multisigOfVault.has(vault)) console.log(`${given} is a Squads multisig; its vault ${vault} signs`);
  multisigOfVault.set(vault, multisig);
  return vault;
}

export const adminAddress = (admin: Admin): Address => (typeof admin === "string" ? admin : admin.address);

/** The admin that governs `role`: --admin, else the config's admin or compliance admin. */
export function roleAdminSetting(role: string, value: string | undefined): string {
  return COMPLIANCE_ROLES.includes(role)
    ? setting(value, "admins.compliance_admin", "admin")
    : setting(value, "admins.admin", "admin");
}

/** --payer when given; else a keypair admin pays itself, and a multisig needs none (its vault pays). */
export async function optionalPayer(value: string | undefined, admin: Admin): Promise<KeyPairSigner | null> {
  if (value) return loadKeypair(value);
  return typeof admin === "string" ? null : admin;
}

/** grant_role. In a Squads proposal only the vault signs, so the vault (admin) also pays the rent. */
export async function grantRoleIx(role: string, member: Address, admin: Admin, payer: KeyPairSigner | null): Promise<Instruction> {
  return coreInstruction(
    "grant_role",
    { payer: typeof admin === "string" ? admin : (payer ?? admin), admin, config: await configPda(), role_entry: await rolePda(role, member) },
    concat(encodeU8(roleIndex(role)), encodePubkey(member)),
  );
}

/** revoke_role; the role account's rent returns to the admin. */
export async function revokeRoleIx(role: string, member: Address, admin: Admin): Promise<Instruction> {
  return coreInstruction(
    "revoke_role",
    { admin, config: await configPda(), role_entry: await rolePda(role, member) },
    concat(encodeU8(roleIndex(role)), encodePubkey(member)),
  );
}

/** The config's role holders by Core role name, multisig accounts resolved to their vaults. */
export async function configuredRoles(roles: Record<string, string[]>): Promise<Map<string, Set<Address>>> {
  const out = new Map<string, Set<Address>>(Object.values(ROLE_NAMES).map((r) => [r, new Set<Address>()]));
  for (const [key, members] of Object.entries(roles)) {
    const role = ROLE_NAMES[key];
    if (!role || role === "Clawback") throw new Error(`roles.${key}: unknown or retired role`);
    for (const m of members) out.get(role)!.add(await signerAddress(m));
  }
  return out;
}

/**
 * Keypair admin: signs and sends (`payer` pays, or the admin when there is no payer). Multisig
 * (Squads vault): prints the action for the Squads app, see printSquadsImport.
 */
export async function sendOrPrint(
  payer: KeyPairSigner | null,
  admin: Admin,
  instructions: Instruction | Instruction[],
  label: string,
) {
  const ixs = Array.isArray(instructions) ? instructions : [instructions];
  if (typeof admin !== "string") {
    console.log(`${label}: ${await send(payer ?? admin, ixs)}`);
    return;
  }
  await printSquadsImport(admin, ixs, label);
}

/**
 * Prints a multisig action: a readable list of the instructions (what the members approve) and the
 * base58 transaction a member imports into the Squads app (Transactions → TX Builder → Import);
 * the members then approve it with their Ledgers and execute it after the time lock. The last line
 * is "<label> base58: <transaction>".
 */
export async function printSquadsImport(vault: Address, ixs: Instruction[], label: string) {
  const multisig = multisigOfVault.get(vault);
  const { base58, size } = await squadsImport(vault, ixs);
  console.log(`${label}: signed by ${multisig ? `the Squads multisig ${multisig.toBase58()} (vault ${vault})` : `the vault ${vault}`};`);
  console.log(`  import the base58 transaction below into the Squads app (Transactions → TX Builder → Import), ${ixs.length} instruction(s):`);
  ixs.forEach((ix, i) => console.log(`  ${i + 1}. ${describeInstruction(ix)}`));
  if (size > 1232) throw new Error(`the transaction is ${size} bytes, over the 1232-byte limit; split the action`);
  console.log(`${label} base58: ${base58}`);
}
