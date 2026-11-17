// Admin actions are signed by a Squads multisig on mainnet. An admin argument is one of:
//   <keypair.json>        signs and sends directly (devnet / local);
//   <multisig address>    a Squads v4 multisig: its vault (index 0) is the signer, and the script
//                         creates the Squads proposal (approved by the proposer) when a member key
//                         is given with --squads-member <keypair.json> or SQUADS_MEMBER; the other
//                         members approve and execute with squads.ts or the Squads app;
//   <any other address>   e.g. the vault itself: prints the instruction for a Squads proposal.
import { address, type Address, type Instruction, type KeyPairSigner } from "@solana/kit";
import { asSquadsMultisig, propose, vaultAddress } from "./squads.ts";
import { loadKeypair, parseArgs, send } from "./env.ts";
import type { PublicKey } from "@solana/web3.js";

export type Admin = KeyPairSigner | Address;

const multisigOfVault = new Map<Address, PublicKey>();

export async function resolveAdmin(value: string): Promise<Admin> {
  return value.endsWith(".json") ? loadKeypair(value) : signerAddress(value);
}

/**
 * The address that signs on chain for `value`: a Squads multisig resolves to its vault, any other
 * address is itself. Use it wherever an address is stored as a signer (admins, role members, hook
 * authority): a multisig account cannot sign, so storing one would brick that authority.
 */
export async function signerAddress(value: string): Promise<Address> {
  const given = address(value);
  const multisig = await asSquadsMultisig(given);
  if (!multisig) return given;
  const vault = vaultAddress(multisig);
  if (!multisigOfVault.has(vault)) console.log(`${given} is a Squads multisig; its vault ${vault} signs`);
  multisigOfVault.set(vault, multisig);
  return vault;
}

export const adminAddress = (admin: Admin): Address => (typeof admin === "string" ? admin : admin.address);

/**
 * Keypair admin: signs and sends (`payer` pays, or the admin when there is no payer). Squads
 * multisig admin: creates the proposal when a member key is given. Otherwise prints the
 * instructions for a Squads proposal.
 */
export async function sendOrPrint(
  payer: KeyPairSigner | null,
  admin: Admin,
  instructions: Instruction | Instruction[],
  label: string,
) {
  const ixs = Array.isArray(instructions) ? instructions : [instructions];
  if (typeof admin !== "string") {
    console.log(`${label}: ${await send(payer ?? admin, ixs)}`);
    return;
  }
  const multisig = multisigOfVault.get(admin);
  const member = parseArgs()["squads-member"] ?? process.env.SQUADS_MEMBER;
  if (multisig && member) {
    const p = await propose(multisig, ixs, member, label);
    console.log(`${label}: Squads proposal #${p.transactionIndex} on ${multisig.toBase58()} (${p.signature})`);
    console.log(
      `  approved by the proposer; needs ${p.threshold} approval(s), then executable ${p.timeLock}s after approval:`,
    );
    console.log(`  tsx scripts/squads.ts approve --multisig ${multisig.toBase58()} --index ${p.transactionIndex} --member <keypair>`);
    console.log(`  tsx scripts/squads.ts execute --multisig ${multisig.toBase58()} --index ${p.transactionIndex} --member <keypair>`);
    return;
  }
  if (multisig) console.log(`(pass --squads-member <member keypair> to create the proposal instead)`);
  for (const ix of ixs) printForSquads(ix, label);
}

/** Prints an instruction to be submitted as a Squads proposal. */
export function printForSquads(ix: Instruction, label: string) {
  console.log(`${label}: signer is a multisig, submit this instruction as a Squads proposal:`);
  console.log(
    JSON.stringify(
      {
        programId: ix.programAddress,
        accounts: ix.accounts!.map((a) => ({ address: a.address, role: a.role })),
        dataBase64: Buffer.from(ix.data!).toString("base64"),
      },
      null,
      2,
    ),
  );
}
