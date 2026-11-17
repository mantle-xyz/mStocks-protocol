// One-time Core initialization. Must be signed by the program's upgrade authority.
// Two admins, split like Mantle's: --admin governs the token roles and the mint registry (Mantle
// multisig 1), --compliance-admin the pause / freeze roles and clawback (Mantle multisig 4).
// A Squads multisig address is stored as its vault, the address that signs. The addresses default to
// the network config's admins.
//   NETWORK=mainnet tsx scripts/init-core.ts --upgrade-authority <deployer keypair>
//     [--admin <squads multisig>] [--compliance-admin <squads multisig>] [--hook-authority <squads multisig>]
import { signerAddress } from "./lib/admin.ts";
import { setting } from "./lib/config.ts";
import { authorityPda, configPda, coreInstruction, concat, CORE_PROGRAM_ID, encodePubkey, programDataPda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const upgradeAuthority = await loadKeypair(required(args, "upgrade-authority"));
const admin = await signerAddress(setting(args.admin, "admins.admin", "admin"));
const complianceAdmin = await signerAddress(setting(args["compliance-admin"], "admins.compliance_admin", "compliance-admin"));
const hookAuthority = await signerAddress(setting(args["hook-authority"], "admins.hook_authority", "hook-authority"));

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
