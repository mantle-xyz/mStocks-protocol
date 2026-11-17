// Core program lifecycle in one command per step:
//   build                       anchor build + the tests; prints the .so's sha256
//   deploy  --deployer <kp>     first deployment with the deployer as upgrade authority, then verify
//   verify                      on-chain bytes == target/deploy/mstocks_core.so (exit 1 otherwise)
//   handoff --deployer <kp>     upgrade authority → the config's upgrade_authority multisig vault
//                               (refused before init-core: initialize needs the upgrade authority)
//   upgrade --deployer <kp>     writes a buffer, hands it to the vault and creates the Squads upgrade
//                               proposal (--squads-member / SQUADS_MEMBER); approve and execute it with
//                               squads.ts, then run verify
//   NETWORK=mainnet tsx scripts/program.ts <command> [--deployer <keypair>] [--to <squads multisig>]
// The Solana CLI gets -k explicitly: some subcommands otherwise fall back to the configured keypair.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { address, fetchEncodedAccount, getAddressDecoder } from "@solana/kit";
import { signerAddress } from "./lib/admin.ts";
import { setting } from "./lib/config.ts";
import { CORE_PROGRAM_ID, fetchConfig, programDataPda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, RPC_URL, withRetry } from "./lib/env.ts";
import { multisigFromConfig, propose, upgradeIx, vaultOf } from "./lib/squads.ts";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const SO = `${ROOT}target/deploy/mstocks_core.so`;
const PROGRAM_KEYPAIR = `${ROOT}target/deploy/mstocks_core-keypair.json`;
const [command, ...rest] = process.argv.slice(2);
const args = parseArgs(rest);

/** Runs a command in the solana/ directory; output is shown, or returned with `capture`. */
function run(cmd: string, cmdArgs: string[], capture = false): string {
  const r = spawnSync(cmd, cmdArgs, { cwd: ROOT, stdio: capture ? ["inherit", "pipe", "inherit"] : "inherit", encoding: "utf8" });
  if (r.status !== 0) throw new Error(`${cmd} ${cmdArgs[0]} ${cmdArgs[1] ?? ""} failed (exit ${r.status})`);
  return r.stdout ?? "";
}
const solana = (deployer: string, ...a: string[]) => run("solana", [...a, "-k", deployer, "-u", RPC_URL], true);

async function upgradeAuthority(): Promise<string> {
  const pd = await withRetry(async () => fetchEncodedAccount(rpc, await programDataPda()));
  if (!pd.exists) return "not deployed";
  return pd.data[12] === 1 ? getAddressDecoder().decode(pd.data.subarray(13, 45)) : "none (immutable)";
}

async function verify(): Promise<boolean> {
  const pd = await withRetry(async () => fetchEncodedAccount(rpc, await programDataPda()));
  if (!pd.exists) throw new Error(`program ${CORE_PROGRAM_ID} is not deployed`);
  const onChain = pd.data.subarray(45); // ProgramData header: tag, slot, Option<authority>
  const built = readFileSync(SO);
  const same = Buffer.from(onChain.subarray(0, built.length)).equals(built) && onChain.subarray(built.length).every((b) => b === 0);
  console.log(`on-chain program ${same ? "matches" : "DIFFERS FROM"} ${SO} (sha256 ${sha256(built)})`);
  console.log(`upgrade authority: ${await upgradeAuthority()}`);
  return same;
}
const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");

switch (command) {
  case "build": {
    const id = run("solana-keygen", ["pubkey", PROGRAM_KEYPAIR], true).trim();
    if (id !== CORE_PROGRAM_ID) throw new Error(`program keypair is ${id}, the IDL says ${CORE_PROGRAM_ID}`);
    run("anchor", ["build"]);
    run("cargo", ["test", "-p", "mstocks-core"]);
    console.log(`program ${id}\nsha256 ${sha256(readFileSync(SO))}  ${SO}`);
    break;
  }
  case "deploy": {
    const deployer = required(args, "deployer");
    const current = await upgradeAuthority();
    if (current !== "not deployed") throw new Error(`program ${CORE_PROGRAM_ID} is already deployed (upgrade authority ${current}); use upgrade`);
    run("solana", ["program", "deploy", SO, "--program-id", PROGRAM_KEYPAIR, "--upgrade-authority", deployer, "-k", deployer, "-u", RPC_URL, "--use-rpc"]);
    if (!(await verify())) process.exit(1);
    break;
  }
  case "verify":
    if (!(await verify())) process.exit(1);
    break;
  case "handoff": {
    const deployer = required(args, "deployer");
    if (!(await fetchConfig())) throw new Error("Core is not initialized: run init-core.ts first (it needs the current upgrade authority)");
    const vault = await signerAddress(setting(args.to, "admins.upgrade_authority", "to"));
    if (vault === (await loadKeypair(deployer)).address) throw new Error("the new upgrade authority is the deployer itself");
    solana(deployer, "program", "set-upgrade-authority", CORE_PROGRAM_ID, "--upgrade-authority", deployer,
      "--new-upgrade-authority", vault, "--skip-new-upgrade-authority-signer-check");
    console.log(`upgrade authority: ${await upgradeAuthority()}`);
    break;
  }
  case "upgrade": {
    const deployer = required(args, "deployer");
    const multisigPda = multisigFromConfig(args.to ?? "upgrade_authority");
    const vault = address(vaultOf(multisigPda).toBase58());
    const current = await upgradeAuthority();
    if (current !== vault) throw new Error(`upgrade authority is ${current}, not the multisig vault ${vault}`);
    console.log(`new build sha256 ${sha256(readFileSync(SO))}`);
    const out = solana(deployer, "program", "write-buffer", SO, "--buffer-authority", deployer, "--use-rpc");
    const buffer = out.match(/Buffer:\s+(\w+)/)?.[1];
    if (!buffer) throw new Error(`no buffer address in: ${out}`);
    solana(deployer, "program", "set-buffer-authority", buffer, "--buffer-authority", deployer, "--new-buffer-authority", vault);
    console.log(`buffer ${buffer} (authority ${vault})`);
    const member = args["squads-member"] ?? process.env.SQUADS_MEMBER ?? required(args, "squads-member");
    const spill = (await loadKeypair(deployer)).address;
    const p = await propose(multisigPda, [upgradeIx(CORE_PROGRAM_ID, address(buffer), spill, vault)], member, `upgrade ${CORE_PROGRAM_ID}`);
    console.log(`upgrade: Squads proposal #${p.transactionIndex} on ${multisigPda.toBase58()} (${p.signature})`);
    console.log(`  needs ${p.threshold} approval(s), then executable ${p.timeLock}s after approval; then: program.ts verify`);
    break;
  }
  default:
    throw new Error("usage: tsx scripts/program.ts <build|deploy|verify|handoff|upgrade> [--deployer <keypair>]");
}
