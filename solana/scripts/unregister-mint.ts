// Admin-only: undoes a registration made in error (wrong mint, or the wrong Mantle token) so the
// mint can be registered again correctly. Core only allows it while the mint has zero supply.
//   tsx scripts/unregister-mint.ts [--payer <keypair>] [--admin <keypair.json|squads multisig>] --mint <mint>
import { address, fetchEncodedAccount } from "@solana/kit";
import { getMintDecoder } from "@solana-program/token-2022";
import { adminAddress, optionalPayer, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { ccipAccounts } from "./lib/ccip.ts";
import { setting } from "./lib/config.ts";
import { configPda, coreInstruction, encodeEvmAddress, mantleTokenOf, mantleTokenPda, mintStatePda } from "./lib/core.ts";
import { parseArgs, required, rpc, withRetry } from "./lib/env.ts";

const args = parseArgs();
const admin = await resolveAdmin(setting(args.admin, "admins.admin", "admin"));
const payer = await optionalPayer(args.payer, admin);
const mint = address(required(args, "mint"));

const token = await mantleTokenOf(mint);
if (!token) throw new Error(`mint ${mint} is not registered with Core`);
console.log(`mint ${mint} is registered for Mantle token ${token}`);
// Core only checks that the supply is zero now. Once the CCIP pool holds the mint authority it can
// mint into the mint later, and an unregistered mint is beyond Core's pause, freeze and clawback.
const acc = await withRetry(() => fetchEncodedAccount(rpc, mint));
if (!acc.exists) throw new Error(`mint ${mint} not found`);
const mintAuthority = getMintDecoder().decode(acc.data).mintAuthority;
const { poolSigner } = await ccipAccounts(mint);
if (mintAuthority.__option === "Some" && mintAuthority.value === poolSigner)
  throw new Error(`the CCIP pool (${poolSigner}) holds the mint authority: unregistering would leave a mint the pool can still mint into, outside Core`);

const ix = coreInstruction(
  "unregister_mint",
  { admin, config: await configPda(), mint, mint_state: await mintStatePda(mint), mantle_index: await mantleTokenPda(encodeEvmAddress(token)) },
  new Uint8Array(),
);
await sendOrPrint(payer, admin, ix, `unregister_mint (admin ${adminAddress(admin)})`);
