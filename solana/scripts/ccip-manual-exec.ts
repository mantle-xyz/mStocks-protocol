// Manually executes an inbound CCIP message (EVM → Solana) whose automatic execution failed, e.g.
// because the mint was paused when it arrived; the DON does not retry such a message. Takes the
// failed execution transaction (the CCIP explorer shows it on the message page), reuses its
// execution report and accounts, and resubmits them as the OffRamp's permissionless
// manually_execute with the payer as authority. Only allowed once the OffRamp's
// enable_manual_execution_after (1200 s on devnet) has passed since the commit; a message that
// has already been executed is skipped by the OffRamp.
//   tsx scripts/ccip-manual-exec.ts --payer <keypair> --failed-tx <signature> [--compute-units 800000]
import { createHash } from "node:crypto";
import {
  AccountRole,
  address,
  getBase58Encoder,
  signature as toSignature,
  type AccountMeta,
  type Address,
  type Instruction,
} from "@solana/kit";
import { lookupTableAddresses } from "./lib/ccip.ts";
import { concat } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send, withRetry } from "./lib/env.ts";

const OFFRAMP = address("offqSMQWgQud6WJz694LRzkeN5kMYpCHTpXQr3Rkcjm");
// execute / manually_execute accounts: config, reference_addresses, source_chain, commit_report,
// offramp, allowed_offramp, authority, ...
const AUTHORITY_INDEX = 6;

const args = parseArgs();
const payer = await loadKeypair(required(args, "payer"));
const failedTx = toSignature(required(args, "failed-tx"));

const disc = (name: string) => new Uint8Array(createHash("sha256").update(`global:${name}`).digest().subarray(0, 8));
const u32 = (v: number) => {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, v, true);
  return b;
};
const readU32 = (b: Uint8Array, at: number) => new DataView(b.buffer, b.byteOffset).getUint32(at, true);
const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");

const tx = await withRetry(() => rpc.getTransaction(failedTx, { maxSupportedTransactionVersion: 0, encoding: "json" }).send());
if (!tx) throw new Error(`transaction ${failedTx} not found`);
if (!tx.meta?.err) throw new Error(`transaction ${failedTx} did not fail; nothing to re-execute`);
const msg = tx.transaction.message;
const loaded = tx.meta.loadedAddresses ?? { writable: [], readonly: [] };
const keys: Address[] = [...msg.accountKeys, ...loaded.writable, ...loaded.readonly];
const { numRequiredSignatures, numReadonlySignedAccounts, numReadonlyUnsignedAccounts } = msg.header;
const nStatic = msg.accountKeys.length;
const writable = (i: number) =>
  i < numRequiredSignatures
    ? i < numRequiredSignatures - numReadonlySignedAccounts
    : i < nStatic
      ? i < nStatic - numReadonlyUnsignedAccounts
      : i < nStatic + loaded.writable.length;

const ix = msg.instructions.find((i) => keys[i.programIdIndex] === OFFRAMP);
if (!ix) throw new Error(`transaction ${failedTx} has no OffRamp instruction`);
const data = new Uint8Array(getBase58Encoder().encode(ix.data));
if (hex(data.subarray(0, 8)) !== hex(disc("execute"))) throw new Error("OffRamp instruction is not execute");
// execute(raw_execution_report: bytes, report_context_byte_words: [[u8; 32]; 2], token_indexes: bytes)
const reportLen = readU32(data, 8);
const report = data.subarray(12, 12 + reportLen);
const tokenIndexes = data.subarray(12 + reportLen + 64);
// ExecutionReportSingleChain: source_chain_selector u64, then the message header's message_id.
console.log(`message 0x${hex(report.subarray(8, 40))}`);

const accounts: AccountMeta[] = ix.accounts.map((k, n) =>
  n === AUTHORITY_INDEX
    ? { address: payer.address, role: AccountRole.WRITABLE_SIGNER, signer: payer }
    : { address: keys[k], role: writable(k) ? AccountRole.WRITABLE : AccountRole.READONLY },
);
const manuallyExecute: Instruction = {
  programAddress: OFFRAMP,
  accounts,
  // manually_execute(raw_execution_report: bytes, token_indexes: bytes)
  data: concat(disc("manually_execute"), u32(report.length), report, tokenIndexes),
};
const computeLimit: Instruction = {
  programAddress: address("ComputeBudget111111111111111111111111111111"),
  accounts: [],
  data: concat(Uint8Array.of(2), u32(Number(args["compute-units"] ?? 800_000))),
};

// Same lookup tables as the failed transaction (the OffRamp's own and the token's pool table).
const tables: Record<Address, Address[]> = {};
for (const { accountKey } of "addressTableLookups" in msg ? (msg.addressTableLookups ?? []) : [])
  tables[accountKey] = await lookupTableAddresses(accountKey);

console.log(`manually_execute: ${await send(payer, [computeLimit, manuallyExecute], tables)}`);
