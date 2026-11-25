// Emergency global pause: finds every mint registered with Core and pauses them, 8 per
// transaction (each pair of accounts costs 64 bytes; 8 keeps the transaction well under 1232).
// A mint in --mints that is not registered (any longer) is skipped, because Core fails the whole
// batch on one; a failed batch does not stop the others, and the exit code is 1 if any failed.
//   tsx scripts/pause-all.ts --operator <Pauser keypair> [--dry-run] [--mints a,b,c]
// Without --mints the registered mints are discovered with getProgramAccounts, which some RPC
// providers (e.g. Alchemy's free tier) reject; keep the mint list at hand for that case.
import { address, getAddressDecoder, getBase58Decoder, type Address, type Base58EncodedBytes } from "@solana/kit";
import { CORE_PROGRAM_ID, accountDiscriminator, coreInstruction, configPda, authorityPda, mantleTokenOf, rolePda, mintStatePda, withRemaining } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send } from "./lib/env.ts";

const BATCH = 8;

const args = parseArgs(["operator", "mints", "dry-run"]);
const operator = await loadKeypair(required(args, "operator"));

async function registeredMints(): Promise<Address[]> {
  // MintState layout: 8-byte discriminator, then the mint pubkey.
  const accounts = await rpc
    .getProgramAccounts(CORE_PROGRAM_ID, {
      encoding: "base64",
      filters: [{ memcmp: { offset: 0n, bytes: getBase58Decoder().decode(accountDiscriminator("MintState")) as Base58EncodedBytes, encoding: "base58" } }],
    })
    .send()
    .catch((e) => {
      throw new Error(`getProgramAccounts failed (${(e as Error).message}); pass --mints a,b,c instead`);
    });
  const decodeAddress = getAddressDecoder();
  return accounts.map((a) => decodeAddress.decode(Buffer.from(a.account.data[0], "base64").subarray(8, 40)));
}

let mints: Address[] = args.mints ? args.mints.split(",").map((m) => address(m.trim())) : await registeredMints();
if (args.mints) {
  const registered: Address[] = [];
  for (const m of mints) {
    if (await mantleTokenOf(m)) registered.push(m);
    else console.log(`  skipped ${m}: not registered with Core`);
  }
  mints = registered;
}
console.log(`${mints.length} mint(s) registered with Core`);
if (args["dry-run"] === "true" || mints.length === 0) {
  mints.forEach((m) => console.log(`  ${m}`));
  process.exit(0);
}

const base = coreInstruction(
  "pause_all",
  { operator, config: await configPda(), role_entry: await rolePda("Pauser", operator.address), authority: await authorityPda() },
  new Uint8Array(),
);
let failed = 0;
for (let i = 0; i < mints.length; i += BATCH) {
  const batch = mints.slice(i, i + BATCH);
  const pairs: Address[] = [];
  for (const m of batch) pairs.push(m, await mintStatePda(m));
  // mint must be writable (Pausable flips a flag on it); mint_state is read-only but harmless as writable.
  try {
    console.log(`pause ${batch.length}: ${await send(operator, [withRemaining(base, pairs)])}`);
  } catch (e) {
    failed += batch.length;
    console.log(`FAILED to pause ${batch.join(", ")}: ${(e as Error).message}`);
  }
}
if (failed) {
  console.log(`${failed} mint(s) NOT paused; retry them with --mints`);
  process.exit(1);
}
