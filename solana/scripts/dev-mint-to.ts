// Local/devnet only: mints to a wallet's ATA while the deployer still holds the mint authority
// (i.e. before handoff-mint-authority.ts). On mainnet only the CCIP pool mints.
//   tsx scripts/dev-mint-to.ts --mint-authority <keypair> --mint <mint> --owner <wallet> --amount <raw>
import { address, type Instruction } from "@solana/kit";
import {
  findAssociatedTokenPda,
  getCreateAssociatedTokenIdempotentInstruction,
  getMintToCheckedInstruction,
} from "@solana-program/token-2022";
import { TOKEN_2022_PROGRAM_ID } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, send } from "./lib/env.ts";

const args = parseArgs();
const mintAuthority = await loadKeypair(required(args, "mint-authority"));
const mint = address(required(args, "mint"));
const owner = address(required(args, "owner"));
const amount = BigInt(required(args, "amount"));

const [ata] = await findAssociatedTokenPda({ owner, mint, tokenProgram: TOKEN_2022_PROGRAM_ID });
const ixs: Instruction[] = [getCreateAssociatedTokenIdempotentInstruction({ payer: mintAuthority, ata, owner, mint, tokenProgram: TOKEN_2022_PROGRAM_ID })];
if (amount > 0n) ixs.push(getMintToCheckedInstruction({ mint, token: ata, mintAuthority, amount, decimals: 9 }));
console.log(`mint ${amount} to ${ata}: ${await send(mintAuthority, ixs)}`);
console.log(`ata: ${ata}`);
