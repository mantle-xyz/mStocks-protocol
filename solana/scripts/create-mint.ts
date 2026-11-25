// Creates one mStocks Token-2022 mint exactly as the TD §6 requires and registers it with Core.
// Registration is signed by a holder of the MintRegistrar role (operations; defaults to the payer).
// Each Mantle token can be registered for only one mint. Everything is one transaction.
//
//   NETWORK=mainnet tsx scripts/create-mint.ts --payer <MintRegistrar keypair> --mantle-token 0x... --uri https://...
//     [--registrar <keypair>] [--mint-keypair <keypair>] [--hook-authority <squads multisig>]
//     [--name "Apple mStock"] [--symbol AAPLm] [--isin US0378331005] [--initial-multiplier-1e18 <n>]
// The hook authority defaults to the config's; name, symbol, ISIN (asset code) and the initial
// multiplier to the Mantle token's (read from the config's Mantle RPC, or MANTLE_RPC_URL).
//
// The payer stays mint authority until the CCIP pool is registered (ccip-register.ts
// --handoff-mint-authority hands it to the pool). If Mantle has a pending multiplier, schedule it on
// this mint right after creation.
import { AccountRole, generateKeyPairSigner, type Instruction } from "@solana/kit";
import { signerAddress } from "./lib/admin.ts";
import { config, setting } from "./lib/config.ts";
import { CORE_PROGRAM_ID } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send, transactionSize } from "./lib/env.ts";
import { scaledToken } from "./lib/mantle.ts";
import { createMintInstructions, evmAddressBytes, mintSizes } from "./lib/mint.ts";

const args = parseArgs(["payer", "registrar", "mint-keypair", "mantle-token", "name", "symbol", "isin", "uri", "hook-authority", "initial-multiplier-1e18", "dry-run"]);
const payer = await loadKeypair(required(args, "payer"));
const registrarKey = args.registrar ? await loadKeypair(args.registrar) : payer;
// The same key loaded twice is two signer objects, which @solana/kit rejects.
const registrar = registrarKey.address === payer.address ? payer : registrarKey;
const hookAuthority = await signerAddress(setting(args["hook-authority"], "admins.hook_authority", "hook-authority"));
const mantleTokenHex = required(args, "mantle-token");
evmAddressBytes(mantleTokenHex); // a malformed address fails here, before anything is read
// Name, symbol, ISIN and the initial multiplier default to the Mantle token's, read on chain, so
// nothing is copied by hand; --name / --symbol / --isin / --initial-multiplier-1e18 override them.
// Read whenever Mantle is reachable (network config or MANTLE_RPC_URL), and in any case when a
// value is missing; local tests pass everything and have no Mantle.
const mantleReachable = Boolean(process.env.MANTLE_RPC_URL || config?.mantle.rpc);
const needsMantle = mantleReachable || !args.name || !args.symbol || !args["initial-multiplier-1e18"];
const fromMantle = needsMantle ? await scaledToken(mantleTokenHex) : null;
if (fromMantle)
  console.log(`Mantle ${mantleTokenHex}: name "${fromMantle.name}", symbol ${fromMantle.symbol}, asset code ${fromMantle.assetCode || "(none)"}, uiMultiplier ${fromMantle.multiplier}`);
const name = args.name ?? fromMantle!.name;
const symbol = args.symbol ?? fromMantle!.symbol;
const uri = required(args, "uri");
const isin = args.isin ?? (fromMantle?.assetCode || undefined);
const multiplier1e18 = BigInt(args["initial-multiplier-1e18"] ?? fromMantle!.multiplier);
if (fromMantle && multiplier1e18 !== fromMantle.multiplier)
  throw new Error(`--initial-multiplier-1e18 ${multiplier1e18} differs from Mantle's uiMultiplier ${fromMantle.multiplier}`);
const mint = args["mint-keypair"] ? await loadKeypair(args["mint-keypair"]) : await generateKeyPairSigner();

// One transaction, so a mint is either fully configured and registered or not created at all; the
// instructions come from lib/mint.ts, the reference for the backend. With realistic metadata it is
// about 1130 bytes when the registrar is the payer (about 1230 when it is a separate signer); send()
// refuses anything over 1232.
const params = {
  coreProgram: CORE_PROGRAM_ID, payer, registrar, mint, hookAuthority,
  mantleToken: mantleTokenHex, name, symbol, uri, isin, multiplier1e18,
};
const lamports = await rpc.getMinimumBalanceForRentExemption((await mintSizes(params)).finalSize).send();
const ixs = await createMintInstructions(params, lamports);
if (args["dry-run"] === "true") {
  // Test vectors for another implementation: every instruction byte for byte; nothing is sent.
  const roles = { [AccountRole.READONLY]: "r", [AccountRole.WRITABLE]: "w", [AccountRole.READONLY_SIGNER]: "rs", [AccountRole.WRITABLE_SIGNER]: "ws" };
  ixs.forEach((ix: Instruction, i) => {
    console.log(`${i + 1}. program ${ix.programAddress}`);
    ix.accounts?.forEach((a) => console.log(`     ${roles[a.role].padEnd(2)} ${a.address}`));
    console.log(`     data ${Buffer.from(ix.data ?? []).toString("hex")}`);
  });
  console.log(`rent ${lamports} lamports; transaction ${await transactionSize(payer, ixs)} bytes; mint ${mint.address} (not sent)`);
  process.exit(0);
}
const signature = await send(payer, ixs);
console.log(`create and register mint ${mint.address} (registrar ${registrar.address}): ${signature}`);
console.log(`mint: ${mint.address}`);
