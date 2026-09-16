// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IComplianceRegistry} from "../complianceRegistry/IComplianceRegistry.sol";

/// @notice The compliance registry a token enforces, as exposed by
///         {ComplianceGuardUpgradeable}'s public `compliance` variable.
///
/// @dev Declared here rather than alongside {IComplianceRegistry} because it is the
///      *token's* ABI, not the registry's: the registry answers `checkIsCompliant`, the
///      token says which registry to ask. This contract is the only thing that needs to
///      ask, so a one-method interface local to it beats a shared file.
interface IComplianceGuardedToken {
    function compliance() external view returns (IComplianceRegistry);
}

/// @notice Registry for warrant issuance and leverage records — see [TD] Privatisation delisting +
///         warrant issuance + leverage records, Part II.
///
///         Warrants are a rights-offering-style entitlement whose per-account amount is fixed at a
///         **record-date snapshot** and published as a Merkle root. There is no on-chain option
///         exercise and no separate "register" step — the root already encodes every eligible
///         holder and amount, and it is immutable, so a single {claim} does it all: verify the
///         proof, record the account's amount on-chain (`warrant[programId][account]`, queryable),
///         and settle it in the settlement asset (e.g. USDC).
///
///         Each leaf's `amount` is the account's **normalized share** of the program
///         (`holding_i / Σholding`, scaled by {RATE_SCALE}, so all leaves sum to `RATE_SCALE`).
///         `settleTotal` is the total settlement asset backing the whole program, so a claim pays
///         `amount * settleTotal / RATE_SCALE`.
///
///         If settlement is not ready yet (`settlementToken` unset or under-funded), {claim}
///         reverts so the holder simply retries once the operator has funded and configured it via
///         {configureProgram} — the proof stays valid and the Merkle index is not consumed.
///
///         Leverage records reuse this contract only as an on-chain record anchor: OPS
///         `createProgram`s + `configureProgram`s the credit-line snapshot root and nobody claims
///         — the actual leverage is used / settled elsewhere. Such a program simply keeps
///         `settlementToken` zero and is never funded or claimed.
///
///         Lifecycle (state machine): `Created` (createProgram: token + optional settlementToken)
///         → `Active` (configureProgram: root + settleTotal + window + state=Active) → funded →
///         claimed within [startTime, deadline] → `Closed` (sweepUnclaimed after deadline).
///
///         The whole program lifecycle (create / configure / fund / sweep) is OPS-driven — admin
///         only manages roles (grants/revokes OPS_ROLE), matching {PrivatizationRegistry}.
///
///         Upgradeable: deployed behind a TransparentUpgradeableProxy (like {TokenIssuer}); upgrade
///         authority lives on the auto-created ProxyAdmin, separate from DEFAULT_ADMIN_ROLE.
///
///         Merkle leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount)))),
///         matching OZ's `StandardMerkleTree` with encoding `["uint256","address","uint256"]`.
contract WarrantRegistry is Initializable, AccessControlEnumerableUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    uint256 public constant RATE_SCALE = 1e18;

    enum State {
        None, // 0 — program id never created
        Created, // 1 — token/settlementToken set; not yet configured (no root / window)
        Active, // 2 — root + settleTotal + window set; claimable
        Closed // 3 — swept after deadline
    }

    struct Program {
        address token; // original mStocks address (informational — which stock this program covers)
        bytes32 merkleRoot; // record-date snapshot: leaf(index, account, amount)
        address settlementToken; // convertible asset (e.g. USDC); zero = not-yet-convertible / leverage record-only
        uint256 settleTotal; // total settlement asset backing this program's warrant amounts
        uint64 startTime; // claims accepted from this timestamp (inclusive)
        uint64 deadline; // claims accepted up to and including this timestamp
        uint8 state; // State
    }

    mapping(uint256 => Program) public programs;
    /// @notice programId => account => cumulative warrant amount claimed (on-chain queryable).
    mapping(uint256 => mapping(address => uint256)) public warrant;
    /// @notice programId => settlement asset still reserved to back settlements.
    mapping(uint256 => uint256) public settleReserve;

    mapping(uint256 => BitMaps.BitMap) private _claimed; // programId => merkle index bitmap
    uint256 public programCount;
    /// @notice programId => whether at least one {claim} has succeeded. Informational:
    ///         {configureProgram} is gated on the program still being Created, not on
    ///         this, so it freezes nothing. Appended after `programCount` rather than grouped with the
    ///         other mappings: this contract is already deployed behind a proxy, and inserting a
    ///         slot would shift every variable after it.
    mapping(uint256 => bool) public claimStarted;

    event ProgramCreated(uint256 indexed programId, address indexed token, address settlementToken);
    event ProgramConfigured(
        uint256 indexed programId,
        bytes32 merkleRoot,
        address settlementToken,
        uint256 settleTotal,
        uint64 startTime,
        uint64 deadline,
        uint8 state
    );
    event Funded(uint256 indexed programId, address indexed from, uint256 amount);
    event Claimed(uint256 indexed programId, uint256 index, address indexed account, uint256 amount, uint256 assetOut);
    event Swept(uint256 indexed programId, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownProgram();
    error InvalidStateTransition();
    error SettlementTermsLocked();
    error ConfigureLockedOnceActive();
    error NotActive();
    error ClaimNotStarted();
    error ClaimClosed();
    error ClaimStillOpen();
    error AlreadyClaimed();
    error InvalidProof();
    error NotConvertibleYet();
    error NothingToSettle();
    error InsufficientReserved();
    error SelfGrantNotAllowed();
    error CannotRenounceLastAdmin();
    /// @notice The program's token does not expose a compliance registry, so whether an
    ///         account may be paid cannot be established.
    ///
    ///         Strands the program once it is Active — {configureProgram} is closed by
    ///         then, so `token` cannot be repointed and no claim will ever succeed. The
    ///         reserve is still recoverable through {sweepUnclaimed} after the deadline.
    ///         Catch it while the program is Created, which is what that state is for.
    error ComplianceUnavailable(address token);
    /// @notice {fund} before {configureProgram} set `settleTotal`. Funding locks the
    ///         settlement terms, so this order would leave `settleTotal` at zero
    ///         permanently and every claim reverting {NothingToSettle}.
    error SettleTotalNotSet();
    /// @notice A program cannot become Active until its reserve covers `settleTotal`.
    error NotFullyFunded(uint256 reserve, uint256 settleTotal);
    /// @notice {fund} after the program opened. Funding is part of getting a program ready,
    ///         not a way to patch one that is already claimable.
    error FundLockedOnceActive();
    /// @notice A supplied deadline must be in the future and strictly after startTime;
    ///         a supplied startTime must precede any stored deadline.
    error InvalidWindow();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param ops Initial OPS_ROLE holders (may be empty — grant later via {grantRole}), matching
    ///        the pattern {ScaledToken.initialize} already uses for its own opsRoles_.
    function initialize(address admin, address[] calldata ops) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        // ReentrancyGuardTransient (EIP-1153 TSTORE) uses transient storage — no initializer needed.
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
        for (uint256 i = 0; i < ops.length; ++i) {
            if (ops[i] == address(0)) revert ZeroAddress();
            _grantRole(OPS_ROLE, ops[i]);
        }
    }

    // ── program lifecycle ─────────────────────────────────────────────────────

    /// @notice Register a program. OPS-only. `settlementToken` may be zero — for a warrant whose
    ///         milestone hasn't resolved yet (set later via {configureProgram}), or for a leverage
    ///         record whose root is anchored on-chain but never settled here. The program starts in
    ///         `Created` — it becomes claimable only after {configureProgram}.
    function createProgram(address token, address settlementToken)
        external
        onlyRole(OPS_ROLE)
        returns (uint256 programId)
    {
        if (token == address(0)) revert ZeroAddress();
        programId = programCount++;
        programs[programId] = Program({
            token: token,
            merkleRoot: bytes32(0),
            settlementToken: settlementToken,
            settleTotal: 0,
            startTime: 0,
            deadline: 0,
            state: uint8(State.Created)
        });
        emit ProgramCreated(programId, token, settlementToken);
    }

    /// @notice Patch a program's fields. For every field of the {Program} struct a **zero value
    ///         means "keep the stored value"** and a non-zero value overwrites it. So OPS can set
    ///         or later adjust any subset — open the window by supplying `{merkleRoot,
    ///         settlementToken, settleTotal, startTime, deadline, state: Active}`, or extend the
    ///         deadline alone by supplying only `deadline` (everything else 0).
    ///
    ///         `state` is the one field that is NOT a free overwrite: a non-zero value must move
    ///         the state machine strictly forward (`Created` → `Active`) and can never reach
    ///         `Closed` here — that transition is {sweepUnclaimed}'s exclusively, atomically paired
    ///         with sweeping the remaining reserve. Without this, OPS could regress `Active` back to
    ///         `Created` (spuriously blocking claims) or jump straight to `Closed` (stranding the
    ///         reserve — {sweepUnclaimed} only runs from `Active`) or reopen an already-`Closed`
    ///         (already swept) program.
    ///
    ///         `settlementToken` / `settleTotal` are likewise frozen once {fund} has put any
    ///         balance behind this program (`settleReserve[programId] != 0`). `settleReserve` is
    ///         only ever accounted in whatever token was `settlementToken` at fund time — changing
    ///         either afterward would desync that reserve from the token actually held (the old
    ///         token's balance becomes stranded, and the new token's `claim`/`sweepUnclaimed` would
    ///         move an amount that was never funded in it, potentially out of another program's
    ///         balance of that same token). Before any funding, both remain freely adjustable.
    ///
    ///         Once any {claim} has succeeded the whole patch is refused
    ///         (`ConfigureLockedAfterClaim`), matching {PrivatizationRegistry}. Before this, the
    ///         `merkleRoot` had no lock at all: OPS could swap the entire holder set after the
    ///         program was funded and after holders had begun claiming, redirecting committed funds
    ///         to addresses absent from the original root while `state` stayed `Active` and nothing
    ///         on chain marked that it had happened.
    ///
    ///         The consequence to weigh: the deadline can no longer be extended once the first
    ///         holder claims. Extending it before that is still fine, and a program whose window
    ///         needs to move after claiming has started can only be handled by a new program.
    ///
    ///         OPS-only and fully trusted otherwise: the contract does NOT verify the snapshot /
    ///         root off-chain provenance. OPS is responsible for supplying the correct `merkleRoot`
    ///         and `settleTotal`, and for setting `state` to `Active` when the program is ready to
    ///         claim.
    function configureProgram(uint256 programId, Program calldata program) external onlyRole(OPS_ROLE) {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();
        // Created is the only configurable state. Active means the root is published and
        // the reserve committed, so every field it exposes is something a holder already
        // relies on; Closed means the program is history.
        //
        // This subsumes the previous "locked once a claim landed" rule — claiming requires
        // Active — and covers what that rule could not: a program nobody ever claims. Leverage
        // records are exactly that, and their root is their whole output, so under the old
        // rule it stayed editable indefinitely.
        if (p.state != uint8(State.Created)) revert ConfigureLockedOnceActive();

        if (program.token != address(0)) p.token = program.token;
        if (program.merkleRoot != bytes32(0)) p.merkleRoot = program.merkleRoot;
        if (program.settlementToken != address(0) || program.settleTotal != 0) {
            if (settleReserve[programId] != 0) revert SettlementTermsLocked();
            if (program.settlementToken != address(0)) p.settlementToken = program.settlementToken;
            if (program.settleTotal != 0) p.settleTotal = program.settleTotal;
        }
        if (program.startTime != 0) {
            if (p.deadline != 0 && program.startTime >= p.deadline) revert InvalidWindow();
            p.startTime = program.startTime;
        }
        if (program.deadline != 0) {
            if (program.deadline <= block.timestamp) revert InvalidWindow();
            if (p.startTime != 0 && program.deadline <= p.startTime) revert InvalidWindow();
            p.deadline = program.deadline;
        }
        if (program.state != 0) {
            if (program.state <= p.state || program.state >= uint8(State.Closed)) revert InvalidStateTransition();
            // Active means claimable, so it has to mean funded. A holder whose claim
            // reverts InsufficientReserved cannot tell an under-funded program from a
            // broken one, and the operator only finds out from the complaint.
            //
            // settleTotal == 0 is the leverage record-only case: it never settles and never
            // funds, so it is exempt rather than blocked.
            //
            // The bound is settleTotal, which is exact when the tree's amounts sum to
            // RATE_SCALE as they are meant to. A tree summing higher needs proportionally
            // more, and this cannot know the sum — so it narrows the failure to that one
            // misconfiguration instead of eliminating InsufficientReserved outright.
            if (program.state == uint8(State.Active) && p.settleTotal != 0 && settleReserve[programId] < p.settleTotal)
            {
                revert NotFullyFunded(settleReserve[programId], p.settleTotal);
            }
            p.state = program.state;
        }

        emit ProgramConfigured(
            programId, p.merkleRoot, p.settlementToken, p.settleTotal, p.startTime, p.deadline, p.state
        );
    }

    /// @notice Fund + reserve settlement asset for a program. OPS-only; caller must `approve` the
    ///         registry for `amount` of the program's `settlementToken` first. Allowed while the
    ///         program exists and is not closed.
    function fund(uint256 programId, uint256 amount) external onlyRole(OPS_ROLE) nonReentrant {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();
        // Funding belongs to the Created state. Active is the second look — "the reserve
        // covers what this program owes, open it" — and that assertion is worthless if the
        // reserve can still move afterwards. Closed is covered by the same condition.
        //
        // The consequence is that a tree whose amounts sum above RATE_SCALE has to be caught
        // before opening: afterwards its later claimants cannot be paid and the reserve only
        // returns through sweepUnclaimed. Nothing on chain can catch it — the sum is not
        // visible here — so the check is the operator reconciling settleReserve against the
        // sum of previewClaim over the leaves, while the program is still Created.
        if (p.state != uint8(State.Created)) revert FundLockedOnceActive();
        if (p.settlementToken == address(0)) revert NotConvertibleYet();
        // createProgram already sets settlementToken, so without this a caller could fund
        // straight after creating — and funding locks the settlement terms, so settleTotal
        // would be stuck at zero and every claim would revert NothingToSettle. The program
        // would look configured, hold the money, and pay nobody.
        if (p.settleTotal == 0) revert SettleTotalNotSet();
        if (amount == 0) revert ZeroAmount();
        settleReserve[programId] += amount;
        IERC20(p.settlementToken).safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(programId, msg.sender, amount);
    }

    // ── views ─────────────────────────────────────────────────────────────────

    function isClaimed(uint256 programId, uint256 index) external view returns (bool) {
        return _claimed[programId].get(index);
    }

    /// @notice Settlement asset paid for a leaf carrying `amount` (0 if not yet convertible).
    function previewClaim(uint256 programId, uint256 amount) external view returns (uint256) {
        uint256 total = programs[programId].settleTotal;
        return total == 0 ? 0 : Math.mulDiv(amount, total, RATE_SCALE);
    }

    // ── claim / sweep ───────────────────────────────────────────────────────────

    /// @notice Verify `account`'s snapshot allocation and settle it in the settlement asset, in one
    ///         call. Anyone may submit a valid proof on an account's behalf; the record / payout
    ///         always accrues to `account`. Reverts (leaving the index unconsumed) if the program
    ///         isn't Active / in its window, or is not yet convertible or under-funded — retry once
    ///         ready.
    function claim(uint256 programId, uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();
        if (p.state != uint8(State.Active)) revert NotActive();
        if (block.timestamp < p.startTime) revert ClaimNotStarted();
        if (block.timestamp > p.deadline) revert ClaimClosed();
        if (_claimed[programId].get(index)) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        if (!MerkleProof.verify(proof, p.merkleRoot, leaf)) revert InvalidProof();

        // Checked after the proof so an unauthenticated caller cannot use this entry point
        // to probe the registry, and before any effect so a blocked account leaves its
        // index unconsumed and can claim once unblocked.
        _requireCompliant(p.token, account);

        if (p.settlementToken == address(0)) revert NotConvertibleYet();
        uint256 out = Math.mulDiv(amount, p.settleTotal, RATE_SCALE);
        if (out == 0) revert NothingToSettle();
        uint256 reserve = settleReserve[programId];
        if (reserve < out) revert InsufficientReserved();

        // effects
        _claimed[programId].set(index);
        warrant[programId][account] += amount; // on-chain queryable record
        settleReserve[programId] = reserve - out;
        // Informational only now: configureProgram locks at Active, and claiming requires
        // Active, so this can no longer be the thing that freezes anything. Kept because it
        // answers "was this program ever claimed against" in one call, and because removing
        // it would move __gap and complicate the upgrade for no gain.
        claimStarted[programId] = true;

        // interaction
        IERC20(p.settlementToken).safeTransfer(account, out);
        emit Claimed(programId, index, account, amount, out);
    }

    /// @notice Reverts unless `account` passes the compliance check the program's token
    ///         enforces on its own transfers.
    ///
    ///         The registry is read from `token` rather than configured here on purpose. A
    ///         warrant is an entitlement derived from holding that security, so it has to
    ///         honour the same blocklist the security does; a second configured address
    ///         would be a second thing to get wrong, and getting it wrong means paying an
    ///         account the token itself refuses.
    ///
    ///         `account`, not `_msgSender()`: {claim} accepts a proof on any account's
    ///         behalf and pays `account`, so checking the caller would let a clean relayer
    ///         collect on behalf of a blocked one.
    ///
    /// @dev Fails closed. If `token` does not expose a registry the answer is unknown, and
    ///      settling a security's entitlement to an account whose standing cannot be
    ///      established is the case this check exists to prevent. Only the `compliance()`
    ///      lookup is caught — a registry that reverts with `UserBlocked` or
    ///      `UserSanctioned` propagates, so the reason reaches the caller.
    function _requireCompliant(address token, address account) private view {
        IComplianceRegistry registry;
        try IComplianceGuardedToken(token).compliance() returns (IComplianceRegistry c) {
            registry = c;
        } catch {
            revert ComplianceUnavailable(token);
        }
        if (address(registry) == address(0)) revert ComplianceUnavailable(token);
        registry.checkIsCompliant(token, account);
    }

    /// @notice After the deadline, sweep the program's remaining (unclaimed) settlement reserve to
    ///         a custody address and close it. OPS-only. Deadline-gated so committed funds cannot
    ///         be pulled out from under holders who can still claim.
    function sweepUnclaimed(uint256 programId, address to) external onlyRole(OPS_ROLE) nonReentrant {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();
        if (p.state != uint8(State.Active)) revert NotActive();
        if (block.timestamp <= p.deadline) revert ClaimStillOpen();
        if (to == address(0)) revert ZeroAddress();

        p.state = uint8(State.Closed);
        uint256 reserve = settleReserve[programId];
        if (reserve != 0) {
            settleReserve[programId] = 0;
            IERC20(p.settlementToken).safeTransfer(to, reserve);
        }
        emit Swept(programId, to, reserve);
    }

    // ── role guards (repo convention) ───────────────────────────────────────────

    /// @notice Disallows self-grant — admin must delegate OPS_ROLE to a separate account.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

    /// @notice Blocks renouncing the final DEFAULT_ADMIN_ROLE holder.
    function renounceRole(bytes32 role, address callerConfirmation)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (role == DEFAULT_ADMIN_ROLE && getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1) {
            revert CannotRenounceLastAdmin();
        }
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Blocks revoking the final DEFAULT_ADMIN_ROLE holder — {renounceRole} is guarded
    ///         against this, but `revokeRole` is a second path to the exact same self-removal (an
    ///         admin can revoke its own role via `revokeRole` just as well as `renounceRole`), so it
    ///         needs the identical guard.
    function revokeRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (role == DEFAULT_ADMIN_ROLE && getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1) {
            revert CannotRenounceLastAdmin();
        }
        super.revokeRole(role, account);
    }

    /// @dev Storage gap for upgrade-safe additions. 5 vars (programs, warrant, settleReserve,
    ///      _claimed, claimStarted) + programCount + 44 = 50 slots reserved.
    uint256[44] private __gap;
}
