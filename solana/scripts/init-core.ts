// One-time Core initialization. Must be signed by the program's upgrade authority.
//   tsx scripts/init-core.ts --upgrade-authority ~/.config/solana/id.json --admin <squads> --hook-authority <squads>
import { address } from "@solana/kit";
import { authorityPda, configPda, coreInstruction, concat, CORE_PROGRAM_ID, encodePubkey, programDataPda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const upgradeAuthority = await loadKeypair(required(args, "upgrade-authority"));
const admin = address(required(args, "admin"));
const hookAuthority = address(required(args, "hook-authority"));

const ix = coreInstruction(
  "initialize",
  {
    payer: upgradeAuthority,
    config: await configPda(),
    authority: await authorityPda(),
    program: CORE_PROGRAM_ID,
    program_data: await programDataPda(),
  },
  concat(encodePubkey(admin), encodePubkey(hookAuthority)),
);
console.log(`initialize: ${await send(upgradeAuthority, [ix])}`);
console.log(`config:    ${await configPda()}`);
console.log(`authority: ${await authorityPda()}  (holds every mint authority except minting)`);
