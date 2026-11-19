// Read-only calls to Mantle (eth_call over JSON-RPC): ScaledToken state, ERC-20 balances and the
// CCIP TokenAdminRegistry.
import { mantleRpc } from "./config.ts";
import { withRetry } from "./env.ts";

export const SELECTORS = {
  name: "0x06fdde03",
  symbol: "0x95d89b41",
  decimals: "0x313ce567",
  balanceOf: "0x70a08231",
  assetCode: "0x4e841e3e",
  uiMultiplier: "0xa60bf13d",
  newUIMultiplier: "0xdc767007",
  effectiveAt: "0x97a4064f",
  getPool: "0xbbe4f6db", // TokenAdminRegistry.getPool(address)
};

/** Rate limits, gateway errors and dropped connections; a revert is final. */
const transient = (e: unknown) => {
  const err = e as Error & { cause?: { code?: string } };
  return /HTTP (429|502|503|504)|rate limit|too many requests|fetch failed|ECONNRESET|ETIMEDOUT|socket hang up/i.test(
    `${err?.message ?? e} ${err?.cause?.code ?? ""}`,
  );
};

/**
 * eth_call on Mantle, retried on transient failures (it only reads, so repeating it is safe; a
 * one-off 429 must not turn a reconciliation into a false alert). `rpcUrl` defaults to MANTLE_RPC_URL
 * or the network config's.
 */
export async function ethCall(to: string, data: string, rpcUrl?: string): Promise<string> {
  const url = rpcUrl ?? mantleRpc();
  return withRetry(
    async () => {
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
      });
      if (!res.ok) throw new Error(`eth_call ${data.slice(0, 10)} on ${to}: HTTP ${res.status}`);
      const json = (await res.json()) as { result?: string; error?: { message: string } };
      if (!json.result) throw new Error(`eth_call ${data.slice(0, 10)} on ${to}: ${json.error?.message ?? "no result"}`);
      return json.result;
    },
    6,
    transient,
  );
}

/** ABI-decodes a single returned `string`. */
function abiString(hex: string): string {
  const b = Buffer.from(hex.slice(2), "hex");
  const offset = Number(b.readBigUInt64BE(24));
  const length = Number(b.readBigUInt64BE(offset + 24));
  return b.subarray(offset + 32, offset + 32 + length).toString("utf8");
}
/** An address as a 32-byte ABI word (hex, no 0x). */
export const word = (addr: string) => addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");

/** The ScaledToken's name, symbol, asset code (ISIN) and current UI multiplier (1e18). */
export async function scaledToken(token: string) {
  const [name, symbol, assetCode, multiplier] = await Promise.all([
    ethCall(token, SELECTORS.name).then(abiString),
    ethCall(token, SELECTORS.symbol).then(abiString),
    ethCall(token, SELECTORS.assetCode).then(abiString),
    ethCall(token, SELECTORS.uiMultiplier).then(BigInt),
  ]);
  return { name, symbol, assetCode, multiplier };
}

/** The pool registered for `token` in the TokenAdminRegistry (zero address when none). */
export async function registeredPool(registry: string, token: string, rpcUrl?: string): Promise<string> {
  const r = await ethCall(registry, SELECTORS.getPool + word(token), rpcUrl);
  return `0x${r.slice(-40)}`;
}
