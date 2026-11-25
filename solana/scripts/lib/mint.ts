// Building an mStocks mint: the one transaction that creates a Token-2022 mint exactly as Core requires
// and registers it with Core (TD §6, "Creating a mint by contract call"). This module is the
// reference for the backend that creates mints on mainnet, so it stands alone: it needs only
// @solana/kit and the System / Token-2022 clients (no network config, no IDL file, no RPC), and every
// signer is a kit TransactionSigner, so a KMS-backed signer works as well as a keypair.
// create-mint.ts uses it; `create-mint.ts --dry-run` prints the instructions it builds for given
// inputs, byte for byte, as test vectors for an implementation in another language.
import {
  AccountRole,
  address,
  getAddressEncoder,
  getProgramDerivedAddress,
  getUtf8Encoder,
  type Address,
  type Instruction,
  type TransactionSigner,
} from "@solana/kit";
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

export const DECIMALS = 9;
export const TOKEN_2022 = address("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
const SYSTEM_PROGRAM = address("11111111111111111111111111111111");
/** The dormant transfer hook: no program (the System program id stands for none). */
const NO_HOOK_PROGRAM = SYSTEM_PROGRAM;
/** Anchor discriminator of Core's register_mint (sha256("global:register_mint")[..8]). */
const REGISTER_MINT = Uint8Array.from([242, 43, 74, 162, 217, 214, 191, 171]);
/** Core's Role::MintRegistrar, the role account's seed. */
const MINT_REGISTRAR = 7;

export type NewMint = {
  /** The mstocks-core program id. */
  coreProgram: Address;
  /** Fee payer, temporary mint authority (until the CCIP pool takes it) and first metadata update authority. */
  payer: TransactionSigner;
  /** Holder of the MintRegistrar role; may be the payer (smaller transaction). */
  registrar: TransactionSigner;
  /** The new mint account's key. */
  mint: TransactionSigner;
  /** Core's Config.hook_authority (the hook multisig's vault), the dormant hook's authority. */
  hookAuthority: Address;
  /** The Mantle ScaledToken, 0x + 40 hex digits. */
  mantleToken: string;
  /** Mantle name(), symbol(); the metadata URI. */
  name: string;
  symbol: string;
  uri: string;
  /** Mantle assetCode(), stored as the "isin" metadata field; omitted when the token has none. */
  isin?: string;
  /** Mantle uiMultiplier(), 18 decimals. */
  multiplier1e18: bigint;
};

const enc = getAddressEncoder();
const utf8 = getUtf8Encoder();
type Seeds = Parameters<typeof getProgramDerivedAddress>[0]["seeds"];
const pda = async (programAddress: Address, seeds: Seeds) => (await getProgramDerivedAddress({ programAddress, seeds }))[0];

export function evmAddressBytes(hex: string): Uint8Array {
  const clean = hex.replace(/^0x/, "");
  if (!/^[0-9a-fA-F]{40}$/.test(clean)) throw new Error(`not a 20-byte hex address: ${hex}`);
  return Uint8Array.from(clean.match(/../g)!.map((h) => parseInt(h, 16)));
}

/** Core PDAs the transaction touches. */
export async function corePdas(coreProgram: Address, mint: Address, registrar: Address, mantleToken: Uint8Array) {
  return {
    config: await pda(coreProgram, [utf8.encode("config")]),
    authority: await pda(coreProgram, [utf8.encode("authority")]),
    roleEntry: await pda(coreProgram, [utf8.encode("role"), Uint8Array.of(MINT_REGISTRAR), enc.encode(registrar)]),
    mintState: await pda(coreProgram, [utf8.encode("mint"), enc.encode(mint)]),
    mantleIndex: await pda(coreProgram, [utf8.encode("mantle_token"), mantleToken]),
  };
}

/** The multiplier as Token-2022 stores it (f64). */
export const multiplierF64 = (multiplier1e18: bigint) => Number(multiplier1e18) / 1e18;

/**
 * Why an initial multiplier cannot be used, or null. Core's schedule_multiplier rules, which
 * register_mint does not apply to the initial value: within [1e9, 1e27] (1e18 fixed point) and at
 * most 15 significant digits, so the f64 Token-2022 stores carries exactly Mantle's value.
 */
export function multiplierProblem(multiplier1e18: bigint): string | null {
  if (multiplier1e18 < 10n ** 9n || multiplier1e18 > 10n ** 27n) return `multiplier ${multiplier1e18} is outside [1e9, 1e27]`;
  let digits = multiplier1e18;
  while (digits % 10n === 0n) digits /= 10n;
  if (digits >= 10n ** 15n)
    return `multiplier ${multiplier1e18} has more than 15 significant digits: Token-2022's f64 would round it, and Core refuses to schedule such a value`;
  return null;
}

/**
 * Account sizes: `space` at creation (the six fixed-size extensions) and `finalSize` once the
 * metadata is written (Token-2022 grows the account). CreateAccount must fund the rent for `finalSize`.
 */
export async function mintSizes(p: NewMint) {
  const { authority } = await corePdas(p.coreProgram, p.mint.address, p.registrar.address, evmAddressBytes(p.mantleToken));
  const multiplier = multiplierF64(p.multiplier1e18);
  const fixed = [
    extension("ScaledUiAmountConfig", { authority, multiplier, newMultiplierEffectiveTimestamp: 0n, newMultiplier: multiplier }),
    extension("PausableConfig", { authority, paused: false }),
    extension("MetadataPointer", { authority, metadataAddress: p.mint.address }),
    extension("DefaultAccountState", { state: AccountState.Initialized }),
    extension("TransferHook", { authority: p.hookAuthority, programId: NO_HOOK_PROGRAM }),
    extension("PermanentDelegate", { delegate: authority }),
  ];
  const metadata = extension("TokenMetadata", {
    updateAuthority: authority,
    mint: p.mint.address,
    name: p.name,
    symbol: p.symbol,
    uri: p.uri,
    additionalMetadata: new Map(p.isin ? [["isin", p.isin]] : []),
  });
  return { space: BigInt(getMintSize(fixed)), finalSize: BigInt(getMintSize([...fixed, metadata])) };
}

/**
 * The instructions, in order, of the one transaction (fee payer `p.payer`; signers payer, registrar
 * and mint). `lamports` is the rent for mintSizes(p).finalSize (getMinimumBalanceForRentExemption).
 * Core's register_mint checks the whole configuration and rejects anything else; the initial
 * multiplier, which it does not check, is checked here (multiplierProblem).
 */
export async function createMintInstructions(p: NewMint, lamports: bigint): Promise<Instruction[]> {
  const problem = multiplierProblem(p.multiplier1e18);
  if (problem) throw new Error(problem);
  const mint = p.mint.address;
  const token = evmAddressBytes(p.mantleToken);
  const { config, authority, roleEntry, mintState, mantleIndex } = await corePdas(p.coreProgram, mint, p.registrar.address, token);
  const multiplier = multiplierF64(p.multiplier1e18);
  const { space } = await mintSizes(p);
  const signer = (s: TransactionSigner, writable: boolean) =>
    ({ address: s.address, role: writable ? AccountRole.WRITABLE_SIGNER : AccountRole.READONLY_SIGNER, signer: s });
  const registerMint: Instruction = {
    programAddress: p.coreProgram,
    accounts: [
      signer(p.payer, true),
      // The payer and the registrar may be the same key: then it is one signer.
      p.registrar.address === p.payer.address ? signer(p.payer, false) : signer(p.registrar, false),
      { address: config, role: AccountRole.READONLY },
      { address: roleEntry, role: AccountRole.READONLY },
      { address: mint, role: AccountRole.READONLY },
      { address: mintState, role: AccountRole.WRITABLE },
      { address: mantleIndex, role: AccountRole.WRITABLE },
      { address: authority, role: AccountRole.READONLY },
      { address: SYSTEM_PROGRAM, role: AccountRole.READONLY },
    ],
    data: Uint8Array.from([...REGISTER_MINT, ...token]),
  };
  return [
    getCreateAccountInstruction({ payer: p.payer, newAccount: p.mint, lamports, space, programAddress: TOKEN_2022 }),
    getInitializeScaledUiAmountMintInstruction({ mint, authority, multiplier }),
    getInitializePausableConfigInstruction({ mint, authority }),
    getInitializeMetadataPointerInstruction({ mint, authority, metadataAddress: mint }),
    getInitializeDefaultAccountStateInstruction({ mint, state: AccountState.Initialized }),
    getInitializeTransferHookInstruction({ mint, authority: p.hookAuthority, programId: NO_HOOK_PROGRAM }),
    getInitializePermanentDelegateInstruction({ mint, delegate: authority }),
    getInitializeMint2Instruction({ mint, decimals: DECIMALS, mintAuthority: p.payer.address, freezeAuthority: authority }),
    getInitializeTokenMetadataInstruction({ metadata: mint, updateAuthority: p.payer.address, mint, mintAuthority: p.payer, name: p.name, symbol: p.symbol, uri: p.uri }),
    ...(p.isin
      ? [getUpdateTokenMetadataFieldInstruction({ metadata: mint, updateAuthority: p.payer, field: { __kind: "Key", fields: ["isin"] }, value: p.isin })]
      : []),
    getUpdateTokenMetadataUpdateAuthorityInstruction({ metadata: mint, updateAuthority: p.payer, newUpdateAuthority: authority }),
    registerMint,
  ];
}
