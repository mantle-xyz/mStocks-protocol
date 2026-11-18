// Plan B reconciliation: compares each Solana mint's multiplier state with its Mantle ScaledToken.
// The Mantle token address comes from Core's MintState, so only the mints are needed.
//
//   NETWORK=mainnet tsx scripts/check-multiplier.ts --mints a,b,c   (Mantle RPC: MANTLE_RPC_URL or the config's)
//
// For each mint it compares, at the current time, the effective multiplier and the pending change
// (value + effective time). Exit code 1 on any mismatch, so a cron job can alert on it. Within
// SKEW_SECONDS of an effective time the two chains' clocks may briefly disagree; that is reported
// as a warning instead.
import { address, fetchEncodedAccount, type Address } from "@solana/kit";
import { getMintDecoder } from "@solana-program/token-2022";
import { mantleTokenOf, toF64 } from "./lib/core.ts";
import { config } from "./lib/config.ts";
import { parseArgs, required, rpc, withRetry } from "./lib/env.ts";
import { ethCall as mantleCall, SELECTORS } from "./lib/mantle.ts";

const SKEW_SECONDS = 60n;

const args = parseArgs();
const mantleRpc = process.env.MANTLE_RPC_URL || config?.mantle.rpc || required(args, "mantle-rpc");
const mints: Address[] = required(args, "mints").split(",").map((m) => address(m.trim()));

const ethCall = async (to: string, data: string) => BigInt(await mantleCall(to, data, mantleRpc));

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

let mismatches = 0;
for (const mint of mints) {
  const token = await mantleTokenOf(mint);
  if (!token) throw new Error(`mint ${mint} is not registered with Core`);
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
