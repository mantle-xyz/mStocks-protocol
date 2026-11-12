// Admin-only compliance policy switch for one mint: new token accounts start frozen (--frozen,
// screen before use) or usable (default, today's screen after use).
//   tsx scripts/set-default-account-state.ts --payer <keypair> --admin <keypair.json|squads pubkey> --mint <mint> [--frozen]
import { address } from "@solana/kit";
import { adminAddress, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { authorityPda, configPda, coreInstruction, encodeU8, mintStatePda } from "./lib/core.ts";
import { loadKeypair, parseArgs, required } from "./lib/env.ts";

const args = parseArgs();
const payer = await loadKeypair(required(args, "payer"));
const admin = await resolveAdmin(required(args, "admin"));
const mint = address(required(args, "mint"));
const frozen = args.frozen === "true";

const ix = coreInstruction(
  "set_default_account_state",
  { admin, config: await configPda(), mint, mint_state: await mintStatePda(mint), authority: await authorityPda() },
  encodeU8(frozen ? 1 : 0),
);
await sendOrPrint(payer, admin, ix, `default account state → ${frozen ? "frozen" : "usable"} for ${mint} (admin ${adminAddress(admin)})`);
