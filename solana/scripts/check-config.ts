// Checks a deployed mstocks-core against its network config (config.mainnet.toml / config.testnet.toml):
// the config itself (both admins set and different, no admin holding a role), the Config account
// (admins, hook authority, notice and horizon), the program's upgrade authority, and every role's
// holders on chain (no missing and no extra holder; the retired Clawback has none). Exits 1 on any
// problem, so it can gate each launch step. Addresses in the config may be Squads multisig accounts;
// they are checked as their vaults, the addresses that sign.
//   NETWORK=mainnet tsx scripts/check-config.ts [--config <file>] [--roles-rpc <rpc>]
// Listing role holders needs getProgramAccounts: the config's network.roles_rpc, or --roles-rpc.
import { readFileSync } from "node:fs";
import { fetchEncodedAccount, getAddressDecoder } from "@solana/kit";
import { parse } from "smol-toml";
import { configuredRoles, signerAddress } from "./lib/admin.ts";
import { CONFIG_PATH, ROLE_NAMES, type Config } from "./lib/config.ts";
import { fetchConfig, programDataPda, ROLE_NAMES_IN_ORDER, roleHolders } from "./lib/core.ts";
import { parseArgs, rpc, RPC_URL, withRetry } from "./lib/env.ts";

const args = parseArgs();
const path = args.config ?? CONFIG_PATH;
if (!path) throw new Error("set NETWORK=mainnet|testnet or pass --config <file>");
const cfg = parse(readFileSync(path, "utf8")) as unknown as Config;
const toSigner = (v: string) => (v ? signerAddress(v) : Promise.resolve(v));
for (const k of Object.keys(cfg.admins) as (keyof Config["admins"])[]) cfg.admins[k] = await toSigner(cfg.admins[k]);
const rolesRpc = args["roles-rpc"] ?? cfg.network?.roles_rpc ?? RPC_URL;
const dec = getAddressDecoder();

let failures = 0;
const ok = (label: string, value: string) => console.log(`  ok   ${label}: ${value}`);
const fail = (label: string, detail: string) => {
  failures++;
  console.log(`  FAIL ${label}: ${detail}`);
};
const expect = (label: string, actual: string, wanted: string) =>
  actual === wanted ? ok(label, actual) : fail(label, `${actual} (want ${wanted || "<not set in config>"})`);

console.log(`== config file ${path}`);
const { admin, compliance_admin: complianceAdmin, hook_authority: hook, upgrade_authority: upgrade } = cfg.admins;
for (const [k, v] of Object.entries(cfg.admins)) (v ? ok : fail)(`admins.${k}`, v || "not set");
if (admin && admin === complianceAdmin) fail("admins", "admin and compliance_admin must differ");
const want = await configuredRoles(cfg.roles).catch((e: Error) => (fail("roles", e.message), new Map<string, Set<string>>()));
for (const [role, members] of want)
  for (const m of members)
    if (m === admin || m === complianceAdmin) fail(`roles.${role}`, `${m} is an admin; admins cannot hold roles`);

console.log("== Config account");
const conf = await fetchConfig();
if (!conf) fail("Config", "not initialized");
else {
  expect("admin", conf.admin, admin);
  expect("compliance admin", conf.complianceAdmin, complianceAdmin);
  expect("hook authority", conf.hookAuthority, hook);
  expect("pending admin", String(conf.pendingAdmin), "null");
  expect("pending compliance admin", String(conf.pendingComplianceAdmin), "null");
  expect("min notice", String(conf.minNotice), String(cfg.program.min_notice_seconds));
  expect("max horizon", String(conf.maxHorizon), String(cfg.program.max_horizon_seconds));
}

console.log("== program");
// ProgramData: u32 enum tag, u64 slot, Option<Pubkey> upgrade authority.
const pd = await withRetry(async () => fetchEncodedAccount(rpc, await programDataPda()));
if (!pd.exists) fail("program data", "not found");
else
  expect("upgrade authority", pd.data[12] === 1 ? dec.decode(pd.data.subarray(13, 45)) : "none (immutable)", upgrade);

console.log("== role holders");
const have = await roleHolders(rolesRpc).catch((e: Error) => e);
if (have instanceof Error) fail("role holders", `getProgramAccounts failed (${have.message.slice(0, 80)}); pass --roles-rpc`);
else {
  const keyOf = Object.fromEntries(Object.entries(ROLE_NAMES).map(([k, v]) => [v, k]));
  for (const role of ROLE_NAMES_IN_ORDER) {
    const wanted = want.get(role) ?? new Set<string>();
    const held = have.get(role) ?? new Set<string>();
    const missing = [...wanted].filter((m) => !held.has(m as never));
    const extra = [...held].filter((m) => !wanted.has(m));
    if (!missing.length && !extra.length) ok(keyOf[role], [...held].join(", ") || "none");
    else
      fail(keyOf[role], `${missing.length ? `missing ${missing.join(", ")} ` : ""}${extra.length ? `unexpected ${extra.join(", ")}` : ""}`);
  }
}

console.log(failures ? `FAILED (${failures})` : "PASS");
process.exit(failures ? 1 : 0);
