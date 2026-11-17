// Squads v4 multisig operations for the admin multisigs (create, inspect, approve, execute, and
// propose a program upgrade). Proposals for Core / CCIP admin actions are created by the scripts
// themselves when given a multisig address and --squads-member; this script takes them the rest of
// the way. Every key here is a member keypair file (--member, default SQUADS_MEMBER); --multisig is
// the multisig account address (not the vault) or, with NETWORK set, a config name: admin,
// compliance_admin, upgrade_authority, unpauser, ccip_admin.
//   tsx scripts/squads.ts create  --creator <kp> --members <a,b,c> --threshold <n> [--time-lock <s>]
//   tsx scripts/squads.ts status  --multisig <ms> [--index <n>]
//   tsx scripts/squads.ts approve --multisig <ms> --index <n> --member <kp>
//   tsx scripts/squads.ts reject  --multisig <ms> --index <n> --member <kp>
//   tsx scripts/squads.ts execute --multisig <ms> --index <n> --member <kp>
//   tsx scripts/squads.ts upgrade [--multisig <ms>] --member <kp> --buffer <buffer> [--program <id>] [--spill <addr>]
//     (program.ts upgrade writes the buffer and calls this; --multisig defaults to upgrade_authority)
// `create` gives every member all permissions (initiate, vote, execute) and no config authority, so
// membership, threshold and time lock change only through the multisig's own config proposals. For
// `upgrade`, first hand the buffer to the vault: solana program set-buffer-authority <buffer>
// --new-buffer-authority <vault>.
import * as multisig from "@sqds/multisig";
import { Keypair, PublicKey } from "@solana/web3.js";
import { address } from "@solana/kit";
import { CORE_PROGRAM_ID } from "./lib/core.ts";
import { parseArgs, required } from "./lib/env.ts";
import { connection, loadWeb3Keypair, multisigFromConfig, propose, sendWeb3, upgradeIx, vaultOf } from "./lib/squads.ts";

const [command, ...rest] = process.argv.slice(2);
const args = parseArgs(rest);
const { Multisig, Proposal, ProgramConfig } = multisig.accounts;

const msArg = () => multisigFromConfig(required(args, "multisig"));
/** --member, else SQUADS_MEMBER. */
const member = () => args.member ?? process.env.SQUADS_MEMBER ?? required(args, "member");
const indexArg = () => BigInt(required(args, "index"));
const proposalPda = (multisigPda: PublicKey, transactionIndex: bigint) =>
  multisig.getProposalPda({ multisigPda, transactionIndex })[0];

async function proposalState(multisigPda: PublicKey, transactionIndex: bigint) {
  const ms = await Multisig.fromAccountAddress(connection, multisigPda);
  const info = await connection.getAccountInfo(proposalPda(multisigPda, transactionIndex));
  if (!info) return { ms, proposal: null };
  const [proposal] = Proposal.fromAccountInfo(info);
  return { ms, proposal };
}

function describe(ms: multisig.accounts.Multisig, proposal: multisig.accounts.Proposal | null, index: bigint) {
  if (!proposal) return `#${index}: no proposal`;
  const status = proposal.status;
  let line = `#${index}: ${status.__kind}, ${proposal.approved.length}/${ms.threshold} approvals (${proposal.approved.map(String).join(", ")})`;
  if (proposal.rejected.length) line += `, ${proposal.rejected.length} rejections`;
  if (status.__kind === "Approved") {
    const at = Number(status.timestamp) + ms.timeLock;
    const left = at - Math.floor(Date.now() / 1000);
    line += left > 0 ? `; executable in ${left}s (${new Date(at * 1000).toISOString()})` : "; executable now";
  }
  return line;
}

async function main() {
  switch (command) {
    case "create": {
      const creator = loadWeb3Keypair(required(args, "creator"));
      const members = required(args, "members").split(",").map((m) => new PublicKey(m.trim()));
      const threshold = Number(required(args, "threshold"));
      const timeLock = Number(args["time-lock"] ?? 0);
      if (threshold < 1 || threshold > members.length) throw new Error(`threshold ${threshold} of ${members.length} members`);
      const createKey = Keypair.generate();
      const [multisigPda] = multisig.getMultisigPda({ createKey: createKey.publicKey });
      const programConfig = await ProgramConfig.fromAccountAddress(connection, multisig.getProgramConfigPda({})[0]);
      console.log(`creating multisig ${multisigPda.toBase58()} ...`);
      const sig = await sendWeb3(
        [
          multisig.instructions.multisigCreateV2({
            treasury: programConfig.treasury,
            creator: creator.publicKey,
            multisigPda,
            configAuthority: null,
            threshold,
            members: members.map((key) => ({ key, permissions: multisig.types.Permissions.all() })),
            timeLock,
            createKey: createKey.publicKey,
            rentCollector: null,
          }),
        ],
        [creator, createKey],
      );
      console.log(`multisig ${multisigPda.toBase58()} (${threshold}/${members.length}, time lock ${timeLock}s): ${sig}`);
      console.log(`vault    ${vaultOf(multisigPda).toBase58()}  (the address that signs; fund it with SOL for rent)`);
      break;
    }
    case "status": {
      const multisigPda = msArg();
      const ms = await Multisig.fromAccountAddress(connection, multisigPda);
      console.log(`multisig ${multisigPda.toBase58()}, vault ${vaultOf(multisigPda).toBase58()}`);
      console.log(`  threshold ${ms.threshold}/${ms.members.length}, time lock ${ms.timeLock}s, config authority ${ms.configAuthority}`);
      console.log(`  members ${ms.members.map((m) => m.key.toBase58()).join(", ")}`);
      console.log(`  transactions ${ms.transactionIndex}, stale up to ${ms.staleTransactionIndex}`);
      const indexes = args.index
        ? [indexArg()]
        : Array.from({ length: Math.min(5, Number(ms.transactionIndex)) }, (_, i) => BigInt(ms.transactionIndex.toString()) - BigInt(i));
      for (const i of indexes) {
        const { proposal } = await proposalState(multisigPda, i);
        console.log(`  ${describe(ms, proposal, i)}`);
      }
      break;
    }
    case "approve":
    case "reject": {
      const multisigPda = msArg();
      const transactionIndex = indexArg();
      const signer = loadWeb3Keypair(member());
      const build = command === "approve" ? multisig.instructions.proposalApprove : multisig.instructions.proposalReject;
      const sig = await sendWeb3([build({ multisigPda, transactionIndex, member: signer.publicKey })], [signer]);
      const { ms, proposal } = await proposalState(multisigPda, transactionIndex);
      console.log(`${command} by ${signer.publicKey.toBase58()}: ${sig}`);
      console.log(`  ${describe(ms, proposal, transactionIndex)}`);
      break;
    }
    case "execute": {
      const multisigPda = msArg();
      const transactionIndex = indexArg();
      const signer = loadWeb3Keypair(member());
      const { ms, proposal } = await proposalState(multisigPda, transactionIndex);
      console.log(`  ${describe(ms, proposal, transactionIndex)}`);
      const { instruction } = await multisig.instructions.vaultTransactionExecute({
        connection,
        multisigPda,
        transactionIndex,
        member: signer.publicKey,
      });
      console.log(`execute #${transactionIndex}: ${await sendWeb3([instruction], [signer])}`);
      break;
    }
    case "upgrade": {
      // BPF Loader Upgradeable `Upgrade`, signed by the vault as upgrade authority.
      const multisigPda = multisigFromConfig(args.multisig ?? "upgrade_authority");
      const vault = address(vaultOf(multisigPda).toBase58());
      const program = address(args.program ?? CORE_PROGRAM_ID);
      const ix = upgradeIx(program, address(required(args, "buffer")), address(args.spill ?? vault), vault);
      const p = await propose(multisigPda, [ix], member(), `upgrade ${program}`);
      console.log(`upgrade ${program}: Squads proposal #${p.transactionIndex} on ${multisigPda.toBase58()} (${p.signature})`);
      console.log(`  needs ${p.threshold} approval(s), then executable ${p.timeLock}s after approval`);
      break;
    }
    default:
      throw new Error("usage: tsx scripts/squads.ts <create|status|approve|reject|execute|upgrade> ...");
  }
}

// Operators see the named Squads / Core error, not a stack trace.
main().catch((e: Error) => {
  console.error(`error: ${e.message}`);
  process.exit(1);
});
