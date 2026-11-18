// Core program lifecycle in one command per step:
//   build                       anchor build + the tests; prints the .so's sha256
//   deploy  --deployer <kp>     first deployment with the deployer as upgrade authority, the IDL
//                               uploaded, then verify
//   verify                      on-chain bytes == target/deploy/mstocks_core.so and on-chain IDL ==
//                               target/idl/mstocks_core.json (exit 1 otherwise)
//   handoff --deployer <kp>     upgrade authority → the config's upgrade_authority multisig vault
//                               (refused before init-core: initialize needs the upgrade authority)
//   upgrade --deployer <kp>     writes the program buffer (and an IDL buffer when the IDL changed),
//                               hands them to the vault and prints the upgrade, with the IDL update,
//                               as one base58 transaction message for the Squads app; after the
//                               members approve and execute it, run verify
//   idl     --deployer <kp>     makes the on-chain IDL match the local one: directly while the deployer
//                               is the upgrade authority, else as a base58 message for the Squads app
// The IDL is kept where Anchor 1.x keeps it (Program Metadata, see lib/idl.ts); --idl <file>
// overrides target/idl/mstocks_core.json.
//   NETWORK=mainnet DEPLOYER=<keypair> tsx scripts/program.ts <command> [--deployer <keypair>] [--to <squads multisig>]
// --deployer defaults to the DEPLOYER environment variable: a keypair file or a private key (base58 or a
// JSON byte array); an inline key goes to the Solana CLI through an owner-only temporary file.
// The Solana CLI gets -k explicitly: some subcommands otherwise fall back to the configured keypair.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { address, fetchEncodedAccount, getAddressDecoder, type Address, type Instruction, type KeyPairSigner } from "@solana/kit";
import { printSquadsImport, signerAddress } from "./lib/admin.ts";
import { setting } from "./lib/config.ts";
import { CORE_PROGRAM_ID, fetchConfig, programDataPda } from "./lib/core.ts";
import { deployerKey, keypairFile, loadKeypair, parseArgs, rpc, RPC_URL, send, withRetry } from "./lib/env.ts";
import { createIdl, encodeIdl, readIdl, replaceIdl, sameIdl, topUp, topUpInstruction, writeBuffer } from "./lib/idl.ts";
import { multisigFromConfig, upgradeIx, vaultOf } from "./lib/squads.ts";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const SO = `${ROOT}target/deploy/mstocks_core.so`;
const PROGRAM_KEYPAIR = `${ROOT}target/deploy/mstocks_core-keypair.json`;
const IDL_FILE = `${ROOT}target/idl/mstocks_core.json`;
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

const localIdl = () => readFileSync(args.idl ?? IDL_FILE, "utf8");
async function verifyIdl(): Promise<boolean> {
  const onChain = await readIdl(CORE_PROGRAM_ID);
  const same = !!onChain && sameIdl(onChain.text, localIdl());
  console.log(`on-chain IDL ${!onChain ? "MISSING" : same ? "matches" : "DIFFERS FROM"} ${args.idl ?? IDL_FILE}`);
  return same;
}
const sendAll = async (payer: KeyPairSigner, txs: Instruction[][]) => {
  for (const ixs of txs) await send(payer, ixs);
};

/**
 * Brings the on-chain IDL in line with the local one. Creating it (none on chain) needs the deployer
 * as upgrade authority and is sent. Otherwise the deployer writes a buffer handed to `authority` and
 * tops up the rent; the returned instructions copy it in and must be signed by `authority` (sent here
 * when it is the deployer, else put into the multisig's transaction).
 */
async function syncIdl(deployer: KeyPairSigner, authority: Address): Promise<Instruction[]> {
  const json = localIdl();
  const data = encodeIdl(json);
  const onChain = await readIdl(CORE_PROGRAM_ID);
  if (onChain && sameIdl(onChain.text, json)) {
    console.log("IDL: on chain already matches");
    return [];
  }
  const programData = await programDataPda();
  if (!onChain) {
    if (authority !== deployer.address) throw new Error(`no IDL on chain and the upgrade authority is ${authority}, not the deployer`);
    await sendAll(deployer, await createIdl(deployer, deployer, CORE_PROGRAM_ID, programData, data));
    console.log(`IDL: uploaded (${data.length} bytes compressed)`);
    return [];
  }
  const { buffer, txs } = await writeBuffer(deployer, data, authority);
  await sendAll(deployer, txs);
  const extra = await topUp(onChain.lamports, data.length);
  if (extra > 0n) await send(deployer, [topUpInstruction(deployer, onChain.metadata, extra)]);
  console.log(`IDL: buffer ${buffer} (${data.length} bytes, was ${onChain.dataLength}), authority ${authority}`);
  const ixs = replaceIdl(onChain.metadata, authority === deployer.address ? deployer : authority, buffer,
    CORE_PROGRAM_ID, programData, onChain.dataLength, data.length, deployer.address);
  if (authority !== deployer.address) return ixs;
  await send(deployer, ixs);
  console.log("IDL: updated");
  return [];
}

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
    const deployer = await keypairFile(deployerKey(args, "deployer"));
    const current = await upgradeAuthority();
    if (current !== "not deployed") throw new Error(`program ${CORE_PROGRAM_ID} is already deployed (upgrade authority ${current}); use upgrade`);
    run("solana", ["program", "deploy", SO, "--program-id", PROGRAM_KEYPAIR, "--upgrade-authority", deployer, "-k", deployer, "-u", RPC_URL, "--use-rpc"]);
    const signer = await loadKeypair(deployer);
    await syncIdl(signer, signer.address);
    if (!((await verify()) && (await verifyIdl()))) process.exit(1);
    break;
  }
  case "verify": {
    const [program, idl] = [await verify(), await verifyIdl()];
    if (!(program && idl)) process.exit(1);
    break;
  }
  case "idl": {
    const signer = await loadKeypair(await keypairFile(deployerKey(args, "deployer")));
    const authority = await upgradeAuthority();
    if (authority === "not deployed" || authority.startsWith("none")) throw new Error(`upgrade authority: ${authority}`);
    const ixs = await syncIdl(signer, address(authority));
    if (ixs.length) {
      await signerAddress(multisigFromConfig(args.to ?? "upgrade_authority").toBase58()); // names the multisig
      await printSquadsImport(address(authority), ixs, "idl");
      console.log("after the members approve and execute it (time lock), run: program.ts verify");
    } else if (!(await verifyIdl())) process.exit(1);
    break;
  }
  case "handoff": {
    const deployer = await keypairFile(deployerKey(args, "deployer"));
    if (!(await fetchConfig())) throw new Error("Core is not initialized: run init-core.ts first (it needs the current upgrade authority)");
    const vault = await signerAddress(setting(args.to, "admins.upgrade_authority", "to"));
    if (vault === (await loadKeypair(deployer)).address) throw new Error("the new upgrade authority is the deployer itself");
    solana(deployer, "program", "set-upgrade-authority", CORE_PROGRAM_ID, "--upgrade-authority", deployer,
      "--new-upgrade-authority", vault, "--skip-new-upgrade-authority-signer-check");
    console.log(`upgrade authority: ${await upgradeAuthority()}`);
    break;
  }
  case "upgrade": {
    const deployer = await keypairFile(deployerKey(args, "deployer"));
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
    const signer = await loadKeypair(deployer);
    const idlIxs = await syncIdl(signer, vault);
    await signerAddress(multisigPda.toBase58()); // names the multisig in the output
    await printSquadsImport(vault, [upgradeIx(CORE_PROGRAM_ID, address(buffer), signer.address, vault), ...idlIxs], "upgrade");
    console.log("after the members approve and execute it (time lock), run: program.ts verify");
    break;
  }
  default:
    throw new Error("usage: tsx scripts/program.ts <build|deploy|verify|handoff|upgrade|idl> [--deployer <keypair>] (default: DEPLOYER)");
}
