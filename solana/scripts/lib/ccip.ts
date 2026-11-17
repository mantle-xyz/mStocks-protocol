// Shared CCIP helpers for the Solana side: program ids, the per-mint CCIP accounts, Anchor
// instruction encoding, on-chain state, and the two-step handoff of the token admin (router's
// TokenAdminRegistry) and the BurnMint pool's ownership.
import { createHash } from "node:crypto";
import {
  AccountRole,
  address,
  getAddressDecoder,
  getAddressEncoder,
  getProgramDerivedAddress,
  getUtf8Encoder,
  type Address,
  type Instruction,
  type KeyPairSigner,
} from "@solana/kit";
import { findAssociatedTokenPda } from "@solana-program/token-2022";
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
export async function registryState(a: CcipAccounts) {
  const d = await accountData(a.tokenAdminRegistry);
  return d
    ? { admin: dec.decode(d.subarray(9, 41)), pending: dec.decode(d.subarray(41, 73)), lookupTable: dec.decode(d.subarray(73, 105)) }
    : null;
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
