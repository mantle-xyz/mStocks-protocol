// Core program lifecycle in one command per step:
//   build                       anchor build + the tests; prints the .so's sha256 and checks that the
//                               built IDL is the committed idl/mstocks_core.json (the scripts read it)
//   deploy  --deployer <kp>     first deployment with the deployer as upgrade authority, the IDL
//                               uploaded, then verify
//   verify                      on-chain bytes == target/deploy/mstocks_core.so and on-chain IDL ==
//                               idl/mstocks_core.json (exit 1 otherwise)
//   handoff --deployer <kp>     upgrade authority → the config's upgrade_authority multisig vault
//                               (refused before init-core: initialize needs the upgrade authority)
//   upgrade --deployer <kp>     writes the program buffer (and an IDL buffer when the IDL changed),
//                               hands them to the vault and prints the upgrade, with the IDL update,
//                               as one base58 transaction message for the Squads app; after the
//                               members approve and execute it, run verify
//   idl     --deployer <kp>     makes the on-chain IDL match the local one (creates it, replaces it, or
//                               finishes an interrupted upload): directly while the deployer is the
//                               upgrade authority, else as a base58 message for the Squads app
// upgrade and idl plan every transaction and check that the Squads message fits before the deployer
// spends anything; when the new build is larger than the program account, upgrade first extends the
// account (anyone may pay for that; the deployer does). The IDL is kept where Anchor 1.x keeps it
// (Program Metadata, see lib/idl.ts). --so <file> and --idl <file> override
// target/deploy/mstocks_core.so and idl/mstocks_core.json.
//   NETWORK=mainnet DEPLOYER=<keypair> tsx scripts/program.ts <command> [--deployer <keypair>] [--to <squads multisig>]
// --deployer defaults to the DEPLOYER environment variable: a keypair file or a private key (base58 or a
// JSON byte array); an inline key goes to the Solana CLI through an owner-only temporary file.
// The Solana CLI gets -k explicitly: some subcommands otherwise fall back to the configured keypair.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { address, fetchEncodedAccount, generateKeyPairSigner, getAddressDecoder, type Address, type Instruction, type KeyPairSigner } from "@solana/kit";
import { assertImportFits, printSquadsImport, signerAddress } from "./lib/admin.ts";
import { setting } from "./lib/config.ts";
import { CORE_PROGRAM_ID, fetchConfig, programDataPda } from "./lib/core.ts";
import { deployerKey, keypairFile, loadKeypair, parseArgs, rpc, RPC_URL, send, withRetry } from "./lib/env.ts";
import { planIdl, readIdl, sameIdl, type IdlPlan } from "./lib/idl.ts";
import { multisigFromConfig, upgradeIx } from "./lib/squads.ts";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const [command, ...rest] = process.argv.slice(2);
const args = parseArgs(rest);
const SO = args.so ?? `${ROOT}target/deploy/mstocks_core.so`;
const PROGRAM_KEYPAIR = `${ROOT}target/deploy/mstocks_core-keypair.json`;
/** The committed IDL: what the scripts encode instructions with and what is published on chain. */
const IDL_FILE = `${ROOT}idl/mstocks_core.json`;
const BUILT_IDL = `${ROOT}target/idl/mstocks_core.json`;
/** ProgramData header: u32 tag, u64 slot, Option<Pubkey> upgrade authority. */
const PROGRAM_DATA_HEADER = 45;
/** The loader extends a program account by at least this much (or to its maximum). */
const MIN_EXTEND = 10240;

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

/** Bytes of program the deployed program account can hold. */
async function programCapacity(): Promise<number> {
  const pd = await withRetry(async () => fetchEncodedAccount(rpc, await programDataPda()));
  if (!pd.exists) throw new Error(`program ${CORE_PROGRAM_ID} is not deployed`);
  return pd.data.length - PROGRAM_DATA_HEADER;
}

async function verify(): Promise<boolean> {
  const pd = await withRetry(async () => fetchEncodedAccount(rpc, await programDataPda()));
  if (!pd.exists) throw new Error(`program ${CORE_PROGRAM_ID} is not deployed`);
  const onChain = pd.data.subarray(PROGRAM_DATA_HEADER);
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
/** The IDL change for the upgrade authority `authority` (null when the chain already has the local IDL); nothing is sent. */
const planLocalIdl = async (deployer: KeyPairSigner, authority: Address) =>
  planIdl(CORE_PROGRAM_ID, await programDataPda(), deployer, authority, localIdl());

/** Sends the deployer's part of an IDL plan; returns the upgrade authority's instructions (none when that is the deployer). */
async function runIdlPlan(deployer: KeyPairSigner, plan: IdlPlan | null): Promise<Instruction[]> {
  if (!plan) {
    console.log("IDL: on chain already matches");
    return [];
  }
  console.log(`IDL: ${plan.summary}`);
  for (const [i, ixs] of plan.deployerTxs.entries()) {
    try {
      await send(deployer, ixs);
    } catch (e) {
      // A buffer the deployer still holds is closed, so its rent is not stranded.
      const c = plan.cleanup;
      if (c && i >= c.from && i < c.heldUntil)
        await send(deployer, c.ixs).then(
          () => console.log(`IDL: closed the unfinished buffer ${c.buffer}`),
          () => console.log(`IDL: could not close the unfinished buffer ${c.buffer}; the deployer can close it later`),
        );
      throw e;
    }
  }
  if (!plan.authorityIxs.length) console.log("IDL: done");
  return plan.authorityIxs;
}

switch (command) {
  case "build": {
    const id = run("solana-keygen", ["pubkey", PROGRAM_KEYPAIR], true).trim();
    if (id !== CORE_PROGRAM_ID) throw new Error(`program keypair is ${id}, the IDL says ${CORE_PROGRAM_ID}`);
    run("anchor", ["build"]);
    if (!sameIdl(readFileSync(BUILT_IDL, "utf8"), readFileSync(IDL_FILE, "utf8")))
      throw new Error(`the built IDL differs from ${IDL_FILE}: the program's interface changed, so copy ${BUILT_IDL} there and commit it`);
    run("cargo", ["test", "-p", "mstocks-core"]);
    console.log(`program ${id}\nsha256 ${sha256(readFileSync(SO))}  ${SO}`);
    break;
  }
  case "deploy": {
    const deployer = await keypairFile(deployerKey(args, "deployer"));
    const current = await upgradeAuthority();
    if (current !== "not deployed")
      throw new Error(`program ${CORE_PROGRAM_ID} is already deployed (upgrade authority ${current}); use upgrade (or idl to publish the IDL)`);
    run("solana", ["program", "deploy", SO, "--program-id", PROGRAM_KEYPAIR, "--upgrade-authority", deployer, "-k", deployer, "-u", RPC_URL, "--use-rpc"]);
    const signer = await loadKeypair(deployer);
    await runIdlPlan(signer, await planLocalIdl(signer, signer.address));
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
    const current = await upgradeAuthority();
    if (current === "not deployed" || current.startsWith("none")) throw new Error(`upgrade authority: ${current}`);
    const authority = address(current);
    if (authority !== signer.address) {
      // The multisig behind the vault: it names the proposal and sets its size limit. Resolved
      // before anything is spent.
      const vault = await signerAddress(multisigFromConfig(args.to ?? "upgrade_authority").toBase58());
      if (vault !== authority) throw new Error(`upgrade authority is ${authority}, not the multisig vault ${vault}`);
    }
    const plan = await planLocalIdl(signer, authority);
    if (plan?.authorityIxs.length) await assertImportFits(authority, plan.authorityIxs);
    const ixs = await runIdlPlan(signer, plan);
    if (ixs.length) {
      await printSquadsImport(authority, ixs, "idl");
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
    const vault = await signerAddress(multisigPda.toBase58()); // also names the multisig in the output
    const current = await upgradeAuthority();
    if (current !== vault) throw new Error(`upgrade authority is ${current}, not the multisig vault ${vault}`);
    const signer = await loadKeypair(deployer);
    // Plan the IDL change and check the whole proposal fits (sizes do not depend on the buffer's
    // address) before writing the program buffer, which costs SOL and is handed to the vault.
    const plan = await planLocalIdl(signer, vault);
    const idlIxs = plan?.authorityIxs ?? [];
    const placeholder = (await generateKeyPairSigner()).address;
    await assertImportFits(vault, [upgradeIx(CORE_PROGRAM_ID, placeholder, signer.address, vault), ...idlIxs]);
    console.log(`new build sha256 ${sha256(readFileSync(SO))}`);
    // The program account was sized for the first build; the BPF loader's Upgrade, run by the vault,
    // does not grow it, so a larger build would fail only when the approved proposal executes.
    const [size, capacity] = [readFileSync(SO).length, await programCapacity()];
    if (size > capacity) {
      const bytes = Math.max(size - capacity, MIN_EXTEND);
      solana(deployer, "program", "extend", CORE_PROGRAM_ID, String(bytes), "--payer", deployer);
      console.log(`program account extended by ${bytes} bytes (${capacity} → ${capacity + bytes}) for a ${size}-byte build`);
    }
    const out = solana(deployer, "program", "write-buffer", SO, "--buffer-authority", deployer, "--use-rpc");
    const buffer = out.match(/Buffer:\s+(\w+)/)?.[1];
    if (!buffer) throw new Error(`no buffer address in: ${out}`);
    solana(deployer, "program", "set-buffer-authority", buffer, "--buffer-authority", deployer, "--new-buffer-authority", vault);
    console.log(`buffer ${buffer} (authority ${vault})`);
    await runIdlPlan(signer, plan);
    await printSquadsImport(vault, [upgradeIx(CORE_PROGRAM_ID, address(buffer), signer.address, vault), ...idlIxs], "upgrade");
    console.log("after the members approve and execute it (time lock), run: program.ts verify");
    break;
  }
  default:
    throw new Error("usage: tsx scripts/program.ts <build|deploy|verify|handoff|upgrade|idl> [--deployer <keypair>] (default: DEPLOYER)");
}
