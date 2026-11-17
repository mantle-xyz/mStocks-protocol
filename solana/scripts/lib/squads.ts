// Squads v4 support. Admin actions on mainnet are signed by a Squads multisig's vault (index 0).
// When a script is given the multisig account itself, it uses the vault as the signer and, instead
// of printing the instruction, creates the vault transaction, its proposal and the proposer's
// approval in one transaction; the other members approve and execute with squads.ts (or the Squads
// app), after the multisig's time lock.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import * as multisig from "@sqds/multisig";
import {
  Connection,
  Keypair,
  PublicKey,
  TransactionInstruction,
  TransactionMessage,
  VersionedTransaction,
} from "@solana/web3.js";
import { AccountRole, address, type Address, type Instruction } from "@solana/kit";
import { RPC_URL, withRetry } from "./env.ts";

export const SQUADS_PROGRAM_ID = multisig.PROGRAM_ID;
export const connection = new Connection(RPC_URL, "confirmed");

export function loadWeb3Keypair(path: string): Keypair {
  return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path.replace(/^~/, homedir()), "utf8"))));
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

const toWeb3 = (ix: Instruction) =>
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

/** Creates a vault transaction with `instructions` (signed by the vault), its proposal and the proposer's approval. */
export async function propose(multisigPda: PublicKey, instructions: Instruction[], proposerPath: string, memo: string) {
  const proposer = loadWeb3Keypair(proposerPath);
  const ms = await multisig.accounts.Multisig.fromAccountAddress(connection, multisigPda);
  const transactionIndex = BigInt(ms.transactionIndex.toString()) + 1n;
  const vault = vaultOf(multisigPda);
  const { blockhash } = await connection.getLatestBlockhash();
  const transactionMessage = new TransactionMessage({ payerKey: vault, recentBlockhash: blockhash, instructions: instructions.map(toWeb3) });
  const common = { multisigPda, transactionIndex };
  const sig = await sendWeb3(
    [
      multisig.instructions.vaultTransactionCreate({
        ...common,
        creator: proposer.publicKey,
        vaultIndex: 0,
        ephemeralSigners: 0,
        transactionMessage,
        memo,
      }),
      multisig.instructions.proposalCreate({ ...common, creator: proposer.publicKey }),
      multisig.instructions.proposalApprove({ ...common, member: proposer.publicKey }),
    ],
    [proposer],
  );
  return { transactionIndex, signature: sig, threshold: ms.threshold, timeLock: ms.timeLock };
}

export const vaultAddress = (multisigPda: PublicKey): Address => address(vaultOf(multisigPda).toBase58());
