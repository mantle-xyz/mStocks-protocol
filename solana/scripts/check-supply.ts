// Supply reconciliation: every token on Solana is minted by the CCIP BurnMint pool against tokens
// locked in the Mantle LockRelease pool, so for each mint
//
//   Solana supply × 10^(Mantle decimals − Solana decimals) ≤ balance of the Mantle pool
//
// must always hold: Mantle → Solana locks before Solana mints, and Solana → Mantle burns before
// Mantle releases. The difference is tokens in flight to Solana plus tokens holders burned on
// Solana (those stay locked on Mantle for good). A Solana supply above the locked amount means
// tokens were minted without a lock, so it exits 1 for alerting. If the Mantle pool also serves
// other chains, its balance covers them too and this remains a necessary (not sufficient) check.
//
//   NETWORK=mainnet tsx scripts/check-supply.ts --mints a,b,c
//     [--registry <Mantle TokenAdminRegistry>]   (default: the config's; Mantle RPC: MANTLE_RPC_URL or the config's)
//
// The Mantle token comes from Core's MintState and its pool from the TokenAdminRegistry.
import { address, fetchEncodedAccount, type Address } from "@solana/kit";
import { getMintDecoder } from "@solana-program/token-2022";
import { mantleTokenOf } from "./lib/core.ts";
import { config, setting } from "./lib/config.ts";
import { parseArgs, required, rpc, withRetry } from "./lib/env.ts";
import { ethCall as mantleCall, registeredPool, SELECTORS, word } from "./lib/mantle.ts";

const args = parseArgs();
const mantleRpc = process.env.MANTLE_RPC_URL || config?.mantle.rpc || required(args, "mantle-rpc");
const registry = setting(args.registry, "mantle.token_admin_registry", "registry");
const mints: Address[] = required(args, "mints")
  .split(",")
  .map((m) => address(m.trim()));

const ethCall = async (to: string, data: string) => BigInt(await mantleCall(to, data, mantleRpc));

async function solanaSupply(mint: Address) {
  const account = await withRetry(() => fetchEncodedAccount(rpc, mint));
  if (!account.exists) throw new Error(`mint ${mint} not found`);
  const decoded = getMintDecoder().decode(account.data);
  return { supply: decoded.supply, decimals: decoded.decimals };
}

const fmt = (raw: bigint, decimals: number) => {
  const s = raw.toString().padStart(decimals + 1, "0");
  return `${s.slice(0, -decimals)}.${s.slice(-decimals)}`.replace(/\.?0+$/, "");
};

let violations = 0;
for (const mint of mints) {
  const token = await mantleTokenOf(mint);
  if (!token) throw new Error(`mint ${mint} is not registered with Core`);
  const pool = await registeredPool(registry, token, mantleRpc);
  if (BigInt(pool) === 0n) throw new Error(`no pool registered for ${token} in ${registry}`);
  const [solana, locked, mantleDecimals] = await Promise.all([
    solanaSupply(mint),
    ethCall(token, SELECTORS.balanceOf + word(pool)),
    ethCall(token, SELECTORS.decimals),
  ]);
  const scaled = solana.supply * 10n ** (mantleDecimals - BigInt(solana.decimals));
  const ok = scaled <= locked;
  if (!ok) violations++;
  const d = Number(mantleDecimals);
  console.log(
    `${(ok ? "OK" : "VIOLATION").padEnd(9)} ${mint} ↔ ${token} (pool ${pool})\n` +
      `          solana supply ${fmt(scaled, d)}, locked on mantle ${fmt(locked, d)}, ` +
      (ok ? `in flight or burned on solana ${fmt(locked - scaled, d)}` : `UNBACKED ${fmt(scaled - locked, d)}`),
  );
}
process.exit(violations > 0 ? 1 : 0);
