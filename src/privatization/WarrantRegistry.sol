// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {BitMaps} from "@openzeppelin/contracts/utils/structs/BitMaps.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Registry for warrant / 配资 (leverage) issuance — see docs/corporate-actions-td.md §7.
///
///         Warrants are a *rights-offering-style* entitlement: eligibility and per-account amount
///         are fixed at a **record-date snapshot** (resource limits, per-holder caps, leverage
///         credit lines — none derivable from any surrender), published as a Merkle root. There
///         is **no on-chain option exercise**; instead the model is "**record + settle**":
///           - `claim` always **records** the account's allocation (`recorded`), replay-guarded.
///           - if the allocation is convertible to a settlement asset (e.g. USDC "U"), the same
///             call **settles it immediately** (pays U at `settleRate`).
///           - otherwise only the record stands; for a general warrant it can be settled later
///             via {claimSettlement} once `configureSettlement` + {fund} happen; for **配资** the
///             short window simply **expires** (record-only, no later settlement).
///
///         One contract manages many programs, keyed by `programId`. A per-program
///         `deferredSettlement` flag distinguishes a general warrant (`true`, later settlement
///         allowed) from 配资 (`false`, expires at the deadline).
///
///         Merkle leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount)))).
///         Rates are per {RATE_SCALE} (1e18) of warrant raw.
contract WarrantRegistry is AccessControlEnumerable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using BitMaps for BitMaps.BitMap;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    uint256 public constant RATE_SCALE = 1e18;

    struct Program {
        bytes32 merkleRoot; // record-date snapshot: leaf(index, account, amount)
        uint64 deadline; // registration (claim) window upper bound
        bool deferredSettlement; // true = general warrant (settle later); false = 配资 (expire at deadline)
        address settlementToken; // convertible asset (e.g. USDC); zero = not yet convertible
        uint256 settleRate; // settlement raw per RATE_SCALE of warrant
        bool exists;
    }

    mapping(uint256 => Program) public programs;
    /// @notice programId => account => warrant amount recorded (allocation claimed).
    mapping(uint256 => mapping(address => uint256)) public recorded;
    /// @notice programId => account => warrant amount already settled (paid out in the asset).
    mapping(uint256 => mapping(address => uint256)) public settled;
    /// @notice programId => settlement asset still reserved to back settlements.
    mapping(uint256 => uint256) public settleReserve;

    mapping(uint256 => BitMaps.BitMap) private _claimed; // programId => merkle index bitmap
    mapping(uint256 => uint256) public totalRecorded; // programId => Σ recorded (warrant units)
    mapping(uint256 => uint256) public totalSettled; // programId => Σ settled (warrant units)
    uint256 public programCount;

    event ProgramCreated(uint256 indexed programId, bytes32 merkleRoot, uint64 deadline, bool deferredSettlement);
    event SettlementConfigured(uint256 indexed programId, address token, uint256 rate);
    event Funded(uint256 indexed programId, address indexed from, uint256 amount);
    event WarrantClaimed(uint256 indexed programId, uint256 index, address indexed account, uint256 amount);
    event WarrantSettled(uint256 indexed programId, address indexed account, uint256 warrantAmount, uint256 assetOut);
    event Swept(uint256 indexed programId, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error BadTerms();
    error UnknownProgram();
    error ClaimClosed();
    error ClaimStillOpen();
    error AlreadyClaimed();
    error InvalidProof();
    error NoSettlementToken();
    error NotDeferred();
    error NothingToSettle();
    error InsufficientReserved();
    error SelfGrantNotAllowed();
    error CannotRenounceLastAdmin();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
    }

    // ── program lifecycle ─────────────────────────────────────────────────────

    /// @notice Register a warrant / 配资 program. Admin-only. `settlementToken` may be zero
    ///         (not-yet-convertible); if non-zero, `settleRate` must be non-zero.
    function createProgram(
        bytes32 merkleRoot,
        uint64 deadline,
        bool deferredSettlement,
        address settlementToken,
        uint256 settleRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 programId) {
        if (settlementToken != address(0) && settleRate == 0) revert BadTerms();
        programId = programCount++;
        programs[programId] = Program({
            merkleRoot: merkleRoot,
            deadline: deadline,
            deferredSettlement: deferredSettlement,
            settlementToken: settlementToken,
            settleRate: settleRate,
            exists: true
        });
        emit ProgramCreated(programId, merkleRoot, deadline, deferredSettlement);
    }

    /// @notice Set / update the convertible settlement asset for a program (e.g. once a milestone
    ///         resolves). Admin-only.
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

    /// @notice Fund + reserve settlement asset for a program. OPS-only; caller must `approve`
    ///         the registry for `amount` of the program's `settlementToken` first.
    function fund(uint256 programId, uint256 amount) external onlyRole(OPS_ROLE) nonReentrant {
        Program storage p = programs[programId];
        if (!p.exists) revert UnknownProgram();
        if (p.settlementToken == address(0)) revert NoSettlementToken();
        if (amount == 0) revert ZeroAmount();
        settleReserve[programId] += amount;
        IERC20(p.settlementToken).safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(programId, msg.sender, amount);
    }

    // ── claim / settle ──────────────────────────────────────────────────────────

    function isClaimed(uint256 programId, uint256 index) external view returns (bool) {
        return _claimed[programId].get(index);
    }

    /// @notice Record `account`'s snapshot warrant allocation (and settle immediately if the
    ///         program is already convertible + funded). Anyone may submit a valid proof on an
    ///         account's behalf; the record / settlement always accrues to `account`.
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

        _claimed[programId].set(index);
        recorded[programId][account] += amount;
        totalRecorded[programId] += amount;
        emit WarrantClaimed(programId, index, account, amount);

        // Convertible now → settle in the same call.
        if (p.settlementToken != address(0) && p.settleRate != 0) {
            _settle(programId, account, amount);
        }
    }

    /// @notice Settle a general warrant's recorded-but-unsettled allocation once the asset is
    ///         ready (deferred path). Reverts for 配资 (`deferredSettlement == false`), whose
    ///         unsettled records simply expire.
    function claimSettlement(uint256 programId) external nonReentrant {
        Program storage p = programs[programId];
        if (!p.exists) revert UnknownProgram();
        if (!p.deferredSettlement) revert NotDeferred();
        if (p.settlementToken == address(0)) revert NoSettlementToken();
        uint256 owed = recorded[programId][msg.sender] - settled[programId][msg.sender];
        if (owed == 0) revert NothingToSettle();
        _settle(programId, msg.sender, owed);
    }

    function _settle(uint256 programId, address account, uint256 warrantAmount) private {
        Program storage p = programs[programId];
        uint256 out = Math.mulDiv(warrantAmount, p.settleRate, RATE_SCALE);
        if (out == 0) return;
        uint256 r = settleReserve[programId];
        if (r < out) revert InsufficientReserved();
        settleReserve[programId] = r - out;
        settled[programId][account] += warrantAmount;
        totalSettled[programId] += warrantAmount;
        IERC20(p.settlementToken).safeTransfer(account, out);
        emit WarrantSettled(programId, account, warrantAmount, out);
    }

    /// @notice After the deadline, sweep the genuinely-excess settlement reserve to custody.
    ///         For 配资 the unsettled records have expired, so the whole reserve is swept; for a
    ///         general warrant the reserve backing outstanding (recorded-but-unsettled)
    ///         allocations is retained so deferred {claimSettlement} stays honoured.
    function sweepUnsettled(uint256 programId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        Program storage p = programs[programId];
        if (!p.exists) revert UnknownProgram();
        if (block.timestamp <= p.deadline) revert ClaimStillOpen();
        if (to == address(0)) revert ZeroAddress();

        uint256 reserve = settleReserve[programId];
        uint256 sweepable = reserve;
        if (p.deferredSettlement && p.settleRate != 0) {
            uint256 outstanding = totalRecorded[programId] - totalSettled[programId];
            uint256 owedAsset = Math.mulDiv(outstanding, p.settleRate, RATE_SCALE);
            sweepable = reserve > owedAsset ? reserve - owedAsset : 0;
        }
        if (sweepable != 0) {
            settleReserve[programId] = reserve - sweepable;
            IERC20(p.settlementToken).safeTransfer(to, sweepable);
        }
        emit Swept(programId, to, sweepable);
    }

    // ── role guards (repo convention) ───────────────────────────────────────────

    function grantRole(bytes32 role, address account) public virtual override(AccessControl, IAccessControl) {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

    function renounceRole(bytes32 role, address callerConfirmation)
        public
        virtual
        override(AccessControl, IAccessControl)
    {
        if (role == DEFAULT_ADMIN_ROLE && getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1) {
            revert CannotRenounceLastAdmin();
        }
        super.renounceRole(role, callerConfirmation);
    }
}
