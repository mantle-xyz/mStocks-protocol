// Checks a deployed mstocks-core against a config file (config.mainnet.toml / config.devnet.toml):
// the config itself (both admins set and different, no admin holding a role), the Config account
// (admins, hook authority, notice and horizon), the program's upgrade authority, and every role's
// holders on chain (no missing and no extra holder; the retired Clawback has none). Exits 1 on any
// problem, so it can gate each launch step.
//   RPC_URL=<rpc> tsx scripts/check-config.ts --config config.mainnet.toml [--roles-rpc <rpc>]
// Listing role holders needs getProgramAccounts; pass --roles-rpc when RPC_URL's provider rejects it.
import { readFileSync } from "node:fs";
import {
  address,
  createSolanaRpc,
  fetchEncodedAccount,
  getAddressDecoder,
  getBase58Decoder,
  type Address,
} from "@solana/kit";
import { parse } from "smol-toml";
import { configPda, programDataPda } from "./lib/core.ts";
import { parseArgs, required, rpc, RPC_URL, withRetry } from "./lib/env.ts";

const args = parseArgs();
type Cfg = {
  program: { id: string; min_notice_seconds: number; max_horizon_seconds: number };
  admins: { upgrade_authority: string; admin: string; compliance_admin: string; hook_authority: string };
  roles: Record<string, string[]>;
};
const cfg = parse(readFileSync(required(args, "config"), "utf8")) as unknown as Cfg;
const rolesRpc = createSolanaRpc(args["roles-rpc"] ?? RPC_URL);
const dec = getAddressDecoder();

// Role enum order (= seed); `clawback` is retired and must have no holder.
const ROLE_KEYS = [
  "multiplier_scheduler",
  "pauser",
  "unpauser",
  "freezer",
  "unfreezer",
  "clawback",
  "metadata_ops",
  "mint_registrar",
];
const ROLE_ENTRY_DISCRIMINATOR = Uint8Array.from([161, 238, 39, 6, 64, 179, 124, 31]);

let failures = 0;
const ok = (label: string, value: string) => console.log(`  ok   ${label}: ${value}`);
const fail = (label: string, detail: string) => {
  failures++;
  console.log(`  FAIL ${label}: ${detail}`);
};
const expect = (label: string, actual: string, wanted: string) =>
  actual === wanted ? ok(label, actual) : fail(label, `${actual} (want ${wanted || "<not set in config>"})`);

console.log("== config file");
const { admin, compliance_admin: complianceAdmin, hook_authority: hook, upgrade_authority: upgrade } = cfg.admins;
for (const [k, v] of Object.entries(cfg.admins)) (v ? ok : fail)(`admins.${k}`, v || "not set");
if (admin && admin === complianceAdmin) fail("admins", "admin and compliance_admin must differ");
for (const [role, members] of Object.entries(cfg.roles)) {
  if (!ROLE_KEYS.includes(role) || role === "clawback") fail(`roles.${role}`, "unknown or retired role");
  for (const m of members)
    if (m === admin || m === complianceAdmin) fail(`roles.${role}`, `${m} is an admin; admins cannot hold roles`);
}

console.log("== Config account");
const conf = await (async () => {
  const acc = await withRetry(async () => fetchEncodedAccount(rpc, await configPda()));
  if (!acc.exists) return null;
  const d = acc.data;
  let o = 8;
  const key = () => dec.decode(d.subarray(o, (o += 32)));
  const opt = () => (d[o++] === 1 ? key() : null);
  const i64 = () => {
    const v = new DataView(d.buffer, d.byteOffset + o, 8).getBigInt64(0, true);
    o += 8;
    return v;
  };
  const c = { admin: key(), pendingAdmin: opt(), hook: key(), minNotice: i64(), maxHorizon: i64() };
  o += 2; // bump, authority_bump
  return { ...c, complianceAdmin: key(), pendingComplianceAdmin: opt() };
})();
if (!conf) fail("Config", "not initialized");
else {
  expect("admin", conf.admin, admin);
  expect("compliance admin", conf.complianceAdmin, complianceAdmin);
  expect("hook authority", conf.hook, hook);
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
const res = await rolesRpc
  .getProgramAccounts(address(cfg.program.id), {
    encoding: "base64",
    filters: [
      { dataSize: 42n },
      {
        memcmp: { offset: 0n, bytes: getBase58Decoder().decode(ROLE_ENTRY_DISCRIMINATOR) as never, encoding: "base58" },
      },
    ],
  })
  .send()
  .catch((e: Error) => e);
if (res instanceof Error)
  fail("role holders", `getProgramAccounts failed (${res.message.slice(0, 80)}); pass --roles-rpc`);
else {
  const onChain = new Map<string, Set<Address>>();
  for (const { account } of res) {
    const d = Buffer.from(account.data[0], "base64");
    const role = ROLE_KEYS[d[8]];
    if (!onChain.has(role)) onChain.set(role, new Set());
    onChain.get(role)!.add(dec.decode(d.subarray(9, 41)));
  }
  for (const role of ROLE_KEYS) {
    const want = new Set(role === "clawback" ? [] : (cfg.roles[role] ?? []));
    const have = onChain.get(role) ?? new Set();
    const missing = [...want].filter((m) => !have.has(m as Address));
    const extra = [...have].filter((m) => !want.has(m));
    if (!missing.length && !extra.length) ok(role, [...have].join(", ") || "none");
    else
      fail(
        role,
        `${missing.length ? `missing ${missing.join(", ")} ` : ""}${extra.length ? `unexpected ${extra.join(", ")}` : ""}`,
      );
  }
}

console.log(failures ? `FAILED (${failures})` : "PASS");
process.exit(failures ? 1 : 0);
