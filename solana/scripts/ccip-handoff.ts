// Hands a mint's CCIP administration to the multisig (Squads vault on mainnet): the router's token
// admin for this mint, which can repoint the mint at another pool, and the BurnMint pool's owner,
// which configures remote chains and rate limits. Both are two-step:
//   1. the current holder (the key that ran ccip-register.ts) proposes the new holder — sent here;
//   2. the new holder accepts — signed and sent here when --to is a keypair file (devnet / local);
//      when --to is a Squads multisig (mainnet), its vault becomes the holder and both accepts are
//      one Squads action, printed as a base58 transaction for the Squads app.
// Steps already done on chain are skipped, so it can be re-run (e.g. after the proposal executed).
// ccip-register.ts --handoff-to does the same as part of the registration.
//   tsx scripts/ccip-handoff.ts --authority <current holder keypair> --mint <mint> [--to <keypair.json|squads multisig>]
//     [--router <id>] [--pool-program <id>]
// --to defaults to the network config's CCIP admin.
import { address } from "@solana/kit";
import { adminAddress, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { ccipAccounts, handoffAccepts, handoffProposals, poolOwnership, registryState } from "./lib/ccip.ts";
import { ccipAdmin } from "./lib/config.ts";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const authority = await loadKeypair(required(args, "authority"));
const mint = address(required(args, "mint"));
const target = await resolveAdmin(args.to && args.to !== "true" ? args.to : ccipAdmin());
const targetAddress = adminAddress(target);
const a = await ccipAccounts(mint, { router: args.router, poolProgram: args["pool-program"] });

async function state() {
  const [reg, pool] = await Promise.all([registryState(a), poolOwnership(a)]);
  if (!reg || !pool) throw new Error(`mint ${mint} has no CCIP registration or pool; run ccip-register.ts first`);
  console.log(`  now: token admin ${reg.admin} (pending ${reg.pending}); pool owner ${pool.owner} (proposed ${pool.proposed})`);
  return { reg, pool };
}

console.log(`mint ${mint}: hand CCIP token admin and pool ownership to ${targetAddress}`);
let { reg, pool } = await state();

// 1. Proposals by the current holder.
const proposals = handoffProposals(a, authority, targetAddress, reg, pool);
if (proposals.length) console.log(`propose (${proposals.length}): ${await send(authority, proposals)}`);
else console.log("propose: nothing to do");

// 2. Acceptance by the new holder.
({ reg, pool } = await state());
const accepts = handoffAccepts(a, target, reg, pool);
const accepting = accepts.map((i) => (i.programAddress === a.router ? "token admin" : "pool owner")).join(" + ");
if (accepts.length) await sendOrPrint(authority, target, accepts, `accept (${accepting})`);
else console.log("accept: nothing to do");

({ reg, pool } = await state());
if (typeof target !== "string" && (reg.admin !== targetAddress || pool.owner !== targetAddress))
  throw new Error("handoff incomplete");
