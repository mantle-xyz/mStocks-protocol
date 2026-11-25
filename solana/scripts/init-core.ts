// One-time Core initialization. Must be signed by the program's upgrade authority.
// Two admins, split like Mantle's: --admin governs the token roles and the mint registry (Mantle
// multisig 1), --compliance-admin the pause / freeze roles and clawback (Mantle multisig 4).
// A Squads multisig address is stored as its vault, the address that signs; on mainnet each must be a
// Squads multisig (its threshold and time lock are printed), since initialize runs once and an
// address set wrongly loses that authority for good. The addresses default to the network config's admins.
//   NETWORK=mainnet DEPLOYER=<deployer keypair> tsx scripts/init-core.ts [--upgrade-authority <keypair>]
//     [--admin <squads multisig>] [--compliance-admin <squads multisig>] [--hook-authority <squads multisig>]
import { permanentAuthority } from "./lib/admin.ts";
import { setting } from "./lib/config.ts";
import { authorityPda, configPda, coreInstruction, concat, CORE_PROGRAM_ID, encodePubkey, programDataPda } from "./lib/core.ts";
import { deployerKey, loadSigner, parseArgs, send } from "./lib/env.ts";

const args = parseArgs(["upgrade-authority", "admin", "compliance-admin", "hook-authority"]);
// The upgrade authority is the deployer until program.ts handoff: --upgrade-authority, else DEPLOYER
// (a keypair file or a private key).
const upgradeAuthority = await loadSigner(deployerKey(args, "upgrade-authority"));
const admin = await permanentAuthority(setting(args.admin, "admins.admin", "admin"), "admin");
const complianceAdmin = await permanentAuthority(setting(args["compliance-admin"], "admins.compliance_admin", "compliance-admin"), "compliance admin");
const hookAuthority = await permanentAuthority(setting(args["hook-authority"], "admins.hook_authority", "hook-authority"), "hook authority");

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
