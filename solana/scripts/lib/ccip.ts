// Shared CCIP helpers for the Solana side: program ids, the per-mint CCIP accounts, Anchor
// instruction encoding, on-chain state, and the two-step handoff of the token admin (router's
// TokenAdminRegistry) and the BurnMint pool's ownership.
import { createHash } from "node:crypto";
import {
  AccountRole,
  address,
  createAddressWithSeed,
  fetchEncodedAccount,
  getAddressDecoder,
  getAddressEncoder,
  getProgramDerivedAddress,
  getUtf8Encoder,
  type AccountSignerMeta,
  type Address,
  type Instruction,
  type KeyPairSigner,
} from "@solana/kit";
import { getAllocateWithSeedInstruction, getCreateAccountWithSeedInstruction, getTransferSolInstruction } from "@solana-program/system";
import { findAssociatedTokenPda, getInitializeMultisig2Instruction, getMultisigDecoder, getMultisigSize } from "@solana-program/token-2022";
import { BPF_LOADER_UPGRADEABLE, TOKEN_2022_PROGRAM_ID, concat, encodeU64 } from "./core.ts";
import { rpc, withRetry } from "./env.ts";

export const SYSTEM_PROGRAM = address("11111111111111111111111111111111");
export const ALT_PROGRAM = address("AddressLookupTab1e1111111111111111111111111");
/** CCIP Solana program ids (the same on devnet and mainnet). */
export const DEFAULT_ROUTER = "Ccip842gzYHhvdDkSyi2YVCoAWPbYJoApMFzSxQroE9C";
export const DEFAULT_POOL_PROGRAM = "41FGToCmdaWa1dgZLKFAjvmx6e6AjVTX7SVRibvsMGVB";
export const DEFAULT_FEE_QUOTER = "FeeQPGkKDeRV1MgoYfMH6L8o3KeuYjwUZrgn4LRKfjHi";

const enc = getAddressEncoder();
const dec = getAddressDecoder();
const utf8 = getUtf8Encoder();
const pda = async (programAddress: Address, seeds: Parameters<typeof getProgramDerivedAddress>[0]["seeds"]) =>
  (await getProgramDerivedAddress({ programAddress, seeds }))[0];

export type CcipAccounts = Awaited<ReturnType<typeof ccipAccounts>>;

/** Every CCIP account of one mint. */
export async function ccipAccounts(mint: Address, opts: { router?: string; poolProgram?: string; feeQuoter?: string } = {}) {
  const router = address(opts.router ?? DEFAULT_ROUTER);
  const poolProgram = address(opts.poolProgram ?? DEFAULT_POOL_PROGRAM);
  const feeQuoter = address(opts.feeQuoter ?? DEFAULT_FEE_QUOTER);
  const m = new Uint8Array(enc.encode(mint));
  const poolSigner = await pda(poolProgram, [utf8.encode("ccip_tokenpool_signer"), m]);
  const [poolAta] = await findAssociatedTokenPda({ owner: poolSigner, mint, tokenProgram: TOKEN_2022_PROGRAM_ID });
  return {
    mint,
    router,
    poolProgram,
    feeQuoter,
    routerConfig: await pda(router, [utf8.encode("config")]),
    tokenAdminRegistry: await pda(router, [utf8.encode("token_admin_registry"), m]),
    poolState: await pda(poolProgram, [utf8.encode("ccip_tokenpool_config"), m]),
    poolSigner,
    poolAta,
    poolGlobalConfig: await pda(poolProgram, [utf8.encode("config")]),
    poolProgramData: await pda(BPF_LOADER_UPGRADEABLE, [new Uint8Array(enc.encode(poolProgram))]),
    feeBillingTokenConfig: await pda(feeQuoter, [utf8.encode("fee_billing_token_config"), m]),
    externalPoolsSigner: await pda(router, [utf8.encode("external_token_pools_signer"), new Uint8Array(enc.encode(poolProgram))]),
  };
}

export const chainConfigPda = (a: CcipAccounts, remoteSelector: bigint) =>
  pda(a.poolProgram, [utf8.encode("ccip_tokenpool_chainconfig"), encodeU64(remoteSelector), new Uint8Array(enc.encode(a.mint))]);

/** An account and its role; a KeyPairSigner is attached so the transaction is signed by it. */
export type Meta = [Address | KeyPairSigner, "r" | "w" | "s" | "sw"];
const ROLES = { r: AccountRole.READONLY, w: AccountRole.WRITABLE, s: AccountRole.READONLY_SIGNER, sw: AccountRole.WRITABLE_SIGNER };

/** Anchor instruction: 8-byte sha256("global:<name>") discriminator + Borsh args. */
export function anchorIx(programAddress: Address, name: string, metas: Meta[], data: Uint8Array): Instruction {
  return {
    programAddress,
    accounts: metas.map(([a, r]) =>
      typeof a === "string" ? { address: a, role: ROLES[r] } : { address: a.address, role: ROLES[r], signer: a },
    ),
    data: concat(createHash("sha256").update(`global:${name}`).digest().subarray(0, 8), data),
  };
}

export async function accountData(addr: Address): Promise<Uint8Array | null> {
  const { value } = await withRetry(() => rpc.getAccountInfo(addr, { encoding: "base64" }).send());
  return value ? new Uint8Array(Buffer.from(value.data[0], "base64")) : null;
}

/** TokenAdminRegistry: 8 discriminator, version (1), administrator, pending administrator, lookup table, ... */
/**
 * The authority of an address lookup table: null once it is frozen (nobody can then extend,
 * deactivate or close it), undefined when the table does not exist. LookupTableMeta: u32 state,
 * deactivation slot, last extended slot, start index, then Option<Pubkey> at byte 21.
 */
export async function lookupTableAuthority(table: Address): Promise<Address | null | undefined> {
  const d = await accountData(table);
  if (!d) return undefined;
  return d[21] === 1 ? dec.decode(d.subarray(22, 54)) : null;
}
/** FreezeLookupTable (instruction 1), signed by the table's authority. */
export function freezeLookupTableIx(table: Address, authority: KeyPairSigner): Instruction {
  const signer: AccountSignerMeta = { address: authority.address, role: AccountRole.READONLY_SIGNER, signer: authority };
  return { programAddress: ALT_PROGRAM, accounts: [{ address: table, role: AccountRole.WRITABLE }, signer], data: Uint8Array.of(1, 0, 0, 0) };
}

/** The addresses an address lookup table holds (after its 56-byte LookupTableMeta). */
export async function lookupTableAddresses(table: Address): Promise<Address[]> {
  const d = await accountData(table);
  if (!d) throw new Error(`lookup table ${table} not found`);
  return Array.from({ length: (d.length - 56) / 32 }, (_, i) => dec.decode(d.subarray(56 + i * 32, 88 + i * 32)));
}

// --- Mint authority: a 1-of-2 token multisig of the pool signer and the admin's vault ---
//
// The BurnMint pool mints through a Token-2022 multisig in which its signer alone meets the
// threshold, so CCIP works as with the signer itself. The admin's vault, the other member, can
// move the mint authority to another pool (a misconfigured one, or one Chainlink retires) without
// Chainlink; with the signer alone, only the pool program's upgrade authority can. The pool finds
// the multisig among the accounts of the token's lookup table, so it must be in the table before
// the table is frozen.

/** Seed of the multisig's address (createAccountWithSeed allows 32 bytes; a mint's base58 has 32+). */
const multisigSeed = (mint: Address) => mint.slice(0, 32);

/** The multisig's address: derived from the key that creates it (the mint's temporary authority). */
export const mintAuthorityMultisig = (base: Address, mint: Address): Promise<Address> =>
  createAddressWithSeed({ baseAddress: base, programAddress: TOKEN_2022_PROGRAM_ID, seed: multisigSeed(mint) });

/**
 * Instructions creating and initializing the 1-of-2 multisig of `poolSigner` and `adminVault`; none
 * when it exists (mintAuthorityMultisigProblem checks it). Anyone can send lamports to the address
 * beforehand, and CreateAccount refuses an address that holds lamports, so such an account is topped
 * up to rent and allocated instead (AllocateWithSeed also assigns it); only the base can do either.
 */
export async function createMintAuthorityMultisigIxs(base: KeyPairSigner, mint: Address, poolSigner: Address, adminVault: Address): Promise<Instruction[]> {
  const multisig = await mintAuthorityMultisig(base.address, mint);
  const existing = await withRetry(() => fetchEncodedAccount(rpc, multisig));
  if (existing.exists && existing.programAddress === TOKEN_2022_PROGRAM_ID) return [];
  const space = BigInt(getMultisigSize());
  const seed = multisigSeed(mint);
  const rent = await withRetry(() => rpc.getMinimumBalanceForRentExemption(space).send());
  const init = getInitializeMultisig2Instruction({ multisig, signers: [poolSigner, adminVault], m: 1 });
  if (!existing.exists)
    return [
      getCreateAccountWithSeedInstruction({
        payer: base, newAccount: multisig, baseAccount: base, base: base.address, seed,
        amount: rent, space, programAddress: TOKEN_2022_PROGRAM_ID,
      }),
      init,
    ];
  if (existing.programAddress !== SYSTEM_PROGRAM || existing.data.length > 0)
    throw new Error(`${multisig} is in use (owner ${existing.programAddress}, ${existing.data.length} bytes)`);
  return [
    ...(existing.lamports < rent ? [getTransferSolInstruction({ source: base, destination: multisig, amount: rent - existing.lamports })] : []),
    getAllocateWithSeedInstruction({ newAccount: multisig, baseAccount: base, base: base.address, seed, space, programAddress: TOKEN_2022_PROGRAM_ID }),
    init,
  ];
}

/**
 * Why `holder`, a mint's current mint authority, is not the expected multisig of `poolSigner` and
 * `adminVault` (null when it is): an initialized Token-2022 multisig, threshold 1, exactly those
 * two members.
 */
export async function mintAuthorityMultisigProblem(holder: Address, poolSigner: Address, adminVault: Address): Promise<string | null> {
  const acc = await withRetry(() => fetchEncodedAccount(rpc, holder));
  if (!acc.exists) return `${holder} does not exist`;
  if (acc.programAddress !== TOKEN_2022_PROGRAM_ID || acc.data.length !== getMultisigSize()) return `${holder} is not a Token-2022 multisig`;
  const m = getMultisigDecoder().decode(acc.data);
  const members = m.signers.slice(0, m.n);
  if (!m.isInitialized) return `multisig ${holder} is not initialized`;
  if (m.m !== 1 || m.n !== 2 || !members.includes(poolSigner) || !members.includes(adminVault))
    return `multisig ${holder} is ${m.m}-of-${m.n} of ${members.join(", ")}, not 1-of-2 of the pool signer ${poolSigner} and the admin ${adminVault}`;
  return null;
}

/**
 * TokenAdminRegistry: administrator, pending administrator, the pool's lookup table, and
 * writable_indexes ([u128; 2] little-endian, filled from the most significant bit: lookup table
 * index i < 128 is bit 127 - i of the first word, otherwise bit 255 - i of the second).
 */
export async function registryState(a: CcipAccounts) {
  const d = await accountData(a.tokenAdminRegistry);
  if (!d) return null;
  const writable = d.subarray(105, 137);
  const isWritable = (i: number) => {
    const bit = i < 128 ? 127 - i : 255 - i;
    return ((writable[(i < 128 ? 0 : 16) + (bit >> 3)] >> (bit & 7)) & 1) === 1;
  };
  return { admin: dec.decode(d.subarray(9, 41)), pending: dec.decode(d.subarray(41, 73)), lookupTable: dec.decode(d.subarray(73, 105)), isWritable };
}

/** Pool State: 8 discriminator, version (1), BaseConfig { token_program, mint, decimals, pool_signer, pool_token_account, owner, proposed_owner, ... } */
export async function poolOwnership(a: CcipAccounts) {
  const d = await accountData(a.poolState);
  return d ? { owner: dec.decode(d.subarray(138, 170)), proposed: dec.decode(d.subarray(170, 202)) } : null;
}

type Registry = NonNullable<Awaited<ReturnType<typeof registryState>>>;
type Pool = NonNullable<Awaited<ReturnType<typeof poolOwnership>>>;

/** The current holder proposes `target` as token admin and pool owner; steps already done are left out. */
export function handoffProposals(a: CcipAccounts, holder: KeyPairSigner, target: Address, reg: Registry, pool: Pool): Instruction[] {
  const out: Instruction[] = [];
  if (reg.admin !== target && reg.pending !== target) {
    if (reg.admin !== holder.address) throw new Error(`token admin is ${reg.admin}, not ${holder.address}`);
    out.push(
      anchorIx(a.router, "transfer_admin_role_token_admin_registry",
        [[a.routerConfig, "r"], [a.tokenAdminRegistry, "w"], [a.mint, "r"], [holder, "sw"]], new Uint8Array(enc.encode(target))),
    );
  }
  if (pool.owner !== target && pool.proposed !== target) {
    if (pool.owner !== holder.address) throw new Error(`pool owner is ${pool.owner}, not ${holder.address}`);
    out.push(anchorIx(a.poolProgram, "transfer_ownership", [[a.poolState, "w"], [a.mint, "r"], [holder, "s"]], new Uint8Array(enc.encode(target))));
  }
  return out;
}

/** The new holder accepts both roles: signed when it is a keypair, otherwise for a Squads proposal. */
export function handoffAccepts(a: CcipAccounts, target: KeyPairSigner | Address, reg: Registry, pool: Pool): Instruction[] {
  const targetAddress = typeof target === "string" ? target : target.address;
  const out: Instruction[] = [];
  if (reg.admin !== targetAddress)
    out.push(anchorIx(a.router, "accept_admin_role_token_admin_registry",
      [[a.routerConfig, "r"], [a.tokenAdminRegistry, "w"], [a.mint, "r"], [target, "sw"]], new Uint8Array()));
  if (pool.owner !== targetAddress)
    out.push(anchorIx(a.poolProgram, "accept_ownership", [[a.poolState, "w"], [a.mint, "r"], [target, "s"]], new Uint8Array()));
  return out;
}
