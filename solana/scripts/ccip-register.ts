// TD §6 step 6: registers a Core mint with CCIP using the shared BurnMint token pool, for one
// remote (EVM) chain, in two transactions signed by the current mint authority:
//   1. token admin (propose + accept), the pool (self-served: the mint authority signs), the pool
//      signer's token account, and the pool's address lookup table;
//   2. the remote chain (token, pool, decimals), its rate limits and set_pool, then the lookup
//      table is frozen (its authority, this key, could otherwise close it and stop every transfer
//      of the mint); with --handoff-to, the proposals handing the token admin and the pool
//      ownership to the multisig; with --handoff-mint-authority, finally the mint authority to the
//      mint authority multisig.
// Before transaction 1, a 1-of-2 Token-2022 multisig of the pool signer and the admin's vault is
// created; it is the mint authority from the handoff on and sits in the lookup table, where the
// pool finds it. The pool signer alone meets its threshold, so CCIP mints as before; the admin's
// vault can move the authority to another pool without Chainlink (lib/ccip.ts).
// With --handoff-to, the new holder's acceptance follows: one Squads proposal for a multisig
// (printed as a base58 transaction message for the Squads app), signed directly for a keypair.
// Steps already done on chain are left out, so it can be re-run after a failure.
//   NETWORK=mainnet tsx scripts/ccip-register.ts --authority <mint authority keypair> --mint <mint>
//     --remote-token <0x..> --remote-pool <0x..> [--remote-selector <u64>] [--remote-decimals 18]
//     [--rate-capacity <units> --rate-per-second <units> | --no-rate-limit]
//        (one of them is required when the remote chain is first configured; a re-run without
//        either leaves the rate limits as they are)
//     [--handoff-to [<keypair.json|squads multisig>]] [--handoff-mint-authority]
//     [--mint-authority-admin <keypair.json|squads multisig>]   (default: the config's admin)
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
  createMintAuthorityMultisigIxs,
  freezeLookupTableIx,
  handoffAccepts,
  handoffProposals,
  lookupTableAddresses,
  lookupTableAuthority,
  mintAuthorityMultisig,
  mintAuthorityMultisigProblem,
  poolOwnership,
  registryState,
  type Meta,
} from "./lib/ccip.ts";
import { ccipAdmin, setting } from "./lib/config.ts";
import { TOKEN_2022_PROGRAM_ID, concat, encodeEvmAddress, encodeU64 } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send, withRetry } from "./lib/env.ts";

const args = parseArgs(["authority", "mint", "remote-token", "remote-pool", "remote-selector", "remote-decimals", "rate-capacity", "rate-per-second", "no-rate-limit", "handoff-to", "handoff-mint-authority", "mint-authority-admin", "router", "pool-program", "fee-quoter"]);
const authority = await loadKeypair(required(args, "authority"));
const mint = address(required(args, "mint"));
const remoteSelector = BigInt(setting(args["remote-selector"], "mantle.chain_selector", "remote-selector"));
const remoteToken = encodeEvmAddress(required(args, "remote-token"));
const remotePool = encodeEvmAddress(required(args, "remote-pool"));
const remoteDecimals = Number(args["remote-decimals"] ?? 18);
// Rate limits are set only when given: a re-run without them must not switch them off.
const rateLimit =
  args["no-rate-limit"] === "true"
    ? { enabled: false, capacity: 0n, rate: 0n }
    : args["rate-capacity"] !== undefined
      ? { enabled: true, capacity: BigInt(args["rate-capacity"]), rate: BigInt(required(args, "rate-per-second")) }
      : undefined;
// --handoff-to without a value: the config's CCIP admin (the admin's Squads).
const handoffTo = args["handoff-to"]
  ? await resolveAdmin(args["handoff-to"] === "true" ? ccipAdmin() : args["handoff-to"])
  : undefined;
const handoffMintAuthority = args["handoff-mint-authority"] === "true";
// The multisig's other member: the admin's vault (the admin governs the token roles and the mint
// registry, like the Mantle token admin).
const mintAuthorityAdmin = adminAddress(await resolveAdmin(setting(args["mint-authority-admin"], "admins.admin", "mint-authority-admin")));

const a = await ccipAccounts(mint, { router: args.router, poolProgram: args["pool-program"], feeQuoter: args["fee-quoter"] });
const chainConfig = await chainConfigPda(a, remoteSelector);
if (!rateLimit && (await accountData(chainConfig)) === null)
  throw new Error("the remote chain is not configured yet: set --rate-capacity and --rate-per-second, or --no-rate-limit");
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
const rateLimitConfig = (c: NonNullable<typeof rateLimit>) => concat(Uint8Array.of(c.enabled ? 1 : 0), encodeU64(c.capacity), encodeU64(c.rate));
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

// Transaction 0: the mint authority multisig, before the lookup table that lists it.
const multisig = await mintAuthorityMultisig(authority.address, mint);
console.log(`mint authority multisig ${multisig} (1 of: pool signer, admin ${mintAuthorityAdmin})`);
await sendSteps("transaction 0", [
  ["mint authority multisig", await createMintAuthorityMultisigIxs(authority, mint, a.poolSigner, mintAuthorityAdmin)],
]);
const multisigProblem = await mintAuthorityMultisigProblem(multisig, a.poolSigner, mintAuthorityAdmin);
if (multisigProblem) throw new Error(multisigProblem);

// Transaction 1: everything that needs the mint authority, and the lookup table.
const reg1 = await registryState(a);
let lut: Address | undefined;
const lutIxs: Instruction[] = [];
if (!reg1 || reg1.lookupTable === SYSTEM_PROGRAM) {
  // Lookup table with exactly the accounts the router expects, in its order, then the mint
  // authority multisig, which the pool looks up among the remaining accounts when it mints.
  const slot = await withRetry(() => rpc.getSlot({ commitment: "finalized" }).send());
  const [table, bump] = await getProgramDerivedAddress({
    programAddress: ALT_PROGRAM,
    seeds: [new Uint8Array(enc.encode(authority.address)), encodeU64(slot)],
  });
  lut = table;
  const entries = [lut, a.tokenAdminRegistry, a.poolProgram, a.poolState, a.poolAta, a.poolSigner, TOKEN_2022_PROGRAM_ID, mint, a.feeBillingTokenConfig, a.externalPoolsSigner, multisig];
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
  // Set when given, while this key owns the pool, so a re-run can correct them.
  [`rate limits (${!rateLimit ? "unchanged" : rateLimit.enabled ? `${rateLimit.capacity} cap, ${rateLimit.rate}/s` : "off"})`, rateLimit && pool.owner === authority.address ? [
    anchorIx(a.poolProgram, "set_chain_rate_limit", chainMetas.slice(0, 3), concat(chainArgs, rateLimitConfig(rateLimit), rateLimitConfig(rateLimit))),
  ] : []],
  [`set_pool${lut ? ` (lookup table ${lut})` : ""}`, lut ? [
    // Indexes 3 (pool state), 4 (pool token account) and 7 (mint) of the lookup table are writable.
    anchorIx(a.router, "set_pool", [...tokenAdminMetas.slice(0, 3), [lut, "r"], [authority, "sw"]], bytesVec(Uint8Array.of(3, 4, 7))),
  ] : []],
];
// Freeze the pool's lookup table: while this key is its authority it could deactivate and close it,
// which stops every transfer of the mint until the admin multisig sets a new table.
const table = lut ?? (reg.lookupTable !== SYSTEM_PROGRAM ? reg.lookupTable : undefined);
const tableAuthority = table && !lut ? await lookupTableAuthority(table) : table ? authority.address : undefined;
if (table && tableAuthority && tableAuthority !== authority.address)
  console.log(`  warning: lookup table ${table} has authority ${tableAuthority}, not this key; that key must freeze it`);
steps.push([`freeze lookup table${table ? ` ${table}` : ""}`, table && tableAuthority === authority.address ? [freezeLookupTableIx(table, authority)] : []]);
if (handoffTo) steps.push([`propose ${adminAddress(handoffTo)} as token admin and pool owner`, handoffProposals(a, authority, adminAddress(handoffTo), reg, pool)]);
if (handoffMintAuthority) {
  const mintAccount = await withRetry(() => fetchEncodedAccount(rpc, mint));
  if (!mintAccount.exists) throw new Error(`mint ${mint} not found`);
  const current = getMintDecoder().decode(mintAccount.data).mintAuthority;
  const holder = current.__option === "Some" ? current.value : null;
  if (holder !== multisig && holder !== authority.address)
    throw new Error(`mint authority is ${holder}, not ${authority.address}; cannot hand it to the multisig`);
  // Without the multisig in the (soon frozen) table the pool could never mint.
  if (table && !(await lookupTableAddresses(table)).includes(multisig))
    throw new Error(`lookup table ${table} does not list the multisig ${multisig}; the pool could not mint through it`);
  steps.push([`mint authority → multisig ${multisig}`, holder === authority.address ? [
    getSetAuthorityInstruction({ owned: mint, owner: authority, authorityType: AuthorityType.MintTokens, newAuthority: multisig }),
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
// What is still left, read from the chain (a re-run after the handoff has nothing left).
const mintNow = await withRetry(() => fetchEncodedAccount(rpc, mint));
const minter = mintNow.exists ? getMintDecoder().decode(mintNow.data).mintAuthority : null;
const next = [
  (r.admin === authority.address || p.owner === authority.address) && r.pending === SYSTEM_PROGRAM && p.proposed === SYSTEM_PROGRAM && "ccip-handoff.ts (multisig)",
  minter?.__option === "Some" && minter.value === authority.address && "handoff-mint-authority.ts --yes",
].filter(Boolean);
console.log(next.length ? `done; next: ${next.join(", then ")}` : "done");
