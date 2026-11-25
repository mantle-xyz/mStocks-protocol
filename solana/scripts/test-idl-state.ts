// Test support for local-squads-e2e.sh, not an operations script: puts the Core IDL account in a
// state the IDL tooling must recover from. `unfinished` closes the IDL and leaves an upload that
// stopped before initialize (allocated, partly written). Needs the deployer as upgrade authority.
//   NETWORK=<config> DEPLOYER=<key> tsx scripts/test-idl-state.ts unfinished
import { readFileSync } from "node:fs";
import { CORE_PROGRAM_ID, programDataPda } from "./lib/core.ts";
import { deployerKey, loadSigner, parseArgs, send } from "./lib/env.ts";
import { closeIdlInstruction, idlState, unfinishedIdlUpload } from "./lib/idl.ts";

const [command, ...rest] = process.argv.slice(2);
if (command !== "unfinished") throw new Error("usage: tsx scripts/test-idl-state.ts unfinished [--deployer <key>]");
const deployer = await loadSigner(deployerKey(parseArgs(["deployer"], rest), "deployer"));
const programData = await programDataPda();
if ((await idlState(CORE_PROGRAM_ID)).kind !== "none") await send(deployer, [await closeIdlInstruction(CORE_PROGRAM_ID, programData, deployer)]);
const json = readFileSync(new URL("../idl/mstocks_core.json", import.meta.url), "utf8");
await send(deployer, await unfinishedIdlUpload(CORE_PROGRAM_ID, programData, deployer, json));
console.log(`IDL account: ${(await idlState(CORE_PROGRAM_ID)).kind}`);
