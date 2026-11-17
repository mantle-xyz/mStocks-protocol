// One-time Core initialization. Must be signed by the program's upgrade authority.
// Two admins, split like Mantle's: --admin governs the token roles and the mint registry (Mantle
// multisig 1), --compliance-admin the pause / freeze roles and clawback (Mantle multisig 4).
// A Squads multisig address is stored as its vault, the address that signs.
//   tsx scripts/init-core.ts --upgrade-authority ~/.config/solana/id.json --admin <squads multisig> \
//     --compliance-admin <squads multisig> --hook-authority <squads multisig>
import { signerAddress } from "./lib/admin.ts";
import { authorityPda, configPda, coreInstruction, concat, CORE_PROGRAM_ID, encodePubkey, programDataPda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const upgradeAuthority = await loadKeypair(required(args, "upgrade-authority"));
const admin = await signerAddress(required(args, "admin"));
const complianceAdmin = await signerAddress(required(args, "compliance-admin"));
const hookAuthority = await signerAddress(required(args, "hook-authority"));

const ix = coreInstruction(
  "initialize",
  {
    payer: upgradeAuthority,
    config: await configPda(),
    authority: await authorityPda(),
    program: CORE_PROGRAM_ID,
    program_data: await programDataPda(),
  },
  concat(encodePubkey(admin), encodePubkey(complianceAdmin), encodePubkey(hookAuthority)),
);
console.log(`initialize: ${await send(upgradeAuthority, [ix])}`);
console.log(`config:    ${await configPda()}`);
console.log(`authority: ${await authorityPda()}  (holds every mint authority except minting)`);
