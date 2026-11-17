// All checks of one launched stock, PASS or FAIL in one command (exit 1 on a problem):
//   - the mint: every authority with Core (freeze, scaled UI amount, pause, metadata pointer and
//     update authority, permanent delegate), the mint authority with the CCIP pool, the dormant
//     transfer hook held by the config's hook authority, not paused;
//   - CCIP on Solana: token admin and pool owner = the config's CCIP admin, nothing pending, pool set;
//   - Mantle: ccip-mantle-setup.sh verify (pool from the TokenAdminRegistry), check-multiplier.ts and
//     check-supply.ts.
//   NETWORK=mainnet tsx scripts/check-stock.ts --mint <mint>
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { address, fetchEncodedAccount } from "@solana/kit";
import { getMintDecoder } from "@solana-program/token-2022";
import { signerAddress } from "./lib/admin.ts";
import { ccipAccounts, poolOwnership, registryState, SYSTEM_PROGRAM } from "./lib/ccip.ts";
import { ccipAdmin, config, NETWORK, setting } from "./lib/config.ts";
import { authorityPda, mintStatePda } from "./lib/core.ts";
import { parseArgs, required, rpc, withRetry } from "./lib/env.ts";
import { registeredPool } from "./lib/mantle.ts";

const args = parseArgs();
if (!config || !NETWORK) throw new Error("set NETWORK=mainnet|testnet: check-stock compares against the network config");
const mint = address(required(args, "mint"));
const ROOT = fileURLToPath(new URL("..", import.meta.url));

let failures = 0;
const ok = (label: string, value: string) => console.log(`  ok   ${label}: ${value}`);
const fail = (label: string, detail: string) => {
  failures++;
  console.log(`  FAIL ${label}: ${detail}`);
};
const expect = (label: string, actual: unknown, wanted: unknown) =>
  actual === wanted ? ok(label, String(actual)) : fail(label, `${actual} (want ${wanted})`);

console.log(`== Core registration`);
const state = await withRetry(async () => fetchEncodedAccount(rpc, await mintStatePda(mint)));
if (!state.exists) {
  fail("MintState", `${mint} is not registered with Core`);
  process.exit(1);
}
// MintState: 8-byte discriminator, mint (32), mantle_token (20).
const token = `0x${Buffer.from(state.data.subarray(40, 60)).toString("hex")}`;
ok("Mantle token", token);

console.log(`== mint`);
const authority = await authorityPda();
const ccip = await ccipAccounts(mint);
const acc = await withRetry(() => fetchEncodedAccount(rpc, mint));
if (!acc.exists) throw new Error(`mint ${mint} not found`);
const m = getMintDecoder().decode(acc.data);
const opt = (o: { __option: string; value?: unknown }) => (o.__option === "Some" ? String(o.value) : "none");
expect("mint authority (CCIP pool signer)", opt(m.mintAuthority), ccip.poolSigner);
expect("freeze authority", opt(m.freezeAuthority), authority);
const hook = await signerAddress(setting(undefined, "admins.hook_authority", "hook-authority"));
const ext = Object.fromEntries((m.extensions.__option === "Some" ? m.extensions.value : []).map((e) => [e.__kind, e as Record<string, unknown>]));
const field = (kind: string, key: string) => {
  const v = ext[kind]?.[key] as { __option?: string; value?: unknown } | string | undefined;
  return v && typeof v === "object" && "__option" in v ? opt(v as { __option: string; value?: unknown }) : String(v);
};
expect("scaled UI amount authority", field("ScaledUiAmountConfig", "authority"), authority);
expect("pause authority", field("PausableConfig", "authority"), authority);
expect("paused", field("PausableConfig", "paused"), "false");
expect("metadata pointer authority", field("MetadataPointer", "authority"), authority);
expect("metadata update authority", field("TokenMetadata", "updateAuthority"), authority);
expect("permanent delegate", field("PermanentDelegate", "delegate"), authority);
expect("transfer hook authority", field("TransferHook", "authority"), hook);
expect("transfer hook program", field("TransferHook", "programId"), SYSTEM_PROGRAM);

console.log(`== CCIP on Solana`);
const admin = await signerAddress(ccipAdmin());
const [reg, pool] = [await registryState(ccip), await poolOwnership(ccip)];
if (!reg || !pool) fail("CCIP", "not registered");
else {
  expect("token admin", reg.admin, admin);
  expect("pending token admin", reg.pending, SYSTEM_PROGRAM);
  (reg.lookupTable !== SYSTEM_PROGRAM ? ok : fail)("pool set (lookup table)", reg.lookupTable);
  expect("pool owner", pool.owner, admin);
  expect("proposed pool owner", pool.proposed, SYSTEM_PROGRAM);
}

console.log(`== Mantle`);
const mantlePool = await registeredPool(config.mantle.token_admin_registry, token);
const sub = (label: string, cmd: string, cmdArgs: string[]) => {
  const r = spawnSync(cmd, cmdArgs, { cwd: ROOT, encoding: "utf8", env: process.env });
  const out = `${r.stdout}${r.stderr}`.split("\n").filter((l) => l && !l.includes("npm warn"));
  const tail = out.filter((l) => /^(OK|MISMATCH|WARN|FAIL|PASS|FAILED)|FAIL /.test(l.trim()));
  (r.status === 0 ? ok : fail)(label, (tail.length ? tail : out.slice(-1)).join(" | ").slice(0, 300));
};
if (BigInt(mantlePool) === 0n) fail("Mantle pool", `none registered for ${token}`);
else sub(`verify (pool ${mantlePool})`, "scripts/ccip-mantle-setup.sh", ["verify", token, mantlePool, mint]);
sub("multiplier", "npx", ["tsx", "scripts/check-multiplier.ts", "--mints", mint]);
sub("supply", "npx", ["tsx", "scripts/check-supply.ts", "--mints", mint]);

console.log(failures ? `FAILED (${failures})` : "PASS");
process.exit(failures ? 1 : 0);
