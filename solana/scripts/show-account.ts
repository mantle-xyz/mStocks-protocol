// Prints a Token-2022 token account's balance and state.
//   tsx scripts/show-account.ts --account <token account>
import { address, fetchEncodedAccount } from "@solana/kit";
import { AccountState, getTokenDecoder } from "@solana-program/token-2022";
import { parseArgs, required, rpc } from "./lib/env.ts";

const account = address(required(parseArgs(), "account"));
const data = await fetchEncodedAccount(rpc, account);
if (!data.exists) throw new Error(`account ${account} not found`);
const token = getTokenDecoder().decode(data.data);
console.log(`account ${account}  owner ${token.owner}  amount ${token.amount}  state ${AccountState[token.state]}`);
