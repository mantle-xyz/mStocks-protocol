// Sends a Core mint cross-chain from Solana to an EVM address through CCIP (the BurnMint pool burns
// on Solana; the remote pool releases or mints), paying the CCIP fee in native SOL. Approves the
// router's fee billing signer as delegate for the amount first. The transaction uses the token's
// pool lookup table to stay under the size limit. Prints the CCIP message id.
//   tsx scripts/ccip-send.ts --sender <keypair> --mint <mint> --amount <raw u64> [--dest-selector <u64>]
//     (--dest-selector defaults to the network config's Mantle selector)
//     --receiver <0x evm address> [--router <id>] [--compute-units 400000] [--gas-limit 0]
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
} from "@solana/kit";
import { findAssociatedTokenPda, getApproveCheckedInstruction } from "@solana-program/token-2022";
import { accountData, ccipAccounts, lookupTableAddresses, registryState, SYSTEM_PROGRAM } from "./lib/ccip.ts";
import { TOKEN_2022_PROGRAM_ID, concat, encodeEvmAddress, encodeU64 } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send, withRetry } from "./lib/env.ts";
import { setting } from "./lib/config.ts";
import { DECIMALS } from "./lib/mint.ts";

const TOKEN_PROGRAM = address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const NATIVE_MINT = address("So11111111111111111111111111111111111111112");
const ZERO = address("11111111111111111111111111111111");

const args = parseArgs();
const sender = await loadKeypair(required(args, "sender"));
const mint = address(required(args, "mint"));
const amount = BigInt(required(args, "amount"));
const destSelector = BigInt(setting(args["dest-selector"], "mantle.chain_selector", "dest-selector"));
const receiver = encodeEvmAddress(required(args, "receiver"));
const ccip = await ccipAccounts(mint, { router: args.router });
const router = ccip.router;

const enc = getAddressEncoder();
const dec = getAddressDecoder();
const utf8 = getUtf8Encoder();
const key = (a: Address) => new Uint8Array(enc.encode(a));
const pda = async (program: Address, seeds: Parameters<typeof getProgramDerivedAddress>[0]["seeds"]) =>
  (await getProgramDerivedAddress({ programAddress: program, seeds }))[0];
async function account(addr: Address): Promise<Uint8Array> {
  const d = await accountData(addr);
  if (!d) throw new Error(`account ${addr} not found`);
  return d;
}
const u32 = (v: number) => {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, v, true);
  return b;
};
const vec = (b: Uint8Array) => concat(u32(b.length), b);
const u128 = (v: bigint) => concat(encodeU64(v & 0xffff_ffff_ffff_ffffn), encodeU64(v >> 64n));

// Router Config (Borsh after the 8-byte discriminator): version u8, default_code_version u8,
// svm_chain_selector u64, owner, proposed_owner, fee_quoter, rmn_remote, link_token_mint, ...
const routerConfig = await pda(router, [utf8.encode("config")]);
const cfgData = await account(routerConfig);
const feeQuoter = dec.decode(cfgData.subarray(82, 114));
const rmnRemote = dec.decode(cfgData.subarray(114, 146));
const fqConfig = await pda(feeQuoter, [utf8.encode("config")]);
// Fee quoter Config: version u8, owner, proposed_owner, max_fee_juels_per_msg u128, link_token_mint, ...
const linkMint = dec.decode((await account(fqConfig)).subarray(89, 121));

const selector = encodeU64(destSelector);
const feeBillingSigner = await pda(router, [utf8.encode("fee_billing_signer")]);
const [feeReceiver] = await findAssociatedTokenPda({ owner: feeBillingSigner, mint: NATIVE_MINT, tokenProgram: TOKEN_PROGRAM });
const [senderAta] = await findAssociatedTokenPda({ owner: sender.address, mint, tokenProgram: TOKEN_2022_PROGRAM_ID });

// Per-token accounts: sender ATA, the fee quoter's per-chain token config, the pool's chain config,
// then exactly the pool lookup table's entries (writable where the token admin registry says).
const registry = await registryState(ccip);
if (!registry) throw new Error(`mint ${mint} is not registered with CCIP`);
const { lookupTable: lut, isWritable } = registry;
const lutEntries = await lookupTableAddresses(lut);
const poolProgram = lutEntries[2];
const tokenAccounts = [
  { address: senderAta, role: AccountRole.WRITABLE },
  { address: await pda(feeQuoter, [utf8.encode("per_chain_per_token_config"), selector, key(mint)]), role: AccountRole.READONLY },
  { address: await pda(poolProgram, [utf8.encode("ccip_tokenpool_chainconfig"), selector, key(mint)]), role: AccountRole.WRITABLE },
  ...lutEntries.map((a, i) => ({ address: a, role: isWritable(i) ? AccountRole.WRITABLE : AccountRole.READONLY })),
];

// SVM2AnyMessage { receiver, data, token_amounts, fee_token, extra_args } with GenericExtraArgsV2
// (tag 0x181dcf10, gas_limit u128, allow_out_of_order_execution). gas_limit is the receiver's
// ccipReceive gas, 0 for a plain token transfer; it does not change the per-token destGasAmount,
// which the fee quoter sets.
const extraArgs = concat(Uint8Array.from([0x18, 0x1d, 0xcf, 0x10]), u128(BigInt(args["gas-limit"] ?? 0)), Uint8Array.of(1));
const message = concat(
  vec(concat(new Uint8Array(12), receiver)),
  vec(new Uint8Array()),
  u32(1), key(mint), encodeU64(amount),
  key(ZERO),
  vec(extraArgs),
);
const data = concat(createHash("sha256").update("global:ccip_send").digest().subarray(0, 8), selector, message, vec(Uint8Array.of(0)));

const metas = [
  [routerConfig, AccountRole.READONLY],
  [await pda(router, [utf8.encode("dest_chain_state"), selector]), AccountRole.WRITABLE],
  [await pda(router, [utf8.encode("nonce"), selector, key(sender.address)]), AccountRole.WRITABLE],
] as const;
const ccipSendAccounts = [
    ...metas.map(([a, role]) => ({ address: a, role })),
    { address: sender.address, role: AccountRole.WRITABLE_SIGNER, signer: sender },
    { address: SYSTEM_PROGRAM, role: AccountRole.READONLY },
    { address: TOKEN_PROGRAM, role: AccountRole.READONLY },
    { address: NATIVE_MINT, role: AccountRole.READONLY },
    { address: ZERO, role: AccountRole.READONLY },
    { address: feeReceiver, role: AccountRole.WRITABLE },
    { address: feeBillingSigner, role: AccountRole.READONLY },
    { address: feeQuoter, role: AccountRole.READONLY },
    { address: fqConfig, role: AccountRole.READONLY },
    { address: await pda(feeQuoter, [utf8.encode("dest_chain"), selector]), role: AccountRole.READONLY },
    { address: await pda(feeQuoter, [utf8.encode("fee_billing_token_config"), key(NATIVE_MINT)]), role: AccountRole.READONLY },
    { address: await pda(feeQuoter, [utf8.encode("fee_billing_token_config"), key(linkMint)]), role: AccountRole.READONLY },
    { address: rmnRemote, role: AccountRole.READONLY },
    { address: await pda(rmnRemote, [utf8.encode("curses")]), role: AccountRole.READONLY },
    { address: await pda(rmnRemote, [utf8.encode("config")]), role: AccountRole.READONLY },
    ...tokenAccounts,
];
const ccipSend: Instruction = { programAddress: router, accounts: ccipSendAccounts, data };
// A token transfer (fee quote, transfer to the pool, burn, onramp bookkeeping) needs more than the
// default 200k compute units. ComputeBudget SetComputeUnitLimit = tag 2 + u32 units.
const computeLimit: Instruction = {
  programAddress: address("ComputeBudget111111111111111111111111111111"),
  accounts: [],
  data: concat(Uint8Array.of(2), u32(Number(args["compute-units"] ?? 400_000))),
};

// The router moves the tokens to the pool as the fee billing signer, so it must be a delegate.
console.log(`approve ${amount} to ${feeBillingSigner}: ${await send(sender, [
  getApproveCheckedInstruction({ source: senderAta, mint, delegate: feeBillingSigner, owner: sender, amount, decimals: DECIMALS }, { programAddress: TOKEN_2022_PROGRAM_ID }),
])}`);

const signature = await send(sender, [computeLimit, ccipSend], { [lut]: lutEntries });
const sent = await withRetry(() => rpc.getTransaction(signature, { maxSupportedTransactionVersion: 0, encoding: "json" }).send());
const msgLog = sent?.meta?.logMessages?.find((l) => l.includes("message_id") || l.includes("messageId"));
console.log(`ccip_send: ${signature}${msgLog ? `\n${msgLog}` : ""}`);
