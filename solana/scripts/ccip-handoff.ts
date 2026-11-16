// Hands a mint's CCIP administration to the multisig (Squads vault on mainnet): the router's token
// admin for this mint, which can repoint the mint at another pool, and the BurnMint pool's owner,
// which configures remote chains and rate limits. Both are two-step:
//   1. the current holder (the key that ran ccip-register.ts) proposes the new holder — sent here;
//   2. the new holder accepts — signed and sent here when --to is a keypair file (devnet / local),
//      printed as instructions for a Squads proposal when --to is the vault address (mainnet).
// Steps already done on chain are skipped, so it can be re-run (e.g. after the proposal executed).
//   tsx scripts/ccip-handoff.ts --authority <current holder keypair> --mint <mint> --to <keypair.json|squads vault>
//     [--router <id>] [--pool-program <id>]
import { createHash } from "node:crypto";
import {
  address,
  fetchEncodedAccount,
  getAddressDecoder,
  getAddressEncoder,
  getProgramDerivedAddress,
  getUtf8Encoder,
  type Address,
  type Instruction,
  type KeyPairSigner,
} from "@solana/kit";
import { AccountRole } from "@solana/kit";
import { adminAddress, resolveAdmin, sendOrPrint } from "./lib/admin.ts";
import { concat } from "./lib/core.ts";
import { loadKeypair, parseArgs, required, rpc, send, withRetry } from "./lib/env.ts";

const args = parseArgs();
const authority = await loadKeypair(required(args, "authority"));
const mint = address(required(args, "mint"));
const target = await resolveAdmin(required(args, "to"));
const targetAddress = adminAddress(target);
const router = address(args.router ?? "Ccip842gzYHhvdDkSyi2YVCoAWPbYJoApMFzSxQroE9C");
const poolProgram = address(args["pool-program"] ?? "41FGToCmdaWa1dgZLKFAjvmx6e6AjVTX7SVRibvsMGVB");

const enc = getAddressEncoder();
const dec = getAddressDecoder();
const utf8 = getUtf8Encoder();
const mintBytes = new Uint8Array(enc.encode(mint));
const pda = async (program: Address, seeds: Parameters<typeof getProgramDerivedAddress>[0]["seeds"]) =>
  (await getProgramDerivedAddress({ programAddress: program, seeds })).at(0) as Address;
const routerConfig = await pda(router, [utf8.encode("config"), new Uint8Array()].slice(0, 1));
const tokenAdminRegistry = await pda(router, [utf8.encode("token_admin_registry"), mintBytes]);
const poolState = await pda(poolProgram, [utf8.encode("ccip_tokenpool_config"), mintBytes]);

const disc = (name: string) => createHash("sha256").update(`global:${name}`).digest().subarray(0, 8);
type Meta = [Address, "r" | "w" | "s" | "sw"];
function ix(program: Address, name: string, metas: Meta[], data: Uint8Array, signer?: KeyPairSigner): Instruction {
  const roles = {
    r: AccountRole.READONLY,
    w: AccountRole.WRITABLE,
    s: AccountRole.READONLY_SIGNER,
    sw: AccountRole.WRITABLE_SIGNER,
  };
  return {
    programAddress: program,
    accounts: metas.map(([a, r]) =>
      r.startsWith("s") && signer && a === signer.address
        ? { address: a, role: roles[r], signer }
        : { address: a, role: roles[r] },
    ),
    data: concat(disc(name), data),
  };
}
async function read(a: Address): Promise<Uint8Array> {
  const acc = await withRetry(() => fetchEncodedAccount(rpc, a));
  if (!acc.exists) throw new Error(`account ${a} not found; was the mint registered with ccip-register.ts?`);
  return acc.data;
}
// TokenAdminRegistry: 8 discriminator, version (1), administrator (32), pending_administrator (32), ...
const registryState = async () => {
  const d = await read(tokenAdminRegistry);
  return { admin: dec.decode(d.subarray(9, 41)), pending: dec.decode(d.subarray(41, 73)) };
};
// Pool State: 8 discriminator, version (1), BaseConfig { token_program, mint, decimals (1), pool_signer,
// pool_token_account, owner, proposed_owner, ... }
const poolOwnership = async () => {
  const d = await read(poolState);
  return { owner: dec.decode(d.subarray(138, 170)), proposed: dec.decode(d.subarray(170, 202)) };
};

console.log(`mint ${mint}: hand CCIP token admin and pool ownership to ${targetAddress}`);
let reg = await registryState();
let pool = await poolOwnership();
console.log(
  `  now: token admin ${reg.admin} (pending ${reg.pending}); pool owner ${pool.owner} (proposed ${pool.proposed})`,
);

// 1. Proposals by the current holder.
const proposals: Instruction[] = [];
if (reg.admin !== targetAddress && reg.pending !== targetAddress) {
  if (reg.admin !== authority.address)
    throw new Error(`token admin is ${reg.admin}, not --authority ${authority.address}`);
  proposals.push(
    ix(
      router,
      "transfer_admin_role_token_admin_registry",
      [
        [routerConfig, "r"],
        [tokenAdminRegistry, "w"],
        [mint, "r"],
        [authority.address, "sw"],
      ],
      new Uint8Array(enc.encode(targetAddress)),
      authority,
    ),
  );
}
if (pool.owner !== targetAddress && pool.proposed !== targetAddress) {
  if (pool.owner !== authority.address)
    throw new Error(`pool owner is ${pool.owner}, not --authority ${authority.address}`);
  proposals.push(
    ix(
      poolProgram,
      "transfer_ownership",
      [
        [poolState, "w"],
        [mint, "r"],
        [authority.address, "s"],
      ],
      new Uint8Array(enc.encode(targetAddress)),
      authority,
    ),
  );
}
if (proposals.length) console.log(`propose (${proposals.length}): ${await send(authority, proposals)}`);
else console.log("propose: nothing to do");

// 2. Acceptance by the new holder.
reg = await registryState();
pool = await poolOwnership();
const accepts: Instruction[] = [];
const signer = typeof target === "string" ? undefined : target;
if (reg.admin !== targetAddress)
  accepts.push(
    ix(
      router,
      "accept_admin_role_token_admin_registry",
      [
        [routerConfig, "r"],
        [tokenAdminRegistry, "w"],
        [mint, "r"],
        [targetAddress, "sw"],
      ],
      new Uint8Array(),
      signer,
    ),
  );
if (pool.owner !== targetAddress)
  accepts.push(
    ix(
      poolProgram,
      "accept_ownership",
      [
        [poolState, "w"],
        [mint, "r"],
        [targetAddress, "s"],
      ],
      new Uint8Array(),
      signer,
    ),
  );
for (const a of accepts)
  await sendOrPrint(authority, target, a, `accept (${a.programAddress === router ? "token admin" : "pool owner"})`);
if (!accepts.length) console.log("accept: nothing to do");

reg = await registryState();
pool = await poolOwnership();
console.log(
  `  now: token admin ${reg.admin} (pending ${reg.pending}); pool owner ${pool.owner} (proposed ${pool.proposed})`,
);
if (signer && (reg.admin !== targetAddress || pool.owner !== targetAddress)) throw new Error("handoff incomplete");
