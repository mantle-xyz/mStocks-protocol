// Shared plumbing for the mStocks Solana scripts: CLI args, keypairs, RPC and transaction sending.
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import {
  appendTransactionMessageInstructions,
  createKeyPairSignerFromBytes,
  createKeyPairSignerFromPrivateKeyBytes,
  getAddressEncoder,
  getBase58Encoder,
  createSolanaRpc,
  createTransactionMessage,
  getBase64EncodedWireTransaction,
  getSignatureFromTransaction,
  pipe,
  setTransactionMessageFeePayerSigner,
  setTransactionMessageLifetimeUsingBlockhash,
  signTransactionMessageWithSigners,
  type Instruction,
  type KeyPairSigner,
} from "@solana/kit";
import { config } from "./config.ts";

/**
 * RPC endpoint: RPC_URL, else the network config's public endpoint, else a local validator. Keep
 * provider URLs with API keys in the environment, never in files.
 */
export const RPC_URL = process.env.RPC_URL || config?.solana.rpc || "http://127.0.0.1:8899";

export const rpc = createSolanaRpc(RPC_URL);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Retries a request on HTTP 429 (provider rate limits) with exponential backoff. */
export async function withRetry<T>(call: () => Promise<T>, attempts = 6): Promise<T> {
  for (let i = 0; ; i++) {
    try {
      return await call();
    } catch (e) {
      if (i + 1 >= attempts || !String((e as Error)?.message ?? e).includes("429")) throw e;
      await sleep(500 * 2 ** i);
    }
  }
}

/** Parses `--name value` pairs; a flag without a value is `"true"`. */
export function parseArgs(argv = process.argv.slice(2)): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    if (!key.startsWith("--")) throw new Error(`unexpected argument ${key}`);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) out[key.slice(2)] = "true";
    else out[key.slice(2)] = argv[++i];
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
 * file's content) or a base58 private key (64 bytes as wallets export it, or a 32-byte seed). The
 * value itself is never printed.
 */
export async function secretKeyBytes(value: string): Promise<Uint8Array> {
  const path = value.replace(/^~/, homedir());
  let bytes: Uint8Array;
  try {
    if (existsSync(path)) bytes = Uint8Array.from(JSON.parse(readFileSync(path, "utf8")));
    else if (value.trim().startsWith("[")) bytes = Uint8Array.from(JSON.parse(value));
    else bytes = Uint8Array.from(getBase58Encoder().encode(value.trim()));
  } catch {
    throw new Error(BAD_KEY);
  }
  if (bytes.length === 32) {
    const signer = await createKeyPairSignerFromPrivateKeyBytes(bytes);
    bytes = Uint8Array.from([...bytes, ...getAddressEncoder().encode(signer.address)]);
  }
  if (bytes.length !== 64) throw new Error(BAD_KEY);
  return bytes;
}

/** A signer from a keypair file path or an inline private key (see secretKeyBytes). */
export async function loadSigner(value: string): Promise<KeyPairSigner> {
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

export async function loadKeypair(path: string): Promise<KeyPairSigner> {
  const resolved = path.replace(/^~/, homedir());
  return createKeyPairSignerFromBytes(new Uint8Array(JSON.parse(readFileSync(resolved, "utf8"))));
}

/** Largest serialized transaction Solana accepts (signatures included). */
export const TRANSACTION_SIZE_LIMIT = 1232;

/**
 * Signs with every signer embedded in the instructions (plus the fee payer), sends over HTTP and
 * polls until confirmed. Polling instead of WebSocket subscriptions keeps it working with RPC
 * providers that do not offer WebSockets.
 */
export async function send(payer: KeyPairSigner, instructions: Instruction[]): Promise<string> {
  const { value: blockhash } = await withRetry(() => rpc.getLatestBlockhash().send());
  const tx = await pipe(
    createTransactionMessage({ version: 0 }),
    (m) => setTransactionMessageFeePayerSigner(payer, m),
    (m) => setTransactionMessageLifetimeUsingBlockhash(blockhash, m),
    (m) => appendTransactionMessageInstructions(instructions, m),
    (m) => signTransactionMessageWithSigners(m),
  );
  const signature = getSignatureFromTransaction(tx);
  const wire = getBase64EncodedWireTransaction(tx);
  const size = Buffer.from(wire, "base64").length;
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
