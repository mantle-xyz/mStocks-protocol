// Admin-only: undoes a registration made in error (wrong mint, or the wrong Mantle token) so the
// mint can be registered again correctly. Core only allows it while the mint has zero supply.
//   tsx scripts/unregister-mint.ts --payer <keypair> --admin <keypair.json|squads pubkey> --mint <mint>
import { address, fetchEncodedAccount } from "@solana/kit";
import { adminAddress, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { configPda, coreInstruction, mantleTokenPda, mintStatePda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, withRetry } from "./lib/env.ts";

const args = parseArgs();
const payer = await loadKeypair(required(args, "payer"));
const admin = await resolveAdmin(required(args, "admin"));
const mint = address(required(args, "mint"));

const mintState = await mintStatePda(mint);
const state = await withRetry(() => fetchEncodedAccount(rpc, mintState));
if (!state.exists) throw new Error(`mint ${mint} is not registered with Core`);
// MintState: 8-byte discriminator, mint (32), mantle_token (20).
const mantleToken = state.data.subarray(40, 60);
console.log(`mint ${mint} is registered for Mantle token 0x${Buffer.from(mantleToken).toString("hex")}`);

const ix = coreInstruction(
  "unregister_mint",
  { admin, config: await configPda(), mint, mint_state: mintState, mantle_index: await mantleTokenPda(mantleToken) },
  new Uint8Array(),
);
await sendOrPrint(payer, admin, ix, `unregister_mint (admin ${adminAddress(admin)})`);
