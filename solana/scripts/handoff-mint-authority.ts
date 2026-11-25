// Final step of TD §6: hands the mint authority to the 1-of-2 Token-2022 multisig of the CCIP
// BurnMint pool signer and the admin's vault (lib/ccip.ts), which ccip-register.ts created and
// listed in the pool's lookup table. The pool mints through it as with its signer; the admin's
// vault can later move the authority to another pool without Chainlink.
// Irreversible from the payer's side, and CCIP self-registration needs the current mint authority
// to sign, so run it only after ccip-register.ts (normally its --handoff-mint-authority does this).
//   tsx scripts/handoff-mint-authority.ts --mint-authority <keypair> --mint <mint> [--pool-program <id>]
//     [--mint-authority-admin <keypair.json|squads multisig>] --yes
import { address } from "@solana/kit";
import { AuthorityType, getSetAuthorityInstruction } from "@solana-program/token-2022";
import { adminAddress, resolveAdmin } from "./lib/admin.ts";
import {
  SYSTEM_PROGRAM,
  ccipAccounts,
  lookupTableAddresses,
  mintAuthorityMultisig,
  mintAuthorityMultisigProblem,
  registryState,
} from "./lib/ccip.ts";
import { setting } from "./lib/config.ts";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const mintAuthority = await loadKeypair(required(args, "mint-authority"));
const mint = address(required(args, "mint"));
const admin = adminAddress(await resolveAdmin(setting(args["mint-authority-admin"], "admins.admin", "mint-authority-admin")));
// CCIP's shared BurnMint token pool program (the same id on mainnet and devnet) unless --pool-program.
const a = await ccipAccounts(mint, { poolProgram: args["pool-program"] });
const multisig = await mintAuthorityMultisig(mintAuthority.address, mint);

console.log(`pool program: ${a.poolProgram}\npool signer:  ${a.poolSigner}\nmultisig:     ${multisig} (1 of: pool signer, admin ${admin})`);
// The pool finds the multisig only in the token's (frozen) lookup table, and the multisig must
// let the pool signer mint alone and the admin move the authority.
const registry = await registryState(a);
if (!registry || registry.lookupTable === SYSTEM_PROGRAM)
  throw new Error(`mint ${mint} has no CCIP lookup table yet: run ccip-register.ts first`);
if (!(await lookupTableAddresses(registry.lookupTable)).includes(multisig))
  throw new Error(`lookup table ${registry.lookupTable} does not list the multisig ${multisig}; the pool could not mint through it`);
const problem = await mintAuthorityMultisigProblem(multisig, a.poolSigner, admin);
if (problem) throw new Error(problem);

if (args.yes !== "true") {
  console.log("dry run: re-run with --yes to transfer the mint authority to the multisig");
  process.exit(0);
}
const sig = await send(mintAuthority, [
  getSetAuthorityInstruction({ owned: mint, owner: mintAuthority, authorityType: AuthorityType.MintTokens, newAuthority: multisig }),
]);
console.log(`handoff: ${sig}`);
