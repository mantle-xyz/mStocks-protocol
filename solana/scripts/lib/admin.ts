// Admin actions are signed by a Squads multisig on mainnet. Pass `--admin <keypair.json>` to sign
// directly (devnet/local), or `--admin <pubkey>` to print the instruction for a Squads proposal.
import { address, type Address, type Instruction, type KeyPairSigner } from "@solana/kit";
import { loadKeypair, send } from "./env.ts";

export async function resolveAdmin(value: string): Promise<KeyPairSigner | Address> {
  return value.endsWith(".json") ? loadKeypair(value) : address(value);
}

export const adminAddress = (admin: KeyPairSigner | Address): Address =>
  typeof admin === "string" ? admin : admin.address;

/** Sends when the admin is a local keypair; otherwise prints the instruction for Squads. */
export async function sendOrPrint(payer: KeyPairSigner, admin: KeyPairSigner | Address, ix: Instruction, label: string) {
  if (typeof admin !== "string") {
    console.log(`${label}: ${await send(payer, [ix])}`);
    return;
  }
  console.log(`${label}: admin is a multisig, submit this instruction as a Squads proposal:`);
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
