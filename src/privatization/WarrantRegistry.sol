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

/// @notice Registry for warrant issuance and 配资 (leverage) records — see [TD] 私有化退市 +
///         Warrant 发放 + 配资 合约技术设计, Part II.
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
///         配资 (leverage) reuses this contract only as an on-chain record anchor: OPS
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
        address settlementToken; // convertible asset (e.g. USDC); zero = not-yet-convertible / 配资 record-only
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        // ReentrancyGuardTransient (EIP-1153 TSTORE) uses transient storage — no initializer needed.
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
    }

    // ── program lifecycle ─────────────────────────────────────────────────────

    /// @notice Register a program. OPS-only. `settlementToken` may be zero — for a warrant whose
    ///         milestone hasn't resolved yet (set later via {configureProgram}), or for a 配资
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
    ///         OPS-only and fully trusted otherwise: the contract does NOT verify the snapshot /
    ///         root off-chain provenance. OPS is responsible for supplying the correct `merkleRoot`
    ///         and `settleTotal`, and for setting `state` to `Active` when the program is ready to
    ///         claim.
    function configureProgram(uint256 programId, Program calldata program) external onlyRole(OPS_ROLE) {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();

        if (program.token != address(0)) p.token = program.token;
        if (program.merkleRoot != bytes32(0)) p.merkleRoot = program.merkleRoot;
        if (program.settlementToken != address(0)) p.settlementToken = program.settlementToken;
        if (program.settleTotal != 0) p.settleTotal = program.settleTotal;
        if (program.startTime != 0) p.startTime = program.startTime;
        if (program.deadline != 0) p.deadline = program.deadline;
        if (program.state != 0) {
            if (program.state <= p.state || program.state >= uint8(State.Closed)) revert InvalidStateTransition();
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
        if (p.state == uint8(State.Closed)) revert ClaimClosed();
        if (p.settlementToken == address(0)) revert NotConvertibleYet();
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

        if (p.settlementToken == address(0)) revert NotConvertibleYet();
        uint256 out = Math.mulDiv(amount, p.settleTotal, RATE_SCALE);
        if (out == 0) revert NothingToSettle();
        uint256 reserve = settleReserve[programId];
        if (reserve < out) revert InsufficientReserved();

        // effects
        _claimed[programId].set(index);
        warrant[programId][account] += amount; // on-chain queryable record
        settleReserve[programId] = reserve - out;

        // interaction
        IERC20(p.settlementToken).safeTransfer(account, out);
        emit Claimed(programId, index, account, amount, out);
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

    /// @dev Storage gap for upgrade-safe additions. 4 vars (programs, warrant, settleReserve,
    ///      _claimed) + programCount + 45 = 50 slots reserved.
    uint256[45] private __gap;
}
