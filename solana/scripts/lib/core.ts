// Minimal client for the mstocks-core program, driven by the Anchor IDL: discriminators, account
// order and writable/signer flags all come from idl/mstocks_core.json, the committed IDL of the
// program (program.ts build checks it matches the build), so the scripts run without a build.
import { readFileSync } from "node:fs";
import {
  AccountRole,
  address,
  createSolanaRpc,
  fetchEncodedAccount,
  getBase58Decoder,
  getAddressDecoder,
  getAddressEncoder,
  getProgramDerivedAddress,
  getUtf8Encoder,
  type Address,
  type Instruction,
  type KeyPairSigner,
} from "@solana/kit";
import { config } from "./config.ts";
import { rpc, withRetry } from "./env.ts";

export const idl = JSON.parse(
  readFileSync(new URL("../../idl/mstocks_core.json", import.meta.url), "utf8"),
);

export const CORE_PROGRAM_ID: Address = address(idl.address);
if (config && config.program.id !== CORE_PROGRAM_ID)
  throw new Error(`config program.id ${config.program.id} is not the built program ${CORE_PROGRAM_ID}`);
export const TOKEN_2022_PROGRAM_ID = address("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
export const BPF_LOADER_UPGRADEABLE = address("BPFLoaderUpgradeab1e11111111111111111111111");

const ROLES: string[] = idl.types.find((t: { name: string }) => t.name === "Role").type.variants.map(
  (v: { name: string }) => v.name,
);
export type RoleName = (typeof ROLES)[number];

const enc = getAddressEncoder();
const utf8 = getUtf8Encoder();

type Seeds = Parameters<typeof getProgramDerivedAddress>[0]["seeds"];

async function pda(seeds: Seeds, program = CORE_PROGRAM_ID): Promise<Address> {
  const [found] = await getProgramDerivedAddress({ programAddress: program, seeds });
  return found;
}

export const configPda = () => pda([utf8.encode("config")]);
export const authorityPda = () => pda([utf8.encode("authority")]);
export const mintStatePda = (mint: Address) => pda([utf8.encode("mint"), enc.encode(mint)]);
/** Index of the one mint registered for a Mantle token (20 raw address bytes). */
export const mantleTokenPda = (token: Uint8Array) => pda([utf8.encode("mantle_token"), token]);
export const rolePda = (role: RoleName, member: Address) =>
  pda([utf8.encode("role"), Uint8Array.of(roleIndex(role)), enc.encode(member)]);
export const programDataPda = () => pda([enc.encode(CORE_PROGRAM_ID)], BPF_LOADER_UPGRADEABLE);

export function roleIndex(role: string): number {
  const i = ROLES.indexOf(role);
  if (i < 0) throw new Error(`unknown role ${role}; expected one of ${ROLES.join(", ")}`);
  return i;
}

/** Roles governed by the compliance admin (Role::is_compliance); the admin governs the others. */
export const COMPLIANCE_ROLES = ["Pauser", "Unpauser", "Freezer", "Unfreezer", "Clawback"];
/** Every Core role name, in the program's enum order (= seed). */
export const ROLE_NAMES_IN_ORDER: readonly string[] = ROLES;

const ROLE_ENTRY_DISCRIMINATOR = Uint8Array.from([161, 238, 39, 6, 64, 179, 124, 31]);
/** On-chain holders of every role (RoleEntry: discriminator, role u8, member). Needs getProgramAccounts. */
export async function roleHolders(rpcUrl: string): Promise<Map<string, Set<Address>>> {
  const accounts = await withRetry(() =>
    createSolanaRpc(rpcUrl)
      .getProgramAccounts(CORE_PROGRAM_ID, {
        encoding: "base64",
        filters: [
          { dataSize: 42n },
          { memcmp: { offset: 0n, bytes: getBase58Decoder().decode(ROLE_ENTRY_DISCRIMINATOR) as never, encoding: "base58" } },
        ],
      })
      .send(),
  );
  const dec = getAddressDecoder();
  const out = new Map<string, Set<Address>>(ROLES.map((r) => [r, new Set<Address>()]));
  for (const { account } of accounts) {
    const d = Buffer.from(account.data[0], "base64");
    out.get(ROLES[d[8]])!.add(dec.decode(d.subarray(9, 41)));
  }
  return out;
}

export type CoreConfig = {
  admin: Address;
  pendingAdmin: Address | null;
  hookAuthority: Address;
  minNotice: bigint;
  maxHorizon: bigint;
  complianceAdmin: Address;
  pendingComplianceAdmin: Address | null;
};

/** Reads the Config account (Borsh: an Option is one byte when None), or null before `initialize`. */
export async function fetchConfig(): Promise<CoreConfig | null> {
  const acc = await withRetry(async () => fetchEncodedAccount(rpc, await configPda()));
  if (!acc.exists) return null;
  const d = acc.data;
  const dec = getAddressDecoder();
  let o = 8;
  const key = () => dec.decode(d.subarray(o, (o += 32)));
  const opt = () => (d[o++] === 1 ? key() : null);
  const i64 = () => {
    const v = new DataView(d.buffer, d.byteOffset + o, 8).getBigInt64(0, true);
    o += 8;
    return v;
  };
  const head = { admin: key(), pendingAdmin: opt(), hookAuthority: key(), minNotice: i64(), maxHorizon: i64() };
  o += 2; // bump, authority_bump
  return { ...head, complianceAdmin: key(), pendingComplianceAdmin: opt() };
}

/** The Mantle token (0x…) a mint is registered for, from its MintState; null when it is not registered. */
export async function mantleTokenOf(mint: Address): Promise<string | null> {
  const state = await withRetry(async () => fetchEncodedAccount(rpc, await mintStatePda(mint)));
  if (!state.exists) return null;
  // MintState: 8-byte discriminator, mint (32), mantle_token (20).
  return `0x${Buffer.from(state.data.subarray(40, 60)).toString("hex")}`;
}

/**
 * Throws unless `admin` governs `role` on chain. Core would reject it too, but for a multisig only
 * when the proposal executes, after its time lock.
 */
export async function assertRoleAdmin(role: string, admin: Address) {
  const config = await fetchConfig();
  if (!config) throw new Error("Core is not initialized");
  const compliance = COMPLIANCE_ROLES.includes(role);
  const governing = compliance ? config.complianceAdmin : config.admin;
  if (governing !== admin)
    throw new Error(`${role} is governed by the ${compliance ? "compliance admin" : "admin"} ${governing}, not ${admin}`);
}

type AccountInput = Address | KeyPairSigner;

/**
 * Builds a Core instruction. `accounts` is keyed by IDL account name; accounts with a fixed
 * address in the IDL (system / token programs) may be omitted.
 */
export function coreInstruction(name: string, accounts: Record<string, AccountInput>, args: Uint8Array): Instruction {
  const ix = idl.instructions.find((i: { name: string }) => i.name === name);
  if (!ix) throw new Error(`no instruction ${name} in IDL`);
  const metas = ix.accounts.map((a: { name: string; writable?: boolean; signer?: boolean; address?: string }) => {
    const input = accounts[a.name] ?? (a.address ? address(a.address) : undefined);
    if (!input) throw new Error(`${name}: missing account ${a.name}`);
    const role =
      a.signer && a.writable ? AccountRole.WRITABLE_SIGNER
      : a.signer ? AccountRole.READONLY_SIGNER
      : a.writable ? AccountRole.WRITABLE
      : AccountRole.READONLY;
    return typeof input === "string" ? { address: input, role } : { address: input.address, role, signer: input };
  });
  return { programAddress: CORE_PROGRAM_ID, accounts: metas, data: concat(Uint8Array.from(ix.discriminator), args) };
}

// --- Borsh argument encoding for the types Core uses ---

export const encodePubkey = (a: Address) => new Uint8Array(enc.encode(a));
export const encodeU8 = (v: number) => Uint8Array.of(v);

export function encodeI64(v: bigint): Uint8Array {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setBigInt64(0, v, true);
  return b;
}

export function encodeU128(v: bigint): Uint8Array {
  const b = new Uint8Array(16);
  const view = new DataView(b.buffer);
  view.setBigUint64(0, v & 0xffff_ffff_ffff_ffffn, true);
  view.setBigUint64(8, v >> 64n, true);
  return b;
}

/** Parses a 0x-prefixed 20-byte EVM address. */
export function encodeEvmAddress(hex: string): Uint8Array {
  const clean = hex.replace(/^0x/, "");
  if (!/^[0-9a-fA-F]{40}$/.test(clean)) throw new Error(`not a 20-byte hex address: ${hex}`);
  return Uint8Array.from(clean.match(/../g)!.map((h) => parseInt(h, 16)));
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** Mantle multipliers are 1e18 fixed point; Token-2022 stores f64. */
export const ONE_E18 = 10n ** 18n;
export const toF64 = (multiplier1e18: bigint) => Number(multiplier1e18) / 1e18;

export function encodeU64(v: bigint): Uint8Array {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setBigUint64(0, v, true);
  return b;
}

export function encodeString(s: string): Uint8Array {
  const bytes = new TextEncoder().encode(s);
  const len = new Uint8Array(4);
  new DataView(len.buffer).setUint32(0, bytes.length, true);
  return concat(len, bytes);
}

/** Borsh encoding of Core's `MetadataField`: Name | Symbol | Uri | Key(String). */
export function encodeMetadataField(field: string): Uint8Array {
  const fixed = ["name", "symbol", "uri"].indexOf(field);
  return fixed >= 0 ? Uint8Array.of(fixed) : concat(Uint8Array.of(3), encodeString(field));
}

/** Accounts shared by every operational instruction on one registered mint. */
export async function mintOpAccounts(role: RoleName, operator: KeyPairSigner | Address, mint: Address) {
  return {
    operator,
    config: await configPda(),
    role_entry: await rolePda(role, typeof operator === "string" ? operator : operator.address),
    mint,
    mint_state: await mintStatePda(mint),
    authority: await authorityPda(),
  };
}

/** Appends extra (remaining) accounts to an instruction. */
export function withRemaining(ix: Instruction, accounts: Address[], writable = true): Instruction {
  const role = writable ? AccountRole.WRITABLE : AccountRole.READONLY;
  return { ...ix, accounts: [...ix.accounts!, ...accounts.map((a) => ({ address: a, role }))] };
}

/** 8-byte discriminator of a Core account type, from the IDL. */
export function accountDiscriminator(name: string): Uint8Array {
  const acc = idl.accounts.find((a: { name: string }) => a.name === name);
  if (!acc) throw new Error(`no account ${name} in IDL`);
  return Uint8Array.from(acc.discriminator);
}
