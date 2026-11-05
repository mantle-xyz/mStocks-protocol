// Schedules a multiplier change on one mint (plan B: send the same values to Mantle's setUIMultiplier).
//   tsx scripts/schedule-multiplier.ts --scheduler <keypair> --mint <mint> --multiplier-1e18 2000000000000000000 --effective-at <unix>
import { address } from "@solana/kit";
import {
  authorityPda, configPda, coreInstruction, concat, encodeI64, encodeU128, mintStatePda, rolePda,
} from "./lib/core.ts";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const scheduler = await loadKeypair(required(args, "scheduler"));
const mint = address(required(args, "mint"));
const multiplier = BigInt(required(args, "multiplier-1e18"));
const effectiveAt = BigInt(required(args, "effective-at"));

const ix = coreInstruction(
  "schedule_multiplier",
  {
    operator: scheduler,
    config: await configPda(),
    role_entry: await rolePda("MultiplierScheduler", scheduler.address),
    mint,
    mint_state: await mintStatePda(mint),
    authority: await authorityPda(),
  },
  concat(encodeU128(multiplier), encodeI64(effectiveAt)),
);
console.log(`schedule_multiplier: ${await send(scheduler, [ix])}`);
