// Minimal client for the mstocks-core program, driven by the Anchor IDL: discriminators, account
// order and writable/signer flags all come from target/idl/mstocks_core.json.
import { readFileSync } from "node:fs";
import {
  AccountRole,
  address,
  getAddressEncoder,
  getProgramDerivedAddress,
  getUtf8Encoder,
  type Address,
  type Instruction,
  type KeyPairSigner,
} from "@solana/kit";

const idl = JSON.parse(
  readFileSync(new URL("../../target/idl/mstocks_core.json", import.meta.url), "utf8"),
);

export const CORE_PROGRAM_ID: Address = address(idl.address);
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
export const rolePda = (role: RoleName, member: Address) =>
  pda([utf8.encode("role"), Uint8Array.of(roleIndex(role)), enc.encode(member)]);
export const programDataPda = () => pda([enc.encode(CORE_PROGRAM_ID)], BPF_LOADER_UPGRADEABLE);

export function roleIndex(role: string): number {
  const i = ROLES.indexOf(role);
  if (i < 0) throw new Error(`unknown role ${role}; expected one of ${ROLES.join(", ")}`);
  return i;
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
export async function mintOpAccounts(role: RoleName, operator: KeyPairSigner, mint: Address) {
  return {
    operator,
    config: await configPda(),
    role_entry: await rolePda(role, operator.address),
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
