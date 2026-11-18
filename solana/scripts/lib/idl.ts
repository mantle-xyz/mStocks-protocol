// The program's IDL on chain, where Anchor 1.x keeps it: the canonical account of Solana's Program
// Metadata program for the program with seed "idl", writable only by the program's upgrade
// authority. The content is the IDL JSON as UTF-8, zlib-compressed, format JSON, stored in the
// account — the Program Metadata CLI's defaults, so `anchor idl fetch` and explorers read it.
// Instruction encodings follow the program's client (@solana-program/program-metadata 0.5.1).
import { deflateSync, inflateSync } from "node:zlib";
import {
  AccountRole,
  address,
  fetchEncodedAccount,
  generateKeyPairSigner,
  getAddressEncoder,
  getProgramDerivedAddress,
  getUtf8Encoder,
  type Address,
  type Instruction,
  type KeyPairSigner,
} from "@solana/kit";
import { getCreateAccountInstruction, getTransferSolInstruction } from "@solana-program/system";
import { rpc, withRetry } from "./env.ts";

export const PROGRAM_METADATA = address("ProgM6JCCvbYkfKqJYHePx4xxSUSqJp7rh8Lyv7nk7S");
const RENT_SYSVAR = address("SysvarRent111111111111111111111111111111111");
const HEADER = 96; // account header before the data
const REALLOC_LIMIT = 10240; // most an instruction may grow an account by
const CHUNK = 900; // data per write transaction
const [ENCODING_UTF8, COMPRESSION_ZLIB, FORMAT_JSON, SOURCE_DIRECT] = [1, 2, 1, 0];
const SEED = (() => {
  const seed = new Uint8Array(16);
  seed.set(getUtf8Encoder().encode("idl"));
  return seed;
})();
enum Op { Write = 0, Initialize = 1, SetAuthority = 2, SetData = 3, Trim = 5, Close = 6, Allocate = 7, Extend = 8 }

export const idlAccount = async (program: Address) =>
  (await getProgramDerivedAddress({ programAddress: PROGRAM_METADATA, seeds: [getAddressEncoder().encode(program), SEED] }))[0];

/** A signer, or the address of one that signs elsewhere (a multisig vault). */
type Authority = KeyPairSigner | Address;
const signerMeta = (a: Authority) =>
  typeof a === "string"
    ? { address: a, role: AccountRole.READONLY_SIGNER }
    : { address: a.address, role: AccountRole.READONLY_SIGNER, signer: a };
const w = (a: Address) => ({ address: a, role: AccountRole.WRITABLE });
const r = (a: Address) => ({ address: a, role: AccountRole.READONLY });
const u16 = (n: number) => [n & 255, (n >> 8) & 255];
const u32 = (n: number) => [n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >>> 24) & 255];
const ix = (data: number[], accounts: Instruction["accounts"]): Instruction => ({
  programAddress: PROGRAM_METADATA,
  accounts,
  data: Uint8Array.from(data),
});
// An absent optional account is the Program Metadata program's own address; Allocate's system
// account defaults to the System program, as in the program's client.
const SYSTEM_PROGRAM = address("11111111111111111111111111111111");
const allocate = (buffer: Address, authority: Authority, program?: Address, programData?: Address, seeded = false) =>
  ix([Op.Allocate, ...(seeded ? SEED : [])], [w(buffer), signerMeta(authority), r(program ?? PROGRAM_METADATA), r(programData ?? PROGRAM_METADATA), r(SYSTEM_PROGRAM)]);
const write = (buffer: Address, authority: Authority, offset: number, data: Uint8Array) =>
  ix([Op.Write, ...u32(offset), ...data], [w(buffer), signerMeta(authority), r(PROGRAM_METADATA)]);
const initialize = (metadata: Address, authority: Authority, program: Address, programData: Address) =>
  ix([Op.Initialize, ...SEED, ENCODING_UTF8, COMPRESSION_ZLIB, FORMAT_JSON, SOURCE_DIRECT],
    [w(metadata), signerMeta(authority), r(program), r(programData), r(PROGRAM_METADATA)]);
const setData = (metadata: Address, authority: Authority, buffer: Address, program: Address, programData: Address) =>
  ix([Op.SetData, ENCODING_UTF8, COMPRESSION_ZLIB, FORMAT_JSON, SOURCE_DIRECT],
    [w(metadata), signerMeta(authority), w(buffer), r(program), r(programData)]);
const setAuthority = (account: Address, authority: Authority, newAuthority: Address) =>
  ix([Op.SetAuthority, 1, ...getAddressEncoder().encode(newAuthority)],
    [w(account), signerMeta(authority), r(PROGRAM_METADATA), r(PROGRAM_METADATA)]);
const extend = (account: Address, authority: Authority, program: Address, programData: Address, length: number) =>
  ix([Op.Extend, ...u16(length)], [w(account), signerMeta(authority), r(program), r(programData)]);
const trim = (account: Address, authority: Authority, program: Address, programData: Address, destination: Address) =>
  ix([Op.Trim], [w(account), signerMeta(authority), r(program), r(programData), w(destination), r(RENT_SYSVAR)]);
const close = (account: Address, authority: Authority, destination: Address) =>
  ix([Op.Close], [w(account), signerMeta(authority), r(PROGRAM_METADATA), r(PROGRAM_METADATA), w(destination)]);

const extendAll = (account: Address, authority: Authority, program: Address, programData: Address, growth: number) =>
  Array.from({ length: Math.ceil(growth / REALLOC_LIMIT) }, (_, i) =>
    extend(account, authority, program, programData, Math.min(REALLOC_LIMIT, growth - i * REALLOC_LIMIT)));
const rent = async (dataLength: number) =>
  withRetry(() => rpc.getMinimumBalanceForRentExemption(BigInt(HEADER + dataLength)).send());

/** The IDL JSON as stored: UTF-8, zlib-compressed. */
export const encodeIdl = (json: string) => Uint8Array.from(deflateSync(Buffer.from(json, "utf8")));
/** Same IDL, ignoring JSON formatting. */
export const sameIdl = (a: string, b: string) => JSON.stringify(JSON.parse(a)) === JSON.stringify(JSON.parse(b));

/** The program's IDL on chain (decoded JSON text), or null when there is none. */
export async function readIdl(program: Address) {
  const metadata = await idlAccount(program);
  const acc = await withRetry(() => fetchEncodedAccount(rpc, metadata));
  if (!acc.exists || acc.data[0] !== 2) return null;
  const d = acc.data;
  const [encoding, compression] = [d[83], d[84]];
  const length = new DataView(d.buffer, d.byteOffset + 87, 4).getUint32(0, true);
  let bytes: Uint8Array = d.subarray(HEADER, HEADER + length);
  if (compression === COMPRESSION_ZLIB) bytes = inflateSync(bytes);
  else if (compression !== 0) throw new Error(`IDL compression ${compression} is not supported`);
  if (encoding !== ENCODING_UTF8 && encoding !== 0) throw new Error(`IDL encoding ${encoding} is not supported`);
  return { metadata, text: Buffer.from(bytes).toString("utf8"), dataLength: length, lamports: acc.lamports };
}

/** Transactions (in order) creating the IDL account; `authority` must be the program's upgrade authority. */
export async function createIdl(payer: KeyPairSigner, authority: KeyPairSigner, program: Address, programData: Address, data: Uint8Array) {
  const metadata = await idlAccount(program);
  const txs: Instruction[][] = [[
    getTransferSolInstruction({ source: payer, destination: metadata, amount: await rent(data.length) }),
    allocate(metadata, authority, program, programData, true),
    ...(data.length > REALLOC_LIMIT ? extendAll(metadata, authority, program, programData, data.length) : []),
  ]];
  for (let o = 0; o < data.length; o += CHUNK) txs.push([write(metadata, authority, o, data.subarray(o, o + CHUNK))]);
  txs.push([initialize(metadata, authority, program, programData)]);
  return txs;
}

/** Transactions writing `data` into a new buffer account, then handing the buffer to `finalAuthority`. */
export async function writeBuffer(payer: KeyPairSigner, data: Uint8Array, finalAuthority: Address) {
  const buffer = await generateKeyPairSigner();
  const txs: Instruction[][] = [[
    getCreateAccountInstruction({ payer, newAccount: buffer, lamports: await rent(data.length), space: BigInt(HEADER + data.length), programAddress: PROGRAM_METADATA }),
    allocate(buffer.address, buffer),
  ]];
  for (let o = 0; o < data.length; o += CHUNK) txs.push([write(buffer.address, buffer, o, data.subarray(o, o + CHUNK))]);
  txs.push([setAuthority(buffer.address, buffer, finalAuthority)]);
  return { buffer: buffer.address, txs };
}

/**
 * Replaces the IDL with a buffer's content, signed by the upgrade authority: grows the account when
 * needed (its rent is topped up beforehand, see topUp), copies the buffer, closes it and trims the
 * account when the IDL shrank. Refunds go to `destination`.
 */
export function replaceIdl(metadata: Address, authority: Authority, buffer: Address, program: Address, programData: Address,
  oldLength: number, newLength: number, destination: Address): Instruction[] {
  const growth = newLength - oldLength;
  return [
    ...(growth > REALLOC_LIMIT ? extendAll(metadata, authority, program, programData, growth) : []),
    setData(metadata, authority, buffer, program, programData),
    close(buffer, authority, destination),
    ...(growth < 0 ? [trim(metadata, authority, program, programData, destination)] : []),
  ];
}

/** Lamports the IDL account needs for `newLength` bytes of data beyond what it holds (0 if none). */
export async function topUp(currentLamports: bigint, newLength: number): Promise<bigint> {
  const needed = await rent(newLength);
  return needed > currentLamports ? needed - currentLamports : 0n;
}
export const topUpInstruction = (payer: KeyPairSigner, metadata: Address, amount: bigint) =>
  getTransferSolInstruction({ source: payer, destination: metadata, amount });
