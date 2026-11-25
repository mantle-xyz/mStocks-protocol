// Squads v4 support. Admin actions on mainnet are signed by a Squads multisig's vault (index 0), whose
// members sign with Ledgers in the Squads app. The scripts never sign for a multisig: they print the
// action as a base58 transaction message with the vault as payer and signer, which a member imports
// into the Squads app to create the proposal; the members approve it there and execute it after the
// time lock. squads.ts propose does the same import with a member's key file (tests and rehearsals),
// decoding it exactly as Squads' open-source client does.
import * as multisig from "@sqds/multisig";
import {
  Connection,
  Keypair,
  Message,
  MessageV0,
  PublicKey,
  TransactionInstruction,
  TransactionMessage,
  VersionedMessage,
  VersionedTransaction,
} from "@solana/web3.js";
import { AccountRole, address, getBase58Decoder, getBase58Encoder, type Address, type Instruction } from "@solana/kit";
import { config } from "./config.ts";
import { RPC_URL, secretKeyBytes, withRetry } from "./env.ts";

export const SQUADS_PROGRAM_ID = multisig.PROGRAM_ID;
export const connection = new Connection(RPC_URL, "confirmed");

/** A web3.js keypair from a keypair file or an inline private key (see env.ts secretKeyBytes). */
export async function loadWeb3Keypair(value: string): Promise<Keypair> {
  return Keypair.fromSecretKey(await secretKeyBytes(value));
}

export const vaultOf = (multisigPda: PublicKey, index = 0) => multisig.getVaultPda({ multisigPda, index })[0];

/** The multisig behind `value` if it is a Squads multisig account, else null. */
export async function asSquadsMultisig(value: Address): Promise<PublicKey | null> {
  const key = new PublicKey(value);
  const info = await connection.getAccountInfo(key);
  if (!info || !info.owner.equals(SQUADS_PROGRAM_ID)) return null;
  // The SDK's deserializer does not check the discriminator; other Squads accounts (program config,
  // proposals) must not pass for a multisig.
  const discriminator = Buffer.from(multisig.generated.multisigDiscriminator);
  return info.data.subarray(0, 8).equals(discriminator) ? key : null;
}

/** A multisig's threshold, member count and time lock (seconds). */
export async function multisigInfo(multisigPda: PublicKey) {
  const m = await multisig.accounts.Multisig.fromAccountAddress(connection, multisigPda);
  return { threshold: m.threshold, members: m.members.length, timeLock: m.timeLock };
}

export const toWeb3 = (ix: Instruction) =>
  new TransactionInstruction({
    programId: new PublicKey(ix.programAddress),
    keys: (ix.accounts ?? []).map((a) => ({
      pubkey: new PublicKey(a.address),
      isSigner: a.role === AccountRole.READONLY_SIGNER || a.role === AccountRole.WRITABLE_SIGNER,
      isWritable: a.role === AccountRole.WRITABLE || a.role === AccountRole.WRITABLE_SIGNER,
    })),
    data: Buffer.from(ix.data ?? new Uint8Array()),
  });

/**
 * Sends web3.js instructions signed by `signers[0]` (fee payer) and polls over HTTP until confirmed
 * (web3.js confirmTransaction needs WebSocket subscriptions, which some RPC providers lack).
 */
export async function sendWeb3(instructions: TransactionInstruction[], signers: Keypair[]): Promise<string> {
  const { blockhash, lastValidBlockHeight } = await withRetry(() => connection.getLatestBlockhash());
  const message = new TransactionMessage({ payerKey: signers[0].publicKey, recentBlockhash: blockhash, instructions });
  const tx = new VersionedTransaction(message.compileToV0Message());
  tx.sign(signers);
  const sig = await connection.sendTransaction(tx).catch((e: Error & { logs?: string[] }) => {
    // Name the Anchor error (Squads or Core) instead of a bare custom program error code.
    const named = (e.logs ?? []).map((l) => l.match(/Error Code: (\w+)\. Error Number: \d+\. Error Message: (.*?)\.?$/)).find(Boolean);
    throw named ? new Error(`${named[1]}: ${named[2]}`, { cause: e }) : e;
  });
  for (;;) {
    const { value } = await withRetry(() => connection.getSignatureStatuses([sig]));
    const status = value[0];
    if (status?.err) throw new Error(`transaction ${sig} failed: ${JSON.stringify(status.err)}`);
    if (status?.confirmationStatus === "confirmed" || status?.confirmationStatus === "finalized") return sig;
    if ((await withRetry(() => connection.getBlockHeight())) > lastValidBlockHeight)
      throw new Error(`transaction ${sig} expired before confirmation`);
    await new Promise((r) => setTimeout(r, 1000));
  }
}

/**
 * What the Squads app does when a member imports a transaction: one transaction with
 * vaultTransactionCreate (no memo) and proposalCreate, exactly what squadsImport sizes; the proposer
 * then approves in a second transaction, as in the app.
 */
export async function propose(multisigPda: PublicKey, instructions: TransactionInstruction[], proposerPath: string, memo?: string) {
  const proposer = await loadWeb3Keypair(proposerPath);
  const ms = await multisig.accounts.Multisig.fromAccountAddress(connection, multisigPda);
  const transactionIndex = BigInt(ms.transactionIndex.toString()) + 1n;
  const vault = vaultOf(multisigPda);
  const { blockhash } = await connection.getLatestBlockhash();
  const transactionMessage = new TransactionMessage({ payerKey: vault, recentBlockhash: blockhash, instructions });
  const common = { multisigPda, transactionIndex };
  const sig = await sendWeb3(
    [
      multisig.instructions.vaultTransactionCreate({
        ...common,
        creator: proposer.publicKey,
        rentPayer: proposer.publicKey,
        vaultIndex: 0,
        ephemeralSigners: 0,
        transactionMessage,
        memo,
      }),
      multisig.instructions.proposalCreate({ ...common, creator: proposer.publicKey }),
    ],
    [proposer],
  );
  await sendWeb3([multisig.instructions.proposalApprove({ ...common, member: proposer.publicKey })], [proposer]);
  return { transactionIndex, signature: sig, threshold: ms.threshold, timeLock: ms.timeLock };
}

/**
 * The action in the format of the Squads app's import ("Import base58 encoded tx": a base58 encoded
 * transaction *message*, not a transaction — as in Squads' open-source client, whose sample builds
 * `Message.compile({ instructions, payerKey: vault, recentBlockhash })` and base58-encodes
 * `message.serialize()`). Legacy message, the vault as payer and only signer. `wrapperSize` is the
 * size of the transaction the app then sends (vaultTransactionCreate + proposalCreate), when the
 * multisig is known; it must fit Solana's 1232 bytes.
 */
export async function squadsImport(vault: Address, instructions: Instruction[], multisigPda?: PublicKey, recentBlockhash?: string) {
  const blockhash = recentBlockhash ?? (await withRetry(() => connection.getLatestBlockhash())).blockhash;
  const message = Message.compile({ instructions: instructions.map(toWeb3), payerKey: new PublicKey(vault), recentBlockhash: blockhash });
  const signers = message.accountKeys.slice(0, message.header.numRequiredSignatures).map(String);
  if (signers.some((k) => k !== vault)) throw new Error(`only the vault may sign a Squads transaction; signers: ${signers.join(", ")}`);
  const bytes = serializeOrNull(message);
  if (!bytes) return { base58: undefined, messageSize: Infinity, wrapperSize: Infinity };
  let wrapperSize: number | undefined;
  if (multisigPda) {
    // What the app sends: vaultTransactionCreate + proposalCreate, signed by the creating member.
    const creator = Keypair.generate().publicKey;
    const common = { multisigPda, transactionIndex: 1n };
    const wrapper = new TransactionMessage({
      payerKey: creator,
      recentBlockhash: blockhash,
      instructions: [
        multisig.instructions.vaultTransactionCreate({
          ...common, creator, rentPayer: creator, vaultIndex: 0, ephemeralSigners: 0,
          transactionMessage: decodeImportMessage(bytes),
        }),
        multisig.instructions.proposalCreate({ ...common, creator }),
      ],
    }).compileToV0Message();
    const wrapperBytes = serializeOrNull(wrapper);
    wrapperSize = wrapperBytes ? 1 + 64 + wrapperBytes.length : Infinity;
  }
  return { base58: getBase58Decoder().decode(bytes), messageSize: bytes.length, wrapperSize };
}

/** A message's bytes, or null when it is larger than a transaction (web3.js then throws a RangeError). */
function serializeOrNull(message: { serialize(): Uint8Array }): Uint8Array | null {
  try {
    return message.serialize();
  } catch (e) {
    if (e instanceof RangeError) return null;
    throw e;
  }
}

/** Decodes an import the way Squads' client does: base58 → message (legacy or v0, no lookup tables). */
function decodeImportMessage(bytes: Uint8Array): TransactionMessage {
  if (VersionedMessage.deserializeMessageVersion(bytes) === "legacy") {
    const legacy = Message.from(bytes);
    return TransactionMessage.decompile(VersionedMessage.deserialize(new MessageV0(legacy).serialize()), { addressLookupTableAccounts: [] });
  }
  return TransactionMessage.decompile(VersionedMessage.deserialize(bytes), { addressLookupTableAccounts: [] });
}

/** The fee payer and instructions of a Squads import (a base58 transaction message). */
export function decodeImport(base58: string): { payer: PublicKey; instructions: TransactionInstruction[] } {
  const message = decodeImportMessage(Uint8Array.from(getBase58Encoder().encode(base58)));
  return { payer: message.payerKey, instructions: message.instructions };
}

export const vaultAddress = (multisigPda: PublicKey): Address => address(vaultOf(multisigPda).toBase58());

const BPF_LOADER_UPGRADEABLE = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");

/** BPF Loader Upgradeable `Upgrade` (instruction 3) of `program` from `buffer`, signed by `authority`. */
export function upgradeIx(program: Address, buffer: Address, spill: Address, authority: Address): Instruction {
  const [programData] = PublicKey.findProgramAddressSync([new PublicKey(program).toBuffer()], BPF_LOADER_UPGRADEABLE);
  return {
    programAddress: address(BPF_LOADER_UPGRADEABLE.toBase58()),
    accounts: [
      { address: address(programData.toBase58()), role: AccountRole.WRITABLE },
      { address: program, role: AccountRole.WRITABLE },
      { address: buffer, role: AccountRole.WRITABLE },
      { address: spill, role: AccountRole.WRITABLE },
      { address: address("SysvarRent111111111111111111111111111111111"), role: AccountRole.READONLY },
      { address: address("SysvarC1ock11111111111111111111111111111111"), role: AccountRole.READONLY },
      { address: authority, role: AccountRole.READONLY_SIGNER },
    ],
    data: Uint8Array.from([3, 0, 0, 0]),
  };
}

/** Config names usable instead of a multisig address (--multisig admin, upgrade_authority, ...). */
export function multisigFromConfig(value: string): PublicKey {
  const named: Record<string, string | undefined> = {
    admin: config?.admins.admin,
    compliance_admin: config?.admins.compliance_admin,
    upgrade_authority: config?.admins.upgrade_authority,
    hook_authority: config?.admins.hook_authority,
    unpauser: config?.roles.unpauser?.length === 1 ? config.roles.unpauser[0] : undefined,
    ccip_admin: config?.ccip.solana_ccip_admin || config?.admins.admin,
  };
  if (value in named) {
    const resolved = named[value];
    if (!resolved) throw new Error(`${value} is not set in the network config (set NETWORK, or pass the multisig address)`);
    return new PublicKey(resolved);
  }
  return new PublicKey(value);
}
