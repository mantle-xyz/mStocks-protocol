// TD §6 step 5: registers a Core mint with CCIP using the shared BurnMint token pool, for one
// remote (EVM) chain, in two transactions signed by the current mint authority:
//   1. token admin (propose + accept), the pool (self-served: the mint authority signs), the pool
//      signer's token account, and the pool's address lookup table;
//   2. the remote chain (token, pool, decimals), its rate limits and set_pool; with --handoff-to,
//      the proposals handing the token admin and the pool ownership to the multisig; with
//      --handoff-mint-authority, finally the mint authority to the pool signer.
// With --handoff-to, the new holder's acceptance follows: one Squads proposal for a multisig
// (created with --squads-member, printed without it), signed directly for a keypair.
// Steps already done on chain are left out, so it can be re-run after a failure.
//   NETWORK=mainnet tsx scripts/ccip-register.ts --authority <mint authority keypair> --mint <mint>
//     --remote-token <0x..> --remote-pool <0x..> [--remote-selector <u64>] [--remote-decimals 18]
//     [--rate-capacity <units> --rate-per-second <units>]   (rate limits are off without these)
//     [--handoff-to [<keypair.json|squads multisig>] [--squads-member <keypair.json>]] [--handoff-mint-authority]
// --remote-selector defaults to the config's Mantle selector; --handoff-to without a value to the
// config's CCIP admin.
//     [--router <id>] [--pool-program <id>] [--fee-quoter <id>]
// Defaults are the CCIP Solana program ids (same on devnet and mainnet).
import {
  AccountRole,
  address,
  fetchEncodedAccount,
  getAddressEncoder,
  getProgramDerivedAddress,
  type Address,
  type Instruction,
} from "@solana/kit";
import {
  AuthorityType,
  getCreateAssociatedTokenIdempotentInstruction,
  getMintDecoder,
  getSetAuthorityInstruction,
} from "@solana-program/token-2022";
import { adminAddress, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import {
  ALT_PROGRAM,
  SYSTEM_PROGRAM,
  accountData,
  anchorIx,
  ccipAccounts,
  chainConfigPda,
  handoffAccepts,
  handoffProposals,
  poolOwnership,
  registryState,
  type Meta,
} from "./lib/ccip.ts";
import { ccipAdmin, setting } from "./lib/config.ts";
import { TOKEN_2022_PROGRAM_ID, concat, encodeEvmAddress, encodeU64 } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send, withRetry } from "./lib/env.ts";

const args = parseArgs();
const authority = await loadKeypair(required(args, "authority"));
const mint = address(required(args, "mint"));
const remoteSelector = BigInt(setting(args["remote-selector"], "ccip.mantle_selector", "remote-selector"));
const remoteToken = encodeEvmAddress(required(args, "remote-token"));
const remotePool = encodeEvmAddress(required(args, "remote-pool"));
const remoteDecimals = Number(args["remote-decimals"] ?? 18);
const rateLimit =
  args["rate-capacity"] !== undefined
    ? { enabled: true, capacity: BigInt(args["rate-capacity"]), rate: BigInt(required(args, "rate-per-second")) }
    : { enabled: false, capacity: 0n, rate: 0n };
// --handoff-to without a value: the config's CCIP admin (the admin's Squads).
const handoffTo = args["handoff-to"]
  ? await resolveAdmin(args["handoff-to"] === "true" ? ccipAdmin() : args["handoff-to"])
  : undefined;
const handoffMintAuthority = args["handoff-mint-authority"] === "true";

const a = await ccipAccounts(mint, { router: args.router, poolProgram: args["pool-program"], feeQuoter: args["fee-quoter"] });
const chainConfig = await chainConfigPda(a, remoteSelector);
const enc = getAddressEncoder();

// --- encoding ---
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

/** Sends the steps that still have instructions as one transaction. */
async function sendSteps(label: string, steps: [string, Instruction[]][]) {
  for (const [name, ixs] of steps) if (!ixs.length) console.log(`  ${name}: already done`);
  const todo = steps.filter(([, ixs]) => ixs.length);
  if (!todo.length) return console.log(`${label}: nothing to do`);
  console.log(`${label} (${todo.map(([name]) => name).join(", ")}): ${await send(authority, todo.flatMap(([, ixs]) => ixs))}`);
}

console.log(`mint ${mint}\npool state ${a.poolState}\npool signer ${a.poolSigner}\npool token account ${a.poolAta}`);

// Transaction 1: everything that needs the mint authority, and the lookup table.
const reg1 = await registryState(a);
let lut: Address | undefined;
const lutIxs: Instruction[] = [];
if (!reg1 || reg1.lookupTable === SYSTEM_PROGRAM) {
  // Lookup table with exactly the accounts the router expects, in its order.
  const slot = await withRetry(() => rpc.getSlot({ commitment: "finalized" }).send());
  const [table, bump] = await getProgramDerivedAddress({
    programAddress: ALT_PROGRAM,
    seeds: [new Uint8Array(enc.encode(authority.address)), encodeU64(slot)],
  });
  lut = table;
  const entries = [lut, a.tokenAdminRegistry, a.poolProgram, a.poolState, a.poolAta, a.poolSigner, TOKEN_2022_PROGRAM_ID, mint, a.feeBillingTokenConfig, a.externalPoolsSigner];
  const altMetas = [
    { address: lut, role: AccountRole.WRITABLE },
    { address: authority.address, role: AccountRole.READONLY_SIGNER, signer: authority },
    { address: authority.address, role: AccountRole.WRITABLE_SIGNER, signer: authority },
    { address: SYSTEM_PROGRAM, role: AccountRole.READONLY },
  ];
  const altIx = (variant: number, data: Uint8Array): Instruction => ({ programAddress: ALT_PROGRAM, accounts: altMetas, data: concat(u32(variant), data) });
  lutIxs.push(
    altIx(0, concat(encodeU64(slot), Uint8Array.of(bump))),
    altIx(2, concat(encodeU64(BigInt(entries.length)), ...entries.map((e) => new Uint8Array(enc.encode(e))))),
  );
}
const tokenAdminMetas: Meta[] = [[a.routerConfig, "r"], [a.tokenAdminRegistry, "w"], [mint, "r"], [authority, "sw"]];
await sendSteps("transaction 1", [
  ["propose token admin", reg1 ? [] : [
    anchorIx(a.router, "owner_propose_administrator", [...tokenAdminMetas, [SYSTEM_PROGRAM, "r"]], new Uint8Array(enc.encode(authority.address))),
  ]],
  ["accept token admin", !reg1 || (reg1.admin !== authority.address && reg1.pending === authority.address) ? [
    anchorIx(a.router, "accept_admin_role_token_admin_registry", tokenAdminMetas, new Uint8Array()),
  ] : []],
  ["initialize pool", (await accountData(a.poolState)) ? [] : [
    anchorIx(a.poolProgram, "initialize",
      [[a.poolState, "w"], [mint, "r"], [authority, "sw"], [SYSTEM_PROGRAM, "r"], [a.poolProgram, "r"], [a.poolProgramData, "r"], [a.poolGlobalConfig, "r"]],
      new Uint8Array()),
  ]],
  ["pool token account", (await accountData(a.poolAta)) ? [] : [
    getCreateAssociatedTokenIdempotentInstruction({ payer: authority, ata: a.poolAta, owner: a.poolSigner, mint, tokenProgram: TOKEN_2022_PROGRAM_ID }),
  ]],
  [`lookup table${lut ? ` ${lut}` : ""}`, lutIxs],
]);

// Transaction 2: remote chain, rate limits, set_pool, then the handoffs.
const reg = (await registryState(a))!;
const pool = (await poolOwnership(a))!;
const chainExists = (await accountData(chainConfig)) !== null;
const chainArgs = concat(encodeU64(remoteSelector), new Uint8Array(enc.encode(mint)));
const chainMetas: Meta[] = [[a.poolState, "r"], [chainConfig, "w"], [authority, "sw"], [SYSTEM_PROGRAM, "r"]];
const steps: [string, Instruction[]][] = [
  ["remote chain config", chainExists ? [] : [
    anchorIx(a.poolProgram, "init_chain_remote_config", chainMetas,
      concat(chainArgs, u32(0), remoteAddress(leftPad32(remoteToken)), Uint8Array.of(remoteDecimals))),
  ]],
  ["remote pool address", chainExists ? [] : [
    anchorIx(a.poolProgram, "append_remote_pool_addresses", chainMetas, concat(chainArgs, u32(1), remoteAddress(remotePool))),
  ]],
  // Re-set on every run while this key owns the pool, so a re-run can correct them.
  [`rate limits (${rateLimit.enabled ? `${rateLimit.capacity} cap, ${rateLimit.rate}/s` : "off"})`, pool.owner === authority.address ? [
    anchorIx(a.poolProgram, "set_chain_rate_limit", chainMetas.slice(0, 3), concat(chainArgs, rateLimitConfig(rateLimit), rateLimitConfig(rateLimit))),
  ] : []],
  [`set_pool${lut ? ` (lookup table ${lut})` : ""}`, lut ? [
    // Indexes 3 (pool state), 4 (pool token account) and 7 (mint) of the lookup table are writable.
    anchorIx(a.router, "set_pool", [...tokenAdminMetas.slice(0, 3), [lut, "r"], [authority, "sw"]], bytesVec(Uint8Array.of(3, 4, 7))),
  ] : []],
];
if (handoffTo) steps.push([`propose ${adminAddress(handoffTo)} as token admin and pool owner`, handoffProposals(a, authority, adminAddress(handoffTo), reg, pool)]);
if (handoffMintAuthority) {
  const mintAccount = await withRetry(() => fetchEncodedAccount(rpc, mint));
  if (!mintAccount.exists) throw new Error(`mint ${mint} not found`);
  const current = getMintDecoder().decode(mintAccount.data).mintAuthority;
  const holder = current.__option === "Some" ? current.value : null;
  if (holder !== a.poolSigner && holder !== authority.address)
    throw new Error(`mint authority is ${holder}, not ${authority.address}; cannot hand it to the pool`);
  steps.push([`mint authority → pool signer ${a.poolSigner}`, holder === authority.address ? [
    getSetAuthorityInstruction({ owned: mint, owner: authority, authorityType: AuthorityType.MintTokens, newAuthority: a.poolSigner }),
  ] : []]);
}
await sendSteps("transaction 2", steps);

// The new holder accepts: a Squads proposal for a multisig, signed directly for a keypair.
if (handoffTo) {
  const accepts = handoffAccepts(a, handoffTo, (await registryState(a))!, (await poolOwnership(a))!);
  const accepting = accepts.map((i) => (i.programAddress === a.router ? "token admin" : "pool owner")).join(" + ");
  if (accepts.length) await sendOrPrint(authority, handoffTo, accepts, `accept (${accepting})`);
  else console.log("accept: nothing to do");
}
const [r, p] = [(await registryState(a))!, (await poolOwnership(a))!];
console.log(`  now: token admin ${r.admin} (pending ${r.pending}); pool owner ${p.owner} (proposed ${p.proposed}); lookup table ${r.lookupTable}`);
const next = [!handoffTo && "ccip-handoff.ts (multisig)", !handoffMintAuthority && "handoff-mint-authority.ts --yes"].filter(Boolean);
console.log(next.length ? `done; next: ${next.join(", then ")}` : "done");
