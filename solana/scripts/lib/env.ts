// Shared plumbing for the mStocks Solana scripts: CLI args, keypairs, RPC and transaction sending.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import {
  appendTransactionMessageInstructions,
  createKeyPairSignerFromBytes,
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

/** RPC endpoint; keep provider URLs with API keys in the environment, never in files. */
export const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:8899";

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

export async function loadKeypair(path: string): Promise<KeyPairSigner> {
  const resolved = path.replace(/^~/, homedir());
  return createKeyPairSignerFromBytes(new Uint8Array(JSON.parse(readFileSync(resolved, "utf8"))));
}

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
  await withRetry(() =>
    rpc.sendTransaction(getBase64EncodedWireTransaction(tx), { encoding: "base64", preflightCommitment: "confirmed" }).send(),
  );
  for (let i = 0; i < 90; i++) {
    const { value } = await withRetry(() => rpc.getSignatureStatuses([signature]).send());
    const status = value[0];
    if (status?.err) throw new Error(`transaction ${signature} failed: ${JSON.stringify(status.err)}`);
    if (status?.confirmationStatus === "confirmed" || status?.confirmationStatus === "finalized") return signature;
    await sleep(1000);
  }
  throw new Error(`transaction ${signature} not confirmed within 90s`);
}
