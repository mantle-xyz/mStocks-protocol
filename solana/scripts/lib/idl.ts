// The program's IDL on chain, where Anchor 1.x keeps it: the canonical account of Solana's Program
// Metadata program for the program with seed "idl", writable only by the program's upgrade
// authority. The content is the IDL JSON as UTF-8, zlib-compressed, format JSON, stored in the
// account — the Program Metadata CLI's defaults, so `anchor idl fetch` and explorers read it.
// Instruction encodings follow the program's client (@solana-program/program-metadata 0.5.1) and the
// account rules its program (solana-program/program-metadata) enforces.
//
// planIdl works out every transaction first, so nothing is spent on a change that cannot finish.
// The deployer pays and writes; whatever only the upgrade authority may sign comes back as
// instructions for it, which for a multisig go into its Squads transaction. A buffer handed to the
// vault can then be changed only by the vault, so the members approve fixed content.
import { deflateSync, inflateSync } from "node:zlib";
import {
  AccountRole,
  address,
  fetchEncodedAccount,
  generateKeyPairSigner,
  getAddressDecoder,
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
const SYSTEM_PROGRAM = address("11111111111111111111111111111111");
const RENT_SYSVAR = address("SysvarRent111111111111111111111111111111111");
const HEADER = 96; // account header before the data (metadata and buffer alike)
const REALLOC_LIMIT = 10240; // most an instruction may grow an account by
const CHUNK = 900; // data per write transaction
const [ENCODING_UTF8, COMPRESSION_ZLIB, FORMAT_JSON, SOURCE_DIRECT] = [1, 2, 1, 0];
const [BUFFER, METADATA] = [1, 2]; // account discriminators
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
// account is the System program, as in the program's client.
const allocate = (buffer: Address, authority: Authority, program?: Address, programData?: Address, seeded = false) =>
  ix([Op.Allocate, ...(seeded ? SEED : [])], [w(buffer), signerMeta(authority), r(program ?? PROGRAM_METADATA), r(programData ?? PROGRAM_METADATA), r(SYSTEM_PROGRAM)]);
const write = (buffer: Address, authority: Authority, offset: number, data: Uint8Array) =>
  ix([Op.Write, ...u32(offset), ...data], [w(buffer), signerMeta(authority), r(PROGRAM_METADATA)]);
/** Write without data: copies the whole of `source` (another buffer) to the start of `buffer`. */
const writeFrom = (buffer: Address, authority: Authority, source: Address) =>
  ix([Op.Write, ...u32(0)], [w(buffer), signerMeta(authority), r(source)]);
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
/** Close; `program`/`programData` let the upgrade authority close a canonical account it is not the set authority of. */
const close = (account: Address, authority: Authority, destination: Address, program?: Address, programData?: Address) =>
  ix([Op.Close], [w(account), signerMeta(authority), r(program ?? PROGRAM_METADATA), r(programData ?? PROGRAM_METADATA), w(destination)]);

const extendAll = (account: Address, authority: Authority, program: Address, programData: Address, growth: number) =>
  Array.from({ length: Math.ceil(growth / REALLOC_LIMIT) }, (_, i) =>
    extend(account, authority, program, programData, Math.min(REALLOC_LIMIT, growth - i * REALLOC_LIMIT)));
const rent = async (dataLength: number) =>
  withRetry(() => rpc.getMinimumBalanceForRentExemption(BigInt(HEADER + dataLength)).send());
const fund = (payer: KeyPairSigner, account: Address, amount: bigint) =>
  amount > 0n ? [getTransferSolInstruction({ source: payer, destination: account, amount })] : [];

/** The IDL JSON as stored: UTF-8, zlib-compressed. */
export const encodeIdl = (json: string) => Uint8Array.from(deflateSync(Buffer.from(json, "utf8")));
/** Same IDL, ignoring JSON formatting. */
export const sameIdl = (a: string, b: string) => JSON.stringify(JSON.parse(a)) === JSON.stringify(JSON.parse(b));

/**
 * What the program's IDL address holds: nothing (possibly prefunded lamports), a buffer (an upload
 * that never reached initialize; `authority` is the key that started it) or the IDL itself.
 */
export type IdlState = { metadata: Address; lamports: bigint } & (
  | { kind: "none" }
  | { kind: "buffer"; authority: Address | null }
  | { kind: "idl"; text: string; dataLength: number }
);

export async function idlState(program: Address): Promise<IdlState> {
  const metadata = await idlAccount(program);
  const acc = await withRetry(() => fetchEncodedAccount(rpc, metadata));
  if (!acc.exists || acc.programAddress !== PROGRAM_METADATA || acc.data.length === 0)
    return { metadata, lamports: acc.exists ? acc.lamports : 0n, kind: "none" };
  const d = acc.data;
  if (d[0] === BUFFER) {
    // Buffer: discriminator, program (32), authority (32, zero when none), …
    const authority = d.subarray(33, 65).some((b) => b !== 0) ? getAddressDecoder().decode(d.subarray(33, 65)) : null;
    return { metadata, lamports: acc.lamports, kind: "buffer", authority };
  }
  if (d[0] !== METADATA) throw new Error(`IDL account ${metadata} has unknown discriminator ${d[0]}`);
  const [encoding, compression] = [d[83], d[84]];
  const length = new DataView(d.buffer, d.byteOffset + 87, 4).getUint32(0, true);
  let bytes: Uint8Array = d.subarray(HEADER, HEADER + length);
  if (compression === COMPRESSION_ZLIB) bytes = inflateSync(bytes);
  else if (compression !== 0) throw new Error(`IDL compression ${compression} is not supported`);
  if (encoding !== ENCODING_UTF8 && encoding !== 0) throw new Error(`IDL encoding ${encoding} is not supported`);
  return { metadata, lamports: acc.lamports, kind: "idl", text: Buffer.from(bytes).toString("utf8"), dataLength: length };
}

/** The program's IDL on chain (decoded JSON text), or null when there is none. */
export async function readIdl(program: Address) {
  const s = await idlState(program);
  return s.kind === "idl" ? s : null;
}

/** Transactions writing `data` into the new keypair buffer `buffer`, then handing it to `finalAuthority`. */
async function writeBufferTxs(payer: KeyPairSigner, buffer: KeyPairSigner, data: Uint8Array, finalAuthority: Address) {
  const txs: Instruction[][] = [[
    getCreateAccountInstruction({ payer, newAccount: buffer, lamports: await rent(data.length), space: BigInt(HEADER + data.length), programAddress: PROGRAM_METADATA }),
    allocate(buffer.address, buffer),
  ]];
  for (let o = 0; o < data.length; o += CHUNK) txs.push([write(buffer.address, buffer, o, data.subarray(o, o + CHUNK))]);
  txs.push([setAuthority(buffer.address, buffer, finalAuthority)]);
  return txs;
}

/**
 * Making the on-chain IDL `data`: `deployerTxs` are signed by the deployer and sent first (buffer
 * writes, rent); `authorityIxs` are the upgrade authority's, for its Squads transaction (empty when
 * the deployer is the upgrade authority: everything is then in deployerTxs).
 */
export type IdlPlan = { summary: string; deployerTxs: Instruction[][]; authorityIxs: Instruction[] };

/**
 * Plans the IDL change without sending anything; null when the IDL on chain is already `json`.
 * `authority` is the program's upgrade authority, the deployer itself or a multisig vault.
 *   no IDL yet:         created (by the deployer directly, or by the vault from a buffer the deployer wrote);
 *   an unfinished upload: its buffer is closed first, then the IDL is created;
 *   another IDL:        replaced from a buffer; the account grows or shrinks with it.
 * Refunds (closed buffers, trimmed rent) go to the deployer.
 */
export async function planIdl(program: Address, programData: Address, deployer: KeyPairSigner, authority: Address, json: string): Promise<IdlPlan | null> {
  const data = encodeIdl(json);
  const state = await idlState(program);
  const { metadata } = state;
  if (state.kind === "idl" && sameIdl(state.text, json)) return null;
  const direct = authority === deployer.address;
  const signer: Authority = direct ? deployer : authority;
  const deployerTxs: Instruction[][] = [];
  const done = (summary: string, authorityIxs: Instruction[]): IdlPlan =>
    direct ? { summary, deployerTxs: authorityIxs.length ? [...deployerTxs, authorityIxs] : deployerTxs, authorityIxs: [] } : { summary, deployerTxs, authorityIxs };

  if (state.kind === "idl") {
    // Replace: the deployer writes a buffer for the authority and tops up the account's rent; the
    // authority grows the account if needed, copies the buffer in, closes it and trims any excess.
    const buffer = await generateKeyPairSigner();
    deployerTxs.push(...(await writeBufferTxs(deployer, buffer, data, authority)));
    const topUp = (await rent(data.length)) - state.lamports;
    if (topUp > 0n) deployerTxs.push(fund(deployer, metadata, topUp));
    const growth = data.length - state.dataLength;
    return done(`replace the IDL (${state.dataLength} → ${data.length} bytes) from buffer ${buffer.address}`, [
      ...(growth > REALLOC_LIMIT ? extendAll(metadata, signer, program, programData, growth) : []),
      setData(metadata, signer, buffer.address, program, programData),
      close(buffer.address, signer, deployer.address),
      ...(growth < 0 ? [trim(metadata, signer, program, programData, deployer.address)] : []),
    ]);
  }

  let prefunded = state.lamports;
  let summary = "";
  if (state.kind === "buffer") {
    // An upload that stopped before initialize. Its starter (the set authority) can close it, and so
    // can the upgrade authority as it is canonical.
    if (direct) deployerTxs.push([close(metadata, deployer, deployer.address, program, programData)]);
    else if (state.authority === deployer.address) deployerTxs.push([close(metadata, deployer, deployer.address)]);
    else throw new Error(`the IDL account ${metadata} holds an unfinished upload started by ${state.authority}; that key or the upgrade authority must close it first`);
    prefunded = 0n;
    summary = `close the unfinished upload at ${metadata}, then `;
  }
  const funding = fund(deployer, metadata, (await rent(data.length)) - prefunded);
  if (direct) {
    // Create: fund, allocate the canonical account, write the data in chunks, initialize.
    deployerTxs.push([...funding, allocate(metadata, deployer, program, programData, true),
      ...(data.length > REALLOC_LIMIT ? extendAll(metadata, deployer, program, programData, data.length) : [])]);
    for (let o = 0; o < data.length; o += CHUNK) deployerTxs.push([write(metadata, deployer, o, data.subarray(o, o + CHUNK))]);
    deployerTxs.push([initialize(metadata, deployer, program, programData)]);
    return { summary: `${summary}upload the IDL (${data.length} bytes)`, deployerTxs, authorityIxs: [] };
  }
  // Create through the vault: the deployer writes a buffer for the vault and funds the account; the
  // vault allocates the canonical account, copies the buffer in, initializes it and closes the buffer.
  const buffer = await generateKeyPairSigner();
  deployerTxs.push(...(await writeBufferTxs(deployer, buffer, data, authority)));
  if (funding.length) deployerTxs.push(funding);
  return done(`${summary}create the IDL (${data.length} bytes) from buffer ${buffer.address}`, [
    allocate(metadata, authority, program, programData, true),
    ...(data.length > REALLOC_LIMIT ? extendAll(metadata, authority, program, programData, data.length) : []),
    writeFrom(metadata, authority, buffer.address),
    initialize(metadata, authority, program, programData),
    close(buffer.address, authority, deployer.address),
  ]);
}

/** Test support: closes the IDL account (or an unfinished upload there), signed by the upgrade authority. */
export const closeIdlInstruction = async (program: Address, programData: Address, authority: KeyPairSigner) =>
  close(await idlAccount(program), authority, authority.address, program, programData);

/** Test support: leaves an unfinished upload at the IDL address (allocated, partly written, not initialized). */
export async function unfinishedIdlUpload(program: Address, programData: Address, authority: KeyPairSigner, json: string): Promise<Instruction[]> {
  const data = encodeIdl(json);
  const metadata = await idlAccount(program);
  return [...fund(authority, metadata, await rent(data.length)), allocate(metadata, authority, program, programData, true),
    write(metadata, authority, 0, data.subarray(0, 100))];
}
