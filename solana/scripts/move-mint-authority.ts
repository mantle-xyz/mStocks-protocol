// Escape hatch of the mint authority multisig (lib/ccip.ts): the admin's vault, the multisig's second
// member, moves the mint authority from the 1-of-2 multisig of the CCIP pool signer and the admin to
// a new authority, without Chainlink. For a pool that was set up wrong, or one Chainlink retires:
// initializing a pool for the mint needs the mint authority's signature, so move it to the admin's
// vault first, set up the new pool from the vault (pool, its mint authority multisig, lookup table,
// set_pool as the token admin), then move it to the new multisig. Whoever holds the mint authority
// can mint outside CCIP, so the target is printed for the members to check.
//   tsx scripts/move-mint-authority.ts --mint <mint> --to <new mint authority>
//     [--admin <keypair.json|squads multisig>] [--payer <keypair>]
// The admin defaults to the config's admin; a keypair signs and sends, a multisig gets a Squads proposal.
import { AccountRole, address, fetchEncodedAccount, type Address } from "@solana/kit";
import { AuthorityType, getMintDecoder, getMultisigDecoder, getMultisigSize, getSetAuthorityInstruction } from "@solana-program/token-2022";
import { adminAddress, optionalPayer, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { setting } from "./lib/config.ts";
import { TOKEN_2022_PROGRAM_ID } from "./lib/core.ts";
import { parseArgs, required, rpc, withRetry } from "./lib/env.ts";

const args = parseArgs();
const admin = await resolveAdmin(setting(args.admin, "admins.admin", "admin"));
const payer = await optionalPayer(args.payer, admin);
const vault = adminAddress(admin);
const mint = address(required(args, "mint"));
const to = address(required(args, "to"));

const fetch = (a: Address) => withRetry(() => fetchEncodedAccount(rpc, a));
/** A Token-2022 multisig's threshold and members, or null for any other account. */
async function multisigOf(a: Address) {
  const acc = await fetch(a);
  if (!acc.exists || acc.programAddress !== TOKEN_2022_PROGRAM_ID || acc.data.length !== getMultisigSize()) return null;
  const m = getMultisigDecoder().decode(acc.data);
  return m.isInitialized ? { m: m.m, members: m.signers.slice(0, m.n) } : null;
}

const mintAccount = await fetch(mint);
if (!mintAccount.exists) throw new Error(`mint ${mint} not found`);
const current = getMintDecoder().decode(mintAccount.data).mintAuthority;
if (current.__option === "None") throw new Error(`mint ${mint} has no mint authority`);
const holder = current.value;
const multisig = await multisigOf(holder);
if (!multisig) throw new Error(`the mint authority ${holder} is not a Token-2022 multisig`);
if (multisig.m !== 1 || !multisig.members.includes(vault))
  throw new Error(`multisig ${holder} is ${multisig.m}-of-${multisig.members.length} of ${multisig.members.join(", ")}: the admin ${vault} cannot move the authority alone`);
if (to === holder) throw new Error(`${to} already holds the mint authority`);

const target = await multisigOf(to);
console.log(`mint ${mint}: mint authority ${holder} (1 of: ${multisig.members.join(", ")})`);
console.log(
  `new mint authority ${to}: ${
    target
      ? `a Token-2022 multisig, ${target.m} of: ${target.members.join(", ")}`
      : "not a Token-2022 multisig: whoever controls it can mint outside CCIP"
  }`,
);

// SetAuthority by a multisig: the multisig is the (non-signing) owner, its signing member follows.
const ix = getSetAuthorityInstruction({ owned: mint, owner: holder, authorityType: AuthorityType.MintTokens, newAuthority: to });
const member = typeof admin === "string"
  ? { address: admin, role: AccountRole.READONLY_SIGNER }
  : { address: admin.address, role: AccountRole.READONLY_SIGNER, signer: admin };
await sendOrPrint(payer, admin, { ...ix, accounts: [...ix.accounts, member] }, `move the mint authority to ${to} (admin ${vault})`);
