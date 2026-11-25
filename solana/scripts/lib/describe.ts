// Readable descriptions of the instructions in a multisig action, printed next to its base58 so the
// members can check what they approve on their Ledgers: Core instructions by name with their
// arguments and named accounts (from the IDL), the CCIP handoff instructions, program upgrades, and
// moving a mint authority (Token-2022 SetAuthority).
import { createHash } from "node:crypto";
import { getAddressDecoder, type Instruction } from "@solana/kit";
import { CORE_PROGRAM_ID, TOKEN_2022_PROGRAM_ID, idl } from "./core.ts";

const dec = getAddressDecoder();
const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");
const u64 = (b: Uint8Array, o: number) => new DataView(b.buffer, b.byteOffset + o, 8).getBigUint64(0, true);
const ROLES: string[] = idl.types.find((t: { name: string }) => t.name === "Role").type.variants.map((v: { name: string }) => v.name);
const WELL_KNOWN = new Set(["config", "authority", "system_program", "token_program", "role_entry", "mint_state", "mantle_index"]);

type IdlIx = { name: string; discriminator: number[]; accounts: { name: string }[]; args: { name: string; type: unknown }[] };
const coreByDisc = new Map<string, IdlIx>(idl.instructions.map((i: IdlIx) => [hex(Uint8Array.from(i.discriminator)), i]));

/** Core arguments worth showing: role and member, amounts, flags. */
function coreArgs(name: string, data: Uint8Array): string {
  const a = data.subarray(8);
  switch (name) {
    case "grant_role":
    case "revoke_role":
      return `role ${ROLES[a[0]]}, member ${dec.decode(a.subarray(1, 33))}`;
    case "clawback":
      return `amount ${u64(a, 0)} (raw)`;
    case "set_default_account_state":
      return a[0] === 1 ? "new accounts frozen" : "new accounts usable";
    case "propose_admin":
    case "propose_compliance_admin":
      return `new ${dec.decode(a.subarray(0, 32))}`;
    default:
      return a.length ? `args ${hex(a)}` : "";
  }
}

const CCIP_NAMES = [
  "accept_admin_role_token_admin_registry",
  "accept_ownership",
  "transfer_admin_role_token_admin_registry",
  "transfer_ownership",
  "set_pool",
  "set_chain_rate_limit",
];
const ccipByDisc = new Map(CCIP_NAMES.map((n) => [createHash("sha256").update(`global:${n}`).digest().subarray(0, 8).toString("hex"), n]));

export function describeInstruction(ix: Instruction): string {
  const data = Uint8Array.from(ix.data ?? []);
  const accounts = (ix.accounts ?? []).map((a) => a.address);
  if (ix.programAddress === CORE_PROGRAM_ID) {
    const def = coreByDisc.get(hex(data.subarray(0, 8)));
    if (!def) return `Core, unknown instruction ${hex(data.subarray(0, 8))}`;
    const named = def.accounts
      .map((acc, i) => [acc.name, accounts[i]] as const)
      .filter(([n]) => !WELL_KNOWN.has(n))
      .map(([n, v]) => `${n} ${v}`)
      .join(", ");
    return `Core ${def.name}${coreArgs(def.name, data) ? `: ${coreArgs(def.name, data)}` : ""} [${named}]`;
  }
  if (ix.programAddress === "BPFLoaderUpgradeab1e11111111111111111111111" && data[0] === 3)
    return `BPF loader upgrade: program ${accounts[1]} from buffer ${accounts[2]} (spill ${accounts[3]}), authority ${accounts[6]}`;
  if (ix.programAddress === "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr")
    return `Memo "${Buffer.from(data).toString("utf8")}" (signed by ${accounts.join(", ")}; changes nothing)`;
  if (ix.programAddress === "ProgM6JCCvbYkfKqJYHePx4xxSUSqJp7rh8Lyv7nk7S") {
    const ops: Record<number, string> = { 0: "write", 1: "initialize", 2: "set_authority", 3: "set_data (from buffer)", 5: "trim", 6: "close", 7: "allocate", 8: "extend" };
    // A write without data copies a whole buffer (the third account) into the account.
    const source = data[0] === 3 ? `, buffer ${accounts[2]}` : data[0] === 0 && data.length === 5 ? `, copy of buffer ${accounts[2]}` : "";
    return `IDL (Program Metadata) ${ops[data[0]] ?? `op ${data[0]}`}: account ${accounts[0]}${source}`;
  }
  if (ix.programAddress === TOKEN_2022_PROGRAM_ID && data[0] === 6) {
    // SetAuthority: type, Option<new authority>; accounts: owned, owner, then a multisig's signing members.
    const type = ({ 0: "mint", 1: "freeze" } as Record<number, string>)[data[1]] ?? `type ${data[1]}`;
    const next = data[2] === 1 ? dec.decode(data.subarray(3, 35)) : "none";
    const members = accounts.length > 2 ? `, signed by its member ${accounts.slice(2).join(", ")}` : "";
    return `Token-2022 SetAuthority: ${accounts[0]} ${type} authority → ${next} (current authority ${accounts[1]}${members})`;
  }
  const ccip = ccipByDisc.get(hex(data.subarray(0, 8)));
  if (ccip) return `CCIP ${ccip} on ${ix.programAddress} [${accounts.join(", ")}]`;
  return `${ix.programAddress} data ${hex(data)} [${accounts.join(", ")}]`;
}
