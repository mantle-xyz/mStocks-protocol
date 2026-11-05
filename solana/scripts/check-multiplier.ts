// Plan B reconciliation: compares each Solana mint's multiplier state with its Mantle ScaledToken.
// The Mantle token address comes from Core's MintState, so only the mints are needed.
//
//   MANTLE_RPC_URL=<mantle rpc> tsx scripts/check-multiplier.ts --mints a,b,c
//
// For each mint it compares, at the current time, the effective multiplier and the pending change
// (value + effective time). Exit code 1 on any mismatch, so a cron job can alert on it. Within
// SKEW_SECONDS of an effective time the two chains' clocks may briefly disagree; that is reported
// as a warning instead.
import { address, fetchEncodedAccount, type Address } from "@solana/kit";
import { getMintDecoder } from "@solana-program/token-2022";
import { mintStatePda, toF64 } from "./lib/core.ts";
import { parseArgs, required, rpc, withRetry } from "./lib/env.ts";

const SKEW_SECONDS = 60n;
const SELECTORS = { uiMultiplier: "0xa60bf13d", newUIMultiplier: "0xdc767007", effectiveAt: "0x97a4064f" };

const args = parseArgs();
const mantleRpc = process.env.MANTLE_RPC_URL ?? required(args, "mantle-rpc");
const mints: Address[] = required(args, "mints").split(",").map((m) => address(m.trim()));

async function ethCall(to: string, data: string): Promise<bigint> {
  const res = await fetch(mantleRpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
  });
  const json = (await res.json()) as { result?: string; error?: { message: string } };
  if (!json.result) throw new Error(`eth_call ${data} on ${to}: ${json.error?.message ?? res.status}`);
  return BigInt(json.result);
}

/** Mantle state in Token-2022 terms: effective value and optional pending (value, time). */
async function mantleState(token: string) {
  const [current, next, effectiveAt] = await Promise.all([
    ethCall(token, SELECTORS.uiMultiplier),
    ethCall(token, SELECTORS.newUIMultiplier),
    ethCall(token, SELECTORS.effectiveAt),
  ]);
  return { current: toF64(current), pending: effectiveAt === 0n ? null : { value: toF64(next), at: effectiveAt } };
}

/** Solana state at `now`: Token-2022 switches to new_multiplier once its timestamp passes. */
async function solanaState(mint: Address, now: bigint) {
  const account = await withRetry(() => fetchEncodedAccount(rpc, mint));
  if (!account.exists) throw new Error(`mint ${mint} not found`);
  const decoded = getMintDecoder().decode(account.data);
  const ext = (decoded.extensions.__option === "Some" ? decoded.extensions.value : []).find(
    (e) => e.__kind === "ScaledUiAmountConfig",
  );
  if (!ext || ext.__kind !== "ScaledUiAmountConfig") throw new Error(`mint ${mint} has no Scaled UI Amount config`);
  const at = BigInt(ext.newMultiplierEffectiveTimestamp);
  return now >= at
    ? { current: ext.newMultiplier, pending: null }
    : { current: ext.multiplier, pending: { value: ext.newMultiplier, at } };
}

async function mantleTokenOf(mint: Address): Promise<string> {
  const statePda = await mintStatePda(mint);
  const state = await withRetry(() => fetchEncodedAccount(rpc, statePda));
  if (!state.exists) throw new Error(`mint ${mint} is not registered with Core`);
  // MintState: 8-byte discriminator, mint (32), mantle_token (20).
  return "0x" + Buffer.from(state.data.subarray(40, 60)).toString("hex");
}

let mismatches = 0;
for (const mint of mints) {
  const token = await mantleTokenOf(mint);
  const now = BigInt(Math.floor(Date.now() / 1000));
  const [m, s] = await Promise.all([mantleState(token), solanaState(mint, now)]);
  const fmt = (x: { current: number; pending: { value: number; at: bigint } | null }) =>
    `current ${x.current}${x.pending ? `, pending ${x.pending.value} @ ${x.pending.at}` : ""}`;
  const same =
    m.current === s.current &&
    (m.pending === null) === (s.pending === null) &&
    (m.pending === null || (m.pending.value === s.pending!.value && m.pending.at === s.pending!.at));

  // Near an effective time one chain may already have switched while the other has not.
  const boundaries = [m.pending?.at, s.pending?.at].filter((t): t is bigint => t !== undefined);
  const nearBoundary = boundaries.some((t) => (now > t ? now - t : t - now) <= SKEW_SECONDS);

  const status = same ? "OK" : nearBoundary ? "WARN (near effective time, recheck)" : "MISMATCH";
  if (!same && !nearBoundary) mismatches++;
  console.log(`${status.padEnd(8)} ${mint} ↔ ${token}\n         mantle: ${fmt(m)}\n         solana: ${fmt(s)}`);
}
process.exit(mismatches > 0 ? 1 : 0);
