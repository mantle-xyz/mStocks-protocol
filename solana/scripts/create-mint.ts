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
import { address, generateKeyPairSigner } from "@solana/kit";
import { getCreateAccountInstruction } from "@solana-program/system";
import {
  AccountState,
  extension,
  getInitializeDefaultAccountStateInstruction,
  getInitializeMetadataPointerInstruction,
  getInitializeMint2Instruction,
  getInitializePausableConfigInstruction,
  getInitializePermanentDelegateInstruction,
  getInitializeScaledUiAmountMintInstruction,
  getInitializeTokenMetadataInstruction,
  getInitializeTransferHookInstruction,
  getMintSize,
  getUpdateTokenMetadataFieldInstruction,
  getUpdateTokenMetadataUpdateAuthorityInstruction,
} from "@solana-program/token-2022";
import {
  authorityPda, configPda, coreInstruction, encodeEvmAddress, mantleTokenPda, mintStatePda, rolePda, toF64,
  TOKEN_2022_PROGRAM_ID,
} from "./lib/core.ts";
import { signerAddress } from "./lib/admin.ts";
import { config, setting } from "./lib/config.ts";
import { scaledToken } from "./lib/mantle.ts";
import { loadKeypair, parseArgs, required, rpc, send } from "./lib/env.ts";

const DECIMALS = 9;
const NO_HOOK_PROGRAM = address("11111111111111111111111111111111");

const args = parseArgs();
const payer = await loadKeypair(required(args, "payer"));
const registrarKey = args.registrar ? await loadKeypair(args.registrar) : payer;
// The same key loaded twice is two signer objects, which @solana/kit rejects.
const registrar = registrarKey.address === payer.address ? payer : registrarKey;
const hookAuthority = await signerAddress(setting(args["hook-authority"], "admins.hook_authority", "hook-authority"));
const mantleTokenHex = required(args, "mantle-token");
const mantleToken = encodeEvmAddress(mantleTokenHex);
// Name, symbol, ISIN and the initial multiplier default to the Mantle token's, read on chain, so
// nothing is copied by hand; --name / --symbol / --isin / --initial-multiplier-1e18 override them.
// Read whenever Mantle is reachable (network config or MANTLE_RPC_URL), and in any case when a
// value is missing; local tests pass everything and have no Mantle.
const mantleReachable = Boolean(process.env.MANTLE_RPC_URL || config?.network.mantle_rpc);
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
const initialMultiplier = toF64(multiplier1e18);
const mintSigner = args["mint-keypair"] ? await loadKeypair(args["mint-keypair"]) : await generateKeyPairSigner();
const mint = mintSigner.address;
const authority = await authorityPda();

// Fixed-size extensions decide the account size at creation; token metadata is appended later
// (Token-2022 reallocates), so the rent covers the final size up front.
const fixed = [
  extension("ScaledUiAmountConfig", { authority, multiplier: initialMultiplier, newMultiplierEffectiveTimestamp: 0n, newMultiplier: initialMultiplier }),
  extension("PausableConfig", { authority, paused: false }),
  extension("MetadataPointer", { authority, metadataAddress: mint }),
  extension("DefaultAccountState", { state: AccountState.Initialized }),
  extension("TransferHook", { authority: hookAuthority, programId: NO_HOOK_PROGRAM }),
  extension("PermanentDelegate", { delegate: authority }),
];
const metadata = extension("TokenMetadata", {
  updateAuthority: authority,
  mint,
  name,
  symbol,
  uri,
  additionalMetadata: new Map(isin ? [["isin", isin]] : []),
});
const space = BigInt(getMintSize(fixed));
const lamports = await rpc.getMinimumBalanceForRentExemption(BigInt(getMintSize([...fixed, metadata]))).send();

// One transaction, so a mint is either fully configured and registered or not created at all:
// account, extensions and mint (the payer is the temporary mint authority until the CCIP
// handoff); metadata written by the payer, then handed to Core; register_mint, which validates the
// whole configuration on chain. With realistic metadata it is about 1130 bytes when the registrar
// is the payer (about 1230 when it is a separate signer); send() refuses anything over 1232.
const register = coreInstruction(
  "register_mint",
  {
    payer,
    registrar,
    config: await configPda(),
    role_entry: await rolePda("MintRegistrar", registrar.address),
    mint,
    mint_state: await mintStatePda(mint),
    mantle_index: await mantleTokenPda(mantleToken),
    authority,
  },
  mantleToken,
);
const signature = await send(payer, [
  getCreateAccountInstruction({ payer, newAccount: mintSigner, lamports, space, programAddress: TOKEN_2022_PROGRAM_ID }),
  getInitializeScaledUiAmountMintInstruction({ mint, authority, multiplier: initialMultiplier }),
  getInitializePausableConfigInstruction({ mint, authority }),
  getInitializeMetadataPointerInstruction({ mint, authority, metadataAddress: mint }),
  getInitializeDefaultAccountStateInstruction({ mint, state: AccountState.Initialized }),
  getInitializeTransferHookInstruction({ mint, authority: hookAuthority, programId: NO_HOOK_PROGRAM }),
  getInitializePermanentDelegateInstruction({ mint, delegate: authority }),
  getInitializeMint2Instruction({ mint, decimals: DECIMALS, mintAuthority: payer.address, freezeAuthority: authority }),
  getInitializeTokenMetadataInstruction({ metadata: mint, updateAuthority: payer.address, mint, mintAuthority: payer, name, symbol, uri }),
  ...(isin
    ? [getUpdateTokenMetadataFieldInstruction({ metadata: mint, updateAuthority: payer, field: { __kind: "Key", fields: ["isin"] }, value: isin })]
    : []),
  getUpdateTokenMetadataUpdateAuthorityInstruction({ metadata: mint, updateAuthority: payer, newUpdateAuthority: authority }),
  register,
]);
console.log(`create and register mint ${mint} (registrar ${registrar.address}): ${signature}`);
console.log(`mint: ${mint}`);
