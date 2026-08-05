// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMintAndBurnable} from "../tokenIssuer/IMintAndBurnable.sol";

/// @notice Registry for privatization / take-private (delisting) events — see
///         docs/corporate-actions-td.md §4.
///
///         One contract manages many delisting **programs**. In each program a retired mStocks
///         security (`oldToken`) is swapped, at FIXED per-share rates, for a basket of
///         standardized reward tokens (USDC, new mStocks, a CVR-mStock, …), one {Leg} each.
///         Because rates are fixed and the old token's supply is frozen
///         (`ScaledToken.setMintAllowed(false)`), there is no record-date snapshot, Merkle tree
///         or escrow: whoever holds the old token can surrender any amount for proportional
///         consideration.
///
///         Reward funds are accounted **per program** (`reserved[programId][token]`): a claim
///         only ever draws from its own program's reserve, so programs never touch each other's
///         money, and `sweepUnclaimed` is precise and deadline-gated.
///
///         A CVR-mStock is redeemed by simply registering another program whose `oldToken` is
///         that CVR-mStock — the deferred settlement of the original event reuses this same
///         machinery, no bespoke contract.
///
///         Setup per program (operator):
///           1. `setMintAllowed(false)` on the old token (freeze supply)
///           2. grant this registry ISSUER_ROLE on that old token (to burn surrendered balances)
///           3. `createProgram(oldToken, legs, deadline)` → programId
///           4. `fund(programId, token, amount)` each reward token up to the payable ceiling
///
///         Rates are per {RATE_SCALE} (1e18) of old-token raw; the operator bakes any
///         UI-multiplier conversion into the rate (the old token's multiplier is frozen at
///         delisting). Fractional remainders truncate (round down).
contract PrivatizationRegistry is AccessControlEnumerable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// @notice Fixed-point scale for a leg's rate. 1e18 == "1.0 reward raw per old raw unit".
    uint256 public constant RATE_SCALE = 1e18;

    struct Leg {
        address token; // reward ERC-20
        uint256 rate; // reward raw delivered per RATE_SCALE of old raw surrendered
    }

    struct Program {
        address oldToken;
        uint64 deadline; // claims accepted up to and including this timestamp
        bool exists;
    }

    mapping(uint256 => Program) public programs;
    mapping(uint256 => Leg[]) internal _legs;
    /// @notice programId => reward token => amount still reserved to back claims.
    mapping(uint256 => mapping(address => uint256)) public reserved;
    uint256 public programCount;

    event ProgramCreated(uint256 indexed programId, address indexed oldToken, uint64 deadline);
    event Funded(uint256 indexed programId, address indexed token, address indexed from, uint256 amount);
    event Claimed(uint256 indexed programId, address indexed holder, uint256 oldAmount);
    event Swept(uint256 indexed programId, address indexed to);

    error ZeroAddress();
    error NoLegs();
    error BadLeg();
    error UnknownProgram();
    error ClaimClosed();
    error ClaimStillOpen();
    error ZeroAmount();
    error NothingToDeliver();
    error InsufficientReserved();
    error BurnFailed();
    error SelfGrantNotAllowed();
    error CannotRenounceLastAdmin();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
    }

    // ── program lifecycle ─────────────────────────────────────────────────────

    /// @notice Register a delisting program. Admin-only (sets economic parameters). Each leg
    ///         must carry a token and non-zero rate; at least one leg is required.
    function createProgram(address oldToken, Leg[] calldata legs, uint64 deadline)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint256 programId)
    {
        if (oldToken == address(0)) revert ZeroAddress();
        if (legs.length == 0) revert NoLegs();

        programId = programCount++;
        programs[programId] = Program({oldToken: oldToken, deadline: deadline, exists: true});
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].token == address(0) || legs[i].rate == 0) revert BadLeg();
            _legs[programId].push(legs[i]);
        }
        emit ProgramCreated(programId, oldToken, deadline);
    }

    /// @notice Fund + reserve `amount` of `token` for `programId`. OPS-only, accounted so a
    ///         claim can never dip into another program's (or unrelated) balance. Caller must
    ///         `approve` this registry for `amount` first.
    function fund(uint256 programId, address token, uint256 amount) external onlyRole(OPS_ROLE) nonReentrant {
        if (!programs[programId].exists) revert UnknownProgram();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        reserved[programId][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(programId, token, msg.sender, amount);
    }

    // ── views ─────────────────────────────────────────────────────────────────

    function legsCount(uint256 programId) external view returns (uint256) {
        return _legs[programId].length;
    }

    function legAt(uint256 programId, uint256 i) external view returns (Leg memory) {
        return _legs[programId][i];
    }

    /// @notice Per-leg consideration for surrendering `oldAmount` (raw), in leg order.
    function previewClaim(uint256 programId, uint256 oldAmount) public view returns (uint256[] memory outs) {
        Leg[] storage legs = _legs[programId];
        outs = new uint256[](legs.length);
        for (uint256 i = 0; i < legs.length; ++i) {
            outs[i] = Math.mulDiv(oldAmount, legs[i].rate, RATE_SCALE);
        }
    }

    // ── claim / sweep ───────────────────────────────────────────────────────────

    /// @notice Surrender `amount` (raw) of the program's old token for the fixed-rate basket.
    ///         Caller must `approve` this registry for `amount` first. The old tokens are pulled
    ///         in and burned (registry holds ISSUER_ROLE on the old token); each leg is paid from
    ///         that program's reserve. A compliance-blocked mStocks leg reverts the whole claim
    ///         (old token stays with the holder) — retry once unblocked, so no escrow is needed.
    function claim(uint256 programId, uint256 amount) external nonReentrant {
        Program storage p = programs[programId];
        if (!p.exists) revert UnknownProgram();
        if (block.timestamp > p.deadline) revert ClaimClosed();
        if (amount == 0) revert ZeroAmount();

        IERC20(p.oldToken).safeTransferFrom(msg.sender, address(this), amount);
        if (!IMintAndBurnable(p.oldToken).burn(amount)) revert BurnFailed();

        Leg[] storage legs = _legs[programId];
        bool delivered;
        for (uint256 i = 0; i < legs.length; ++i) {
            uint256 out = Math.mulDiv(amount, legs[i].rate, RATE_SCALE);
            if (out == 0) continue; // dust leg for this amount
            address token = legs[i].token;
            uint256 r = reserved[programId][token];
            if (r < out) revert InsufficientReserved();
            reserved[programId][token] = r - out;
            IERC20(token).safeTransfer(msg.sender, out);
            delivered = true;
        }
        if (!delivered) revert NothingToDeliver(); // guard a dust claim that burns for nothing

        emit Claimed(programId, msg.sender, amount);
    }

    /// @notice After the program deadline, sweep its remaining (unclaimed) reserve of every leg
    ///         token to a custody address. Deadline-gated so committed funds cannot be pulled
    ///         out from under holders who can still claim.
    function sweepUnclaimed(uint256 programId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        Program storage p = programs[programId];
        if (!p.exists) revert UnknownProgram();
        if (block.timestamp <= p.deadline) revert ClaimStillOpen();
        if (to == address(0)) revert ZeroAddress();

        Leg[] storage legs = _legs[programId];
        for (uint256 i = 0; i < legs.length; ++i) {
            address token = legs[i].token;
            uint256 r = reserved[programId][token];
            if (r != 0) {
                reserved[programId][token] = 0; // token may repeat across legs; second pass is a no-op
                IERC20(token).safeTransfer(to, r);
            }
        }
        emit Swept(programId, to);
    }

    // ── role guards (repo convention) ───────────────────────────────────────────

    /// @notice Disallows self-grant — admin must delegate OPS_ROLE to a separate account.
    function grantRole(bytes32 role, address account) public virtual override(AccessControl, IAccessControl) {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

    /// @notice Blocks renouncing the final DEFAULT_ADMIN_ROLE holder.
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
