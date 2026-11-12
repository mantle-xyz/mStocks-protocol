// Final step of TD §6: hands the mint authority to the CCIP BurnMint pool signer PDA.
// Irreversible from the payer's side — CCIP self-registration needs the current mint authority to
// sign, so run it only after the token is registered with CCIP and the pool is configured.
//   tsx scripts/handoff-mint-authority.ts --mint-authority <keypair> --mint <mint> [--pool-program <id>] --yes
import { address, getAddressEncoder, getProgramDerivedAddress, getUtf8Encoder } from "@solana/kit";
import { AuthorityType, getSetAuthorityInstruction } from "@solana-program/token-2022";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

/** CCIP's shared BurnMint token pool program (same program id on mainnet and devnet). */
const DEFAULT_POOL_PROGRAM = "41FGToCmdaWa1dgZLKFAjvmx6e6AjVTX7SVRibvsMGVB";

const args = parseArgs();
const mintAuthority = await loadKeypair(required(args, "mint-authority"));
const mint = address(required(args, "mint"));
const poolProgram = address(args["pool-program"] ?? DEFAULT_POOL_PROGRAM);
const [poolSigner] = await getProgramDerivedAddress({
  programAddress: poolProgram,
  seeds: [getUtf8Encoder().encode("ccip_tokenpool_signer"), getAddressEncoder().encode(mint)],
});

console.log(`pool program: ${poolProgram}\npool signer:  ${poolSigner}`);
if (args.yes !== "true") {
  console.log("dry run: re-run with --yes to transfer the mint authority to the pool signer");
  process.exit(0);
}
const sig = await send(mintAuthority, [
  getSetAuthorityInstruction({ owned: mint, owner: mintAuthority, authorityType: AuthorityType.MintTokens, newAuthority: poolSigner }),
]);
console.log(`handoff: ${sig}`);
