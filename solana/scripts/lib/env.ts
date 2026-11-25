// Shared plumbing for the mStocks Solana scripts: CLI args, keypairs, RPC and transaction sending.
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import {
  appendTransactionMessageInstructions,
  blockhash as toBlockhash,
  compressTransactionMessageUsingAddressLookupTables,
  createKeyPairSignerFromBytes,
  getBase58Encoder,
  createSolanaRpc,
  createTransactionMessage,
  getBase64EncodedWireTransaction,
  getSignatureFromTransaction,
  pipe,
  setTransactionMessageFeePayerSigner,
  setTransactionMessageLifetimeUsingBlockhash,
  signTransactionMessageWithSigners,
  type Address,
  type Instruction,
  type KeyPairSigner,
  type Signature,
} from "@solana/kit";
import { config } from "./config.ts";

/**
 * RPC endpoint: RPC_URL, else the network config's public endpoint, else a local validator. Keep
 * provider URLs with API keys in the environment, never in files.
 */
export const RPC_URL = process.env.RPC_URL || config?.solana.rpc || "http://127.0.0.1:8899";

export const rpc = createSolanaRpc(RPC_URL);

/** Genesis hash of Solana mainnet-beta: tells the chain the RPC serves, whatever the config is called. */
const MAINNET_GENESIS = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d";
export const isMainnet = async () => (await withRetry(() => rpc.getGenesisHash().send())) === MAINNET_GENESIS;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Errors worth another try: rate limits and gateway errors in either client's wording (kit "HTTP
 * error (503): …", web3.js "503 Service Unavailable: …") and failed connections (dropped, refused, timed out),
 * found anywhere in the cause chain (fetch reports "fetch failed" with the system error as cause).
 * A program error is final, and resending a signed transaction is safe: it has one signature.
 */
const transient = (e: unknown) => {
  const parts: string[] = [];
  for (let x = e as { message?: unknown; code?: unknown; cause?: unknown } | undefined, depth = 0; x && depth < 5; x = x.cause as typeof x, depth++)
    parts.push(String(x.message ?? x), String(x.code ?? ""));
  return /HTTP error \((?:429|50[234])\)|\b(?:429|50[234]) [A-Z]|fetch failed|ECONNRESET|ETIMEDOUT|EAI_AGAIN|UND_ERR_SOCKET|socket hang up/.test(parts.join(" "));
};

/** Retries a request on a transient error (see `transient`) or whatever `retryable` accepts, with exponential backoff. */
export async function withRetry<T>(call: () => Promise<T>, attempts = 6, retryable = transient): Promise<T> {
  for (let i = 0; ; i++) {
    try {
      return await call();
    } catch (e) {
      if (i + 1 >= attempts || !retryable(e)) throw e;
      await sleep(500 * 2 ** i);
    }
  }
}

/**
 * Parses `--name value` pairs; a flag without a value is `"true"`. Only the options in `known` are
 * accepted, each once: a mistyped flag would otherwise be ignored, and for flags that choose what a
 * script does (`--dry-run`, `--thaw`, `--resume`, `--frozen`) the script would do the opposite.
 */
export function parseArgs(known: readonly string[], argv = process.argv.slice(2)): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    if (!key.startsWith("--")) throw new Error(`unexpected argument ${key}`);
    const name = key.slice(2);
    if (!known.includes(name))
      throw new Error(`unknown option ${key}; this script takes ${known.length ? known.map((k) => `--${k}`).join(", ") : "no options"}`);
    if (name in out) throw new Error(`${key} is given twice`);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) out[name] = "true";
    else out[name] = argv[++i];
  }
  return out;
}

export function required(args: Record<string, string>, name: string): string {
  const v = args[name];
  if (!v) throw new Error(`missing --${name}`);
  return v;
}

/** The deployer key: --<flag>, else the DEPLOYER environment variable (see secretKeyBytes). */
export function deployerKey(args: Record<string, string>, flag: string): string {
  const v = args[flag] ?? process.env.DEPLOYER;
  if (!v) throw new Error(`missing --${flag} (or export DEPLOYER=<keypair file or private key>)`);
  return v;
}

const BAD_KEY = "the key is not an existing keypair file, a JSON byte array or a base58 private key";

/**
 * A key's 64 bytes (secret + public) from a keypair file path, a JSON byte array ("[12,34,…]", the
 * file's content) or a base58 private key (the 64 bytes wallets export). A 32-byte value is refused:
 * it is far more likely a public address given by mistake than a seed, and taken as a seed it would
 * make a key whose secret is public. The value itself is never printed.
 */
export async function secretKeyBytes(value: string): Promise<Uint8Array> {
  const path = value.replace(/^~/, homedir());
  // A path that does not exist is named (a private key never contains "/" or ends in .json).
  if ((value.includes("/") || value.endsWith(".json")) && !existsSync(path)) throw new Error(`no keypair file ${value}`);
  let bytes: Uint8Array;
  try {
    if (existsSync(path)) bytes = Uint8Array.from(JSON.parse(readFileSync(path, "utf8")));
    else if (value.trim().startsWith("[")) bytes = Uint8Array.from(JSON.parse(value));
    else bytes = Uint8Array.from(getBase58Encoder().encode(value.trim()));
  } catch {
    throw new Error(BAD_KEY);
  }
  if (bytes.length === 32)
    throw new Error("the key is 32 bytes: a public address, not a private key; give the 64-byte private key or the keypair file");
  if (bytes.length !== 64) throw new Error(BAD_KEY);
  return bytes;
}

/** A signer from a keypair file path or an inline private key (see secretKeyBytes). */
export async function loadSigner(value: string): Promise<KeyPairSigner> {
  // Also checks that the public half matches the secret half.
  return createKeyPairSignerFromBytes(await secretKeyBytes(value));
}

/**
 * A keypair file for the Solana CLI: the path itself, or, for an inline private key, a temporary
 * file readable only by the owner and removed when the process exits.
 */
export async function keypairFile(value: string): Promise<string> {
  const path = value.replace(/^~/, homedir());
  if (existsSync(path)) return path;
  const bytes = await secretKeyBytes(value);
  const dir = mkdtempSync(join(tmpdir(), "mstocks-key-"));
  const file = join(dir, "keypair.json");
  writeFileSync(file, JSON.stringify(Array.from(bytes)), { mode: 0o600 });
  process.on("exit", () => rmSync(dir, { recursive: true, force: true }));
  for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, () => process.exit(130));
  return file;
}

/** A signer for a key argument: a keypair file, or an inline private key like DEPLOYER (see secretKeyBytes). */
export const loadKeypair = (value: string): Promise<KeyPairSigner> => loadSigner(value);

/** Largest serialized transaction Solana accepts (signatures included). */
export const TRANSACTION_SIZE_LIMIT = 1232;

/** Address lookup tables to compress a transaction with: table address → its addresses. */
export type LookupTables = Record<Address, Address[]>;

const buildTransaction = (payer: KeyPairSigner, instructions: Instruction[], lifetime: Parameters<typeof setTransactionMessageLifetimeUsingBlockhash>[0], lookupTables?: LookupTables) =>
  pipe(
    createTransactionMessage({ version: 0 }),
    (m) => setTransactionMessageFeePayerSigner(payer, m),
    (m) => setTransactionMessageLifetimeUsingBlockhash(lifetime, m),
    (m) => appendTransactionMessageInstructions(instructions, m),
    (m) => (lookupTables ? compressTransactionMessageUsingAddressLookupTables(m, lookupTables) : m),
    (m) => signTransactionMessageWithSigners(m),
  );
const wireSize = (wire: string) => Buffer.from(wire, "base64").length;

/** Serialized size of the transaction `send` would build, without sending anything. */
export async function transactionSize(payer: KeyPairSigner, instructions: Instruction[], lookupTables?: LookupTables): Promise<number> {
  const lifetime = { blockhash: toBlockhash("11111111111111111111111111111111"), lastValidBlockHeight: 0n };
  return wireSize(getBase64EncodedWireTransaction(await buildTransaction(payer, instructions, lifetime, lookupTables)));
}

/**
 * Signs with every signer embedded in the instructions (plus the fee payer), sends over HTTP and
 * polls until confirmed; throws if the transaction fails or is not confirmed within 90 s. Polling
 * instead of WebSocket subscriptions keeps it working with RPC providers that do not offer
 * WebSockets. `lookupTables` compresses the transaction (CCIP sends and executions need them).
 */
export async function send(payer: KeyPairSigner, instructions: Instruction[], lookupTables?: LookupTables): Promise<Signature> {
  const { value: lifetime } = await withRetry(() => rpc.getLatestBlockhash().send());
  const tx = await buildTransaction(payer, instructions, lifetime, lookupTables);
  const signature = getSignatureFromTransaction(tx);
  const wire = getBase64EncodedWireTransaction(tx);
  const size = wireSize(wire);
  if (size > TRANSACTION_SIZE_LIMIT)
    throw new Error(`transaction is ${size} bytes, over Solana's ${TRANSACTION_SIZE_LIMIT}-byte limit; nothing was sent`);
  await withRetry(() => rpc.sendTransaction(wire, { encoding: "base64", preflightCommitment: "confirmed" }).send());
  for (let i = 0; i < 90; i++) {
    const { value } = await withRetry(() => rpc.getSignatureStatuses([signature]).send());
    const status = value[0];
    if (status?.err) throw new Error(`transaction ${signature} failed: ${JSON.stringify(status.err)}`);
    if (status?.confirmationStatus === "confirmed" || status?.confirmationStatus === "finalized") return signature;
    await sleep(1000);
  }
  throw new Error(`transaction ${signature} not confirmed within 90s`);
}
