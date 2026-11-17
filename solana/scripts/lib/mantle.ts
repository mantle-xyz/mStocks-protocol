// Read-only calls to Mantle (eth_call over JSON-RPC): ScaledToken metadata and the CCIP registry.
import { mantleRpc } from "./config.ts";

const SELECTORS = {
  name: "0x06fdde03",
  symbol: "0x95d89b41",
  assetCode: "0x4e841e3e",
  uiMultiplier: "0xa60bf13d",
  getPool: "0xbbe4f6db", // TokenAdminRegistry.getPool(address)
};

export async function ethCall(to: string, data: string): Promise<string> {
  const res = await fetch(mantleRpc(), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
  });
  const json = (await res.json()) as { result?: string; error?: { message: string } };
  if (!json.result) throw new Error(`eth_call ${data} on ${to}: ${json.error?.message ?? res.status}`);
  return json.result;
}

/** ABI-decodes a single returned `string`. */
function abiString(hex: string): string {
  const b = Buffer.from(hex.slice(2), "hex");
  const offset = Number(b.readBigUInt64BE(24));
  const length = Number(b.readBigUInt64BE(offset + 24));
  return b.subarray(offset + 32, offset + 32 + length).toString("utf8");
}
const word = (addr: string) => addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");

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
export async function registeredPool(registry: string, token: string): Promise<string> {
  const r = await ethCall(registry, SELECTORS.getPool + word(token));
  return `0x${r.slice(-40)}`;
}
