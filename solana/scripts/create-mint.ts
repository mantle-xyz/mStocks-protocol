// Creates one mStocks Token-2022 mint exactly as the TD §6 requires and registers it with Core.
//
//   tsx scripts/create-mint.ts --payer <keypair> --admin <keypair.json|squads pubkey> \
//     --hook-authority <squads pubkey> --name "Apple mStock" --symbol AAPLm --uri https://... \
//     --isin US0378331005 --mantle-token 0x... --initial-multiplier-1e18 <Mantle uiMultiplier()>
//
// The payer stays mint authority until the CCIP pool is registered (run handoff-mint-authority.ts
// afterwards). If Mantle has a pending multiplier, schedule it on this mint right after creation.
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
import { adminAddress, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import {
  authorityPda, configPda, coreInstruction, encodeEvmAddress, mintStatePda, toF64, TOKEN_2022_PROGRAM_ID,
} from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send } from "./lib/env.ts";

const DECIMALS = 9;
const NO_HOOK_PROGRAM = address("11111111111111111111111111111111");

const args = parseArgs();
const payer = await loadKeypair(required(args, "payer"));
const admin = await resolveAdmin(required(args, "admin"));
const hookAuthority = address(required(args, "hook-authority"));
const name = required(args, "name");
const symbol = required(args, "symbol");
const uri = required(args, "uri");
const isin = args.isin;
const mantleToken = encodeEvmAddress(required(args, "mantle-token"));
const initialMultiplier = toF64(BigInt(required(args, "initial-multiplier-1e18")));
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

// 1. Account, extensions and mint. The payer is the temporary mint authority (until CCIP handoff).
const create = await send(payer, [
  getCreateAccountInstruction({ payer, newAccount: mintSigner, lamports, space, programAddress: TOKEN_2022_PROGRAM_ID }),
  getInitializeScaledUiAmountMintInstruction({ mint, authority, multiplier: initialMultiplier }),
  getInitializePausableConfigInstruction({ mint, authority }),
  getInitializeMetadataPointerInstruction({ mint, authority, metadataAddress: mint }),
  getInitializeDefaultAccountStateInstruction({ mint, state: AccountState.Initialized }),
  getInitializeTransferHookInstruction({ mint, authority: hookAuthority, programId: NO_HOOK_PROGRAM }),
  getInitializePermanentDelegateInstruction({ mint, delegate: authority }),
  getInitializeMint2Instruction({ mint, decimals: DECIMALS, mintAuthority: payer.address, freezeAuthority: authority }),
]);
console.log(`create mint ${mint}: ${create}`);

// 2. Metadata, written by the payer, then handed to Core.
const meta = await send(payer, [
  getInitializeTokenMetadataInstruction({ metadata: mint, updateAuthority: payer.address, mint, mintAuthority: payer, name, symbol, uri }),
  ...(isin
    ? [getUpdateTokenMetadataFieldInstruction({ metadata: mint, updateAuthority: payer, field: { __kind: "Key", fields: ["isin"] }, value: isin })]
    : []),
  getUpdateTokenMetadataUpdateAuthorityInstruction({ metadata: mint, updateAuthority: payer, newUpdateAuthority: authority }),
]);
console.log(`metadata: ${meta}`);

// 3. Register with Core (validates the whole configuration on-chain).
const register = coreInstruction(
  "register_mint",
  // In a Squads proposal only the vault signs, so the vault (admin) also pays rent.
  { payer: typeof admin === "string" ? admin : payer, admin, config: await configPda(), mint, mint_state: await mintStatePda(mint), authority },
  mantleToken,
);
await sendOrPrint(payer, admin, register, `register_mint (admin ${adminAddress(admin)})`);
console.log(`mint: ${mint}`);
