// Network configuration. NETWORK=mainnet|testnet selects config.<network>.toml (NETWORK may also be a
// path to a .toml file, for rehearsals): [solana] and [mantle] hold each chain's endpoints and CCIP
// contracts, [program] / [admins] / [roles] / [ccip] the deployment. The scripts take addresses,
// selectors and endpoints from it, and a command-line value overrides it. The bash scripts read the
// same file through lib/config.sh. Without NETWORK the scripts are in local mode:
// every address comes from the command line and the RPC defaults to a local validator.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "smol-toml";

export type Config = {
  solana: { rpc: string; roles_rpc: string; chain_selector: string };
  mantle: {
    chain_id: number;
    rpc: string;
    chain_selector: string;
    router: string;
    rmn: string;
    token_admin_registry: string;
    registry_module: string;
    token_admin: string;
    pool_owner: string;
  };
  program: { id: string; min_notice_seconds: number; max_horizon_seconds: number };
  admins: { upgrade_authority: string; admin: string; compliance_admin: string; hook_authority: string };
  roles: Record<string, string[]>;
  ccip: { solana_ccip_admin: string };
};

export const NETWORK = process.env.NETWORK || undefined;
// A config file given as a relative path is resolved here, and NETWORK made absolute for the
// scripts this one starts (check-stock.ts runs its sub-checks from solana/).
export const CONFIG_PATH = NETWORK
  ? NETWORK.endsWith(".toml")
    ? (process.env.NETWORK = resolve(NETWORK))
    : fileURLToPath(new URL(`../../config.${NETWORK}.toml`, import.meta.url))
  : undefined;
export const config: Config | null = CONFIG_PATH ? (parse(readFileSync(CONFIG_PATH, "utf8")) as unknown as Config) : null;

/** A value from the command line, else from the config (`key` like "admins.admin"). */
export function setting(value: string | undefined, key: string, flag: string): string {
  if (value && value !== "true") return value;
  const fromConfig = key.split(".").reduce<unknown>((o, k) => (o as Record<string, unknown> | undefined)?.[k], config);
  if (typeof fromConfig === "string" && fromConfig) return fromConfig;
  throw new Error(
    config
      ? `${key} is empty in ${CONFIG_PATH}; fill it in or pass --${flag}`
      : `missing --${flag} (or set NETWORK=mainnet|testnet to take it from the config)`,
  );
}

/** Config role key (snake_case) → Core role name, in the program's enum order (= seed). */
export const ROLE_NAMES: Record<string, string> = {
  multiplier_scheduler: "MultiplierScheduler",
  pauser: "Pauser",
  unpauser: "Unpauser",
  freezer: "Freezer",
  unfreezer: "Unfreezer",
  clawback: "Clawback",
  metadata_ops: "MetadataOps",
  mint_registrar: "MintRegistrar",
};

/** The Solana CCIP token admin and pool owner of every mint: ccip.solana_ccip_admin, else admins.admin. */
export function ccipAdmin(): string {
  return config?.ccip.solana_ccip_admin || setting(undefined, "admins.admin", "handoff-to");
}

/** Mantle JSON-RPC endpoint: MANTLE_RPC_URL, else the config's. */
export function mantleRpc(): string {
  const url = process.env.MANTLE_RPC_URL || config?.mantle.rpc;
  if (!url) throw new Error("set MANTLE_RPC_URL (or NETWORK=mainnet|testnet)");
  return url;
}

if (config) {
  const rpc = process.env.RPC_URL || config.solana.rpc;
  console.error(`[${NETWORK}] config ${CONFIG_PATH}; Solana RPC ${new URL(rpc).host}`);
}
