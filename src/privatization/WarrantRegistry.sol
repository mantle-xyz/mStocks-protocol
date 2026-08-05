// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Registry for warrant issuance and 配资 (leverage) records — see
///         docs/corporate-actions-td.md §7.
///
///         Warrants are a *rights-offering-style* entitlement whose per-account amount is fixed
///         at a **record-date snapshot** and published as a Merkle root. There is **no on-chain
///         option exercise** and **no separate "register" step** — the root already encodes every
///         eligible holder and amount, and it is immutable, so a single {claim} does it all:
///         verify the proof, record the account's amount on-chain (`warrant[programId][account]`,
///         queryable), and settle it in the settlement asset (e.g. USDC "U").
///
///         If settlement is not ready yet (`settlementToken` unset or under-funded), {claim}
///         reverts so the holder simply retries once the operator has `configureSettlement` +
///         {fund} — the proof stays valid and the Merkle index is not consumed. So there is no
///         need to "record now, settle later".
///
///         **配资 (leverage)** reuses this contract only as an on-chain **record anchor**: the
///         operator `createProgram`s the credit-line snapshot root and nobody claims — the actual
///         leverage is used / settled elsewhere. Such a program simply keeps `settlementToken`
///         zero, is never funded and never claimed.
///
///         Upgradeable: deployed behind a TransparentUpgradeableProxy (like {TokenIssuer}).
///
///         One contract manages many programs, keyed by `programId`. Merkle leaf =
///         keccak256(bytes.concat(keccak256(abi.encode(index, account, amount)))). Rates are per
///         {RATE_SCALE} (1e18) of warrant raw.
contract WarrantRegistry is Initializable, AccessControlEnumerableUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    uint256 public constant RATE_SCALE = 1e18;

    struct Program {
        bytes32 merkleRoot; // record-date snapshot: leaf(index, account, amount)
        address settlementToken; // convertible asset (e.g. USDC); zero = not-yet-convertible / 配资 record-only
        uint256 settleRate; // settlement raw per RATE_SCALE of warrant
        uint64 deadline; // claim window upper bound (short for 配资, long for a general warrant)
        bool exists;
    }

    mapping(uint256 => Program) public programs;
    /// @notice programId => account => warrant amount claimed (persistent, on-chain queryable).
    mapping(uint256 => mapping(address => uint256)) public warrant;
    /// @notice programId => settlement asset still reserved to back settlements.
    mapping(uint256 => uint256) public settleReserve;

    mapping(uint256 => BitMaps.BitMap) private _claimed; // programId => merkle index bitmap
    uint256 public programCount;

    event ProgramCreated(
        uint256 indexed programId, bytes32 merkleRoot, address settlementToken, uint256 settleRate, uint64 deadline
    );
    event SettlementConfigured(uint256 indexed programId, address token, uint256 rate);
    event Funded(uint256 indexed programId, address indexed from, uint256 amount);
    event Claimed(uint256 indexed programId, uint256 index, address indexed account, uint256 amount, uint256 assetOut);
    event Swept(uint256 indexed programId, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error BadTerms();
    error UnknownProgram();
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
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
    }

    // ── program lifecycle ─────────────────────────────────────────────────────

    /// @notice Register a program. Admin-only. `settlementToken` may be zero — for a general
    ///         warrant whose milestone hasn't resolved yet (set later via {configureSettlement}),
    ///         or for a 配资 record whose root is anchored on-chain but never settled here. A
    ///         non-zero `settlementToken` requires a non-zero `settleRate`.
    function createProgram(bytes32 merkleRoot, address settlementToken, uint256 settleRate, uint64 deadline)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 programId)
    {
        if (settlementToken != address(0) && settleRate == 0) revert BadTerms();
        programId = programCount++;
        programs[programId] = Program({
            merkleRoot: merkleRoot,
            settlementToken: settlementToken,
            settleRate: settleRate,
            deadline: deadline,
            exists: true
        });
        emit ProgramCreated(programId, merkleRoot, settlementToken, settleRate, deadline);
    }

    /// @notice Set / update the convertible settlement asset (e.g. once a milestone resolves).
    ///         Admin-only.
    function configureSettlement(uint256 programId, address token, uint256 rate)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        Program storage p = programs[programId];
        if (!p.exists) revert UnknownProgram();
        if (token == address(0) || rate == 0) revert BadTerms();
        p.settlementToken = token;
        p.settleRate = rate;
        emit SettlementConfigured(programId, token, rate);
    }

    /// @notice Fund + reserve settlement asset for a program. OPS-only; caller must `approve` the
    ///         registry for `amount` of the program's `settlementToken` first.
    function fund(uint256 programId, uint256 amount) external onlyRole(OPS_ROLE) nonReentrant {
        Program storage p = programs[programId];
        if (!p.exists) revert UnknownProgram();
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

    /// @notice Settlement asset paid for claiming `amount` warrants (0 if not yet convertible).
    function previewClaim(uint256 programId, uint256 amount) external view returns (uint256) {
        uint256 rate = programs[programId].settleRate;
        return rate == 0 ? 0 : Math.mulDiv(amount, rate, RATE_SCALE);
    }

    // ── claim / sweep ───────────────────────────────────────────────────────────

    /// @notice Verify `account`'s snapshot allocation and settle it in the settlement asset, in
    ///         one call. Anyone may submit a valid proof on an account's behalf; the record /
    ///         payout always accrues to `account`. Reverts (leaving the index unconsumed) if the
    ///         program is not yet convertible or under-funded — retry once ready.
    function claim(uint256 programId, uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Program storage p = programs[programId];
        if (!p.exists) revert UnknownProgram();
        if (block.timestamp > p.deadline) revert ClaimClosed();
        if (_claimed[programId].get(index)) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        if (!MerkleProof.verify(proof, p.merkleRoot, leaf)) revert InvalidProof();

        if (p.settlementToken == address(0)) revert NotConvertibleYet();
        uint256 out = Math.mulDiv(amount, p.settleRate, RATE_SCALE);
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
    ///         a custody address. Deadline-gated; since every claim settles immediately, whatever
    ///         is left is exactly the unclaimed holders' share.
    function sweepUnclaimed(uint256 programId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        Program storage p = programs[programId];
        if (!p.exists) revert UnknownProgram();
        if (block.timestamp <= p.deadline) revert ClaimStillOpen();
        if (to == address(0)) revert ZeroAddress();
        uint256 reserve = settleReserve[programId];
        if (reserve != 0) {
            settleReserve[programId] = 0;
            IERC20(p.settlementToken).safeTransfer(to, reserve);
        }
        emit Swept(programId, to, reserve);
    }

    // ── role guards (repo convention) ───────────────────────────────────────────

    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

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

    /// @dev Storage gap for upgrade-safe additions. 5 vars (programs, warrant, settleReserve,
    ///      _claimed, programCount) + 45 = 50 slots reserved.
    uint256[45] private __gap;
}
