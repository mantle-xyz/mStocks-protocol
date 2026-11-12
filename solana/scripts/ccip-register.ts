// TD §6 step 5: registers a Core mint with CCIP using the shared BurnMint token pool, for one
// remote (EVM) chain. In order: propose and accept the token admin on the router, initialize the
// pool (self-served: the mint authority signs), create the pool signer's token account, configure
// the remote chain (token, pool, decimals) and its rate limits, build the pool's address lookup
// table and set_pool. Steps already done on chain are skipped, so it can be re-run. The signer is
// the current mint authority and becomes token admin and pool owner; run handoff-mint-authority.ts
// afterwards.
//   tsx scripts/ccip-register.ts --authority <mint authority keypair> --mint <mint>
//     --remote-selector <u64> --remote-token <0x..> --remote-pool <0x..> [--remote-decimals 18]
//     [--rate-capacity <units> --rate-per-second <units>]   (rate limits are off without these)
//     [--router <id>] [--pool-program <id>] [--fee-quoter <id>]
// Defaults are the CCIP Solana program ids (same on devnet and mainnet).
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
import { findAssociatedTokenPda, getCreateAssociatedTokenIdempotentInstruction } from "@solana-program/token-2022";
import { BPF_LOADER_UPGRADEABLE, TOKEN_2022_PROGRAM_ID, concat, encodeEvmAddress, encodeU64 } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send, withRetry } from "./lib/env.ts";

const SYSTEM_PROGRAM = address("11111111111111111111111111111111");
const ALT_PROGRAM = address("AddressLookupTab1e1111111111111111111111111");

const args = parseArgs();
const authority = await loadKeypair(required(args, "authority"));
const mint = address(required(args, "mint"));
const router = address(args.router ?? "Ccip842gzYHhvdDkSyi2YVCoAWPbYJoApMFzSxQroE9C");
const poolProgram = address(args["pool-program"] ?? "41FGToCmdaWa1dgZLKFAjvmx6e6AjVTX7SVRibvsMGVB");
const feeQuoter = address(args["fee-quoter"] ?? "FeeQPGkKDeRV1MgoYfMH6L8o3KeuYjwUZrgn4LRKfjHi");
const remoteSelector = BigInt(required(args, "remote-selector"));
const remoteToken = encodeEvmAddress(required(args, "remote-token"));
const remotePool = encodeEvmAddress(required(args, "remote-pool"));
const remoteDecimals = Number(args["remote-decimals"] ?? 18);
const rateLimit =
  args["rate-capacity"] !== undefined
    ? { enabled: true, capacity: BigInt(args["rate-capacity"]), rate: BigInt(required(args, "rate-per-second")) }
    : { enabled: false, capacity: 0n, rate: 0n };

const enc = getAddressEncoder();
const utf8 = getUtf8Encoder();
const pda = async (program: Address, seeds: Parameters<typeof getProgramDerivedAddress>[0]["seeds"]) =>
  (await getProgramDerivedAddress({ programAddress: program, seeds })).at(0) as Address;

const routerConfig = await pda(router, [utf8.encode("config")]);
const tokenAdminRegistry = await pda(router, [utf8.encode("token_admin_registry"), new Uint8Array(enc.encode(mint))]);
const poolState = await pda(poolProgram, [utf8.encode("ccip_tokenpool_config"), new Uint8Array(enc.encode(mint))]);
const poolSigner = await pda(poolProgram, [utf8.encode("ccip_tokenpool_signer"), new Uint8Array(enc.encode(mint))]);
const poolGlobalConfig = await pda(poolProgram, [utf8.encode("config")]);
const poolProgramData = await pda(BPF_LOADER_UPGRADEABLE, [new Uint8Array(enc.encode(poolProgram))]);
const chainConfig = await pda(poolProgram, [
  utf8.encode("ccip_tokenpool_chainconfig"),
  encodeU64(remoteSelector),
  new Uint8Array(enc.encode(mint)),
]);
const feeBillingTokenConfig = await pda(feeQuoter, [utf8.encode("fee_billing_token_config"), new Uint8Array(enc.encode(mint))]);
const externalPoolsSigner = await pda(router, [utf8.encode("external_token_pools_signer"), new Uint8Array(enc.encode(poolProgram))]);
const [poolAta] = await findAssociatedTokenPda({ owner: poolSigner, mint, tokenProgram: TOKEN_2022_PROGRAM_ID });

// --- encoding (Anchor: 8-byte sha256("global:<name>") discriminator + Borsh args) ---

const disc = (name: string) => createHash("sha256").update(`global:${name}`).digest().subarray(0, 8);
const u32 = (v: number) => {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, v, true);
  return b;
};
const bytesVec = (b: Uint8Array) => concat(u32(b.length), b);
/** RemoteAddress { address: Vec<u8> } */
const remoteAddress = (b: Uint8Array) => bytesVec(b);
const rateLimitConfig = (c: typeof rateLimit) => concat(Uint8Array.of(c.enabled ? 1 : 0), encodeU64(c.capacity), encodeU64(c.rate));
/** The remote EVM token is an ABI-style 32-byte left-padded address; remote EVM pools stay 20 bytes. */
const leftPad32 = (b: Uint8Array) => concat(new Uint8Array(32 - b.length), b);

type Meta = [Address | KeyPairSigner, "r" | "w" | "s" | "sw"];
function ix(programAddress: Address, name: string, metas: Meta[], data: Uint8Array): Instruction {
  const roles = { r: AccountRole.READONLY, w: AccountRole.WRITABLE, s: AccountRole.READONLY_SIGNER, sw: AccountRole.WRITABLE_SIGNER };
  return {
    programAddress,
    accounts: metas.map(([a, r]) =>
      typeof a === "string" ? { address: a, role: roles[r] } : { address: a.address, role: roles[r], signer: a },
    ),
    data: concat(disc(name), data),
  };
}

async function account(addr: Address): Promise<Uint8Array | null> {
  const { value } = await withRetry(() => rpc.getAccountInfo(addr, { encoding: "base64" }).send());
  return value ? new Uint8Array(Buffer.from(value.data[0], "base64")) : null;
}

const dec = getAddressDecoder();
async function step(label: string, done: boolean, instructions: () => Promise<Instruction[]> | Instruction[]) {
  if (done) return console.log(`${label}: already done`);
  console.log(`${label}: ${await send(authority, await instructions())}`);
}

console.log(`mint ${mint}\npool state ${poolState}\npool signer ${poolSigner}\npool token account ${poolAta}`);

// 1–2. Token admin: the mint authority proposes itself, then accepts.
let registry = await account(tokenAdminRegistry);
await step("propose token admin", registry !== null, () => [
  ix(router, "owner_propose_administrator", [[routerConfig, "r"], [tokenAdminRegistry, "w"], [mint, "r"], [authority, "sw"], [SYSTEM_PROGRAM, "r"]],
    new Uint8Array(enc.encode(authority.address))),
]);
registry = await account(tokenAdminRegistry);
const administrator = registry ? dec.decode(registry.subarray(9, 41)) : undefined;
await step("accept token admin", administrator === authority.address, () => [
  ix(router, "accept_admin_role_token_admin_registry", [[routerConfig, "r"], [tokenAdminRegistry, "w"], [mint, "r"], [authority, "sw"]], new Uint8Array()),
]);

// 3. Pool state for this mint (self-served: allowed for the mint authority while the global
//    config says so).
await step("initialize pool", (await account(poolState)) !== null, () => [
  ix(poolProgram, "initialize", [[poolState, "w"], [mint, "r"], [authority, "sw"], [SYSTEM_PROGRAM, "r"], [poolProgram, "r"], [poolProgramData, "r"], [poolGlobalConfig, "r"]],
    new Uint8Array()),
]);

// 4. The pool signer's token account (holds tokens briefly before they are burned).
await step("pool token account", (await account(poolAta)) !== null, () => [
  getCreateAssociatedTokenIdempotentInstruction({ payer: authority, ata: poolAta, owner: poolSigner, mint, tokenProgram: TOKEN_2022_PROGRAM_ID }),
]);

// 5. Remote chain: token + decimals, then the remote pool, then rate limits.
const chainArgs = concat(encodeU64(remoteSelector), new Uint8Array(enc.encode(mint)));
const chainMetas: Meta[] = [[poolState, "r"], [chainConfig, "w"], [authority, "sw"], [SYSTEM_PROGRAM, "r"]];
const chainExisted = (await account(chainConfig)) !== null;
await step("remote chain config", chainExisted, () => [
  ix(poolProgram, "init_chain_remote_config", chainMetas,
    concat(chainArgs, u32(0), remoteAddress(leftPad32(remoteToken)), Uint8Array.of(remoteDecimals))),
]);
await step("remote pool address", chainExisted, () => [
  ix(poolProgram, "append_remote_pool_addresses", chainMetas, concat(chainArgs, u32(1), remoteAddress(remotePool))),
]);
await step(`rate limits (${rateLimit.enabled ? `${rateLimit.capacity} cap, ${rateLimit.rate}/s` : "off"})`, false, () => [
  ix(poolProgram, "set_chain_rate_limit", chainMetas.slice(0, 3), concat(chainArgs, rateLimitConfig(rateLimit), rateLimitConfig(rateLimit))),
]);

// 6. Lookup table with exactly the accounts the router expects, in its order, then set_pool.
//    Indexes 3 (pool state), 4 (pool token account) and 7 (mint) are writable.
registry = await account(tokenAdminRegistry);
const currentLut = registry ? dec.decode(registry.subarray(73, 105)) : SYSTEM_PROGRAM;
if (currentLut !== SYSTEM_PROGRAM) {
  console.log(`set_pool: already done (lookup table ${currentLut})`);
} else {
  const slot = await withRetry(() => rpc.getSlot({ commitment: "finalized" }).send());
  const [lut, bump] = await getProgramDerivedAddress({
    programAddress: ALT_PROGRAM,
    seeds: [new Uint8Array(enc.encode(authority.address)), encodeU64(slot)],
  });
  const entries = [lut, tokenAdminRegistry, poolProgram, poolState, poolAta, poolSigner, TOKEN_2022_PROGRAM_ID, mint, feeBillingTokenConfig, externalPoolsSigner];
  const altIx = (variant: number, data: Uint8Array, metas: Instruction["accounts"]): Instruction => ({
    programAddress: ALT_PROGRAM,
    accounts: metas,
    data: concat(u32(variant), data),
  });
  const altMetas = [
    { address: lut, role: AccountRole.WRITABLE },
    { address: authority.address, role: AccountRole.READONLY_SIGNER, signer: authority },
    { address: authority.address, role: AccountRole.WRITABLE_SIGNER, signer: authority },
    { address: SYSTEM_PROGRAM, role: AccountRole.READONLY },
  ];
  console.log(`create lookup table ${lut}: ${await send(authority, [
    altIx(0, concat(encodeU64(slot), Uint8Array.of(bump)), altMetas),
    altIx(2, concat(encodeU64(BigInt(entries.length)), ...entries.map((e) => new Uint8Array(enc.encode(e)))), altMetas),
  ])}`);
  await step("set_pool", false, () => [
    ix(router, "set_pool", [[routerConfig, "r"], [tokenAdminRegistry, "w"], [mint, "r"], [lut, "r"], [authority, "sw"]], bytesVec(Uint8Array.of(3, 4, 7))),
  ]);
}
console.log("done; next: handoff-mint-authority.ts --yes");
