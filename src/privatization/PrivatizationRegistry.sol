// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
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
///         security (`oldToken`) is swapped for a basket of standardized reward tokens (USDC, new
///         mStocks, a CVR-mStock, …), one {Leg} each. Each leg carries a **`total`** — the whole
///         amount of that reward token to be distributed — and a holder surrendering `amount` of
///         the old token receives a **pro-rata** slice:
///
///             out_i = amount * leg.total / oldSupplySnapshot
///
///         `oldSupplySnapshot` is a **fixed snapshot** of the old token's `totalSupply()`, supplied
///         by OPS at {configureProgram} AFTER freezing the supply (`setMintAllowed(false)`). It must
///         be a fixed value — never live supply — because {claim} burns the surrendered old tokens,
///         so live `totalSupply` shrinks as people claim; dividing by a shrinking denominator would
///         over-distribute.
///
///         Lifecycle (state machine): `Created` → (operator `setMintAllowed(false)` off-registry)
///         → `Active` (configureProgram: OPS supplies the frozen-supply snapshot + [startTime,
///         deadline] window + sets state=Active) → funded → claimed within the window → `Closed`
///         (sweepUnclaimed after deadline).
///
///         Reward funds are accounted **per program** (`reserved[programId][token]`): a claim only
///         ever draws from its own program's reserve, so programs never touch each other's money,
///         and `sweepUnclaimed` is precise and deadline-gated.
///
///         A CVR-mStock is redeemed by simply registering another program whose `oldToken` is that
///         CVR-mStock — the deferred settlement reuses this same machinery, no bespoke contract.
///
///         Upgradeable: deployed behind a TransparentUpgradeableProxy (like {TokenIssuer}); upgrade
///         authority lives on the auto-created ProxyAdmin, separate from DEFAULT_ADMIN_ROLE.
///
///         Setup per program (operator):
///           1. `createProgram(oldToken, legs)` → programId (each leg = token + total)
///           2. `setMintAllowed(false)` on the old token (freeze supply — off-registry, OPS)
///           3. `configureProgram(programId, {startTime, deadline, oldSupplySnapshot: frozen
///              totalSupply, state: Active})` (any 0 field keeps its stored value)
///           4. `fund(programId, token, amount)` each reward token up to its `total`
contract PrivatizationRegistry is Initializable, AccessControlEnumerableUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    enum State {
        None, // 0 — program id never created
        Created, // 1 — legs set; not yet configured (no snapshot / window)
        Active, // 2 — supply snapshotted + window open; claimable
        Closed // 3 — swept after deadline
    }

    struct Leg {
        address token; // reward ERC-20
        uint256 total; // total amount of this reward token distributed across the whole old supply
    }

    struct Program {
        address oldToken;
        uint64 startTime; // claims accepted from this timestamp (inclusive)
        uint64 deadline; // claims accepted up to and including this timestamp
        uint256 oldSupplySnapshot; // denominator: oldToken.totalSupply() captured at configureProgram
        uint8 state; // State
    }

    mapping(uint256 => Program) public programs;
    mapping(uint256 => Leg[]) internal _legs;
    /// @notice programId => reward token => amount still reserved to back claims.
    mapping(uint256 => mapping(address => uint256)) public reserved;
    uint256 public programCount;

    event ProgramCreated(uint256 indexed programId, address indexed oldToken);
    event ProgramConfigured(uint256 indexed programId, uint64 startTime, uint64 deadline, uint256 oldSupplySnapshot);
    event Funded(uint256 indexed programId, address indexed token, address indexed from, uint256 amount);
    event Claimed(uint256 indexed programId, address indexed holder, uint256 oldAmount);
    event Swept(uint256 indexed programId, address indexed to);

    error ZeroAddress();
    error NoLegs();
    error BadLeg();
    error UnknownProgram();
    error NotActive();
    error ClaimNotStarted();
    error ClaimClosed();
    error ClaimStillOpen();
    error ZeroAmount();
    error NothingToDeliver();
    error InsufficientReserved();
    error BurnFailed();
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

    /// @notice Register a delisting program. OPS-only — the whole program lifecycle (create /
    ///         configure / fund / sweep) is an operational duty; admin only manages roles. Each leg
    ///         must carry a token and non-zero `total`; at least one leg is required. The program
    ///         starts in `Created` — it becomes claimable only after {configureProgram}.
    function createProgram(address oldToken, Leg[] calldata legs)
        external
        onlyRole(OPS_ROLE)
        returns (uint256 programId)
    {
        if (oldToken == address(0)) revert ZeroAddress();
        if (legs.length == 0) revert NoLegs();

        programId = programCount++;
        programs[programId] =
            Program({oldToken: oldToken, startTime: 0, deadline: 0, oldSupplySnapshot: 0, state: uint8(State.Created)});
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].token == address(0) || legs[i].total == 0) revert BadLeg();
            _legs[programId].push(legs[i]);
        }
        emit ProgramCreated(programId, oldToken);
    }

    /// @notice Patch a program's fields. `programId` selects the program; for every field of the
    ///         {Program} struct a **zero value means "keep the stored value"** and a non-zero value
    ///         overwrites it. So an operator can set or later adjust any subset — open the window by
    ///         supplying `{startTime, deadline, oldSupplySnapshot, state: Active}`, or extend the
    ///         deadline alone by supplying only `deadline` (everything else 0).
    ///
    ///         OPS-only and fully trusted: the contract does NOT read the snapshot on-chain or
    ///         verify the old supply is frozen. OPS is responsible for supplying the correct
    ///         `oldSupplySnapshot` — the old token's `totalSupply()` captured AFTER freezing it
    ///         (`setMintAllowed(false)` off-registry) — as the pro-rata denominator, and for setting
    ///         `state` to `Active` when the program is ready to claim. A wrong snapshot mis-scales
    ///         every payout, so freeze first, then snapshot.
    function configureProgram(uint256 programId, Program calldata program) external onlyRole(OPS_ROLE) {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();

        if (program.oldToken != address(0)) p.oldToken = program.oldToken;
        if (program.startTime != 0) p.startTime = program.startTime;
        if (program.deadline != 0) p.deadline = program.deadline;
        if (program.oldSupplySnapshot != 0) p.oldSupplySnapshot = program.oldSupplySnapshot;
        if (program.state != 0) p.state = program.state;

        emit ProgramConfigured(programId, p.startTime, p.deadline, p.oldSupplySnapshot);
    }

    /// @notice Fund + reserve `amount` of `token` for `programId`. OPS-only, accounted so a claim
    ///         can never dip into another program's (or unrelated) balance. Caller must `approve`
    ///         this registry for `amount` first. Allowed while the program exists and is not closed.
    function fund(uint256 programId, address token, uint256 amount) external onlyRole(OPS_ROLE) nonReentrant {
        uint8 s = programs[programId].state;
        if (s == uint8(State.None)) revert UnknownProgram();
        if (s == uint8(State.Closed)) revert ClaimClosed();
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

    /// @notice Per-leg consideration for surrendering `oldAmount` (raw), in leg order. Returns zeros
    ///         until the program is configured (snapshot == 0).
    function previewClaim(uint256 programId, uint256 oldAmount) public view returns (uint256[] memory outs) {
        Leg[] storage legs = _legs[programId];
        outs = new uint256[](legs.length);
        uint256 snapshot = programs[programId].oldSupplySnapshot;
        if (snapshot == 0) return outs;
        for (uint256 i = 0; i < legs.length; ++i) {
            outs[i] = Math.mulDiv(oldAmount, legs[i].total, snapshot);
        }
    }

    // ── claim / sweep ───────────────────────────────────────────────────────────

    /// @notice Surrender `amount` (raw) of the program's old token for the pro-rata basket. Caller
    ///         must `approve` this registry for `amount` first. The old tokens are pulled in and
    ///         burned (registry holds BURN_ROLE on the old token); each leg pays
    ///         `amount * leg.total / oldSupplySnapshot` from that program's reserve. A
    ///         compliance-blocked mStocks leg reverts the whole claim (old token stays with the
    ///         holder) — retry once unblocked, so no escrow is needed.
    function claim(uint256 programId, uint256 amount) external nonReentrant {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();
        if (p.state != uint8(State.Active)) revert NotActive();
        if (block.timestamp < p.startTime) revert ClaimNotStarted();
        if (block.timestamp > p.deadline) revert ClaimClosed();
        if (amount == 0) revert ZeroAmount();

        uint256 snapshot = p.oldSupplySnapshot;
        IERC20(p.oldToken).safeTransferFrom(msg.sender, address(this), amount);
        if (!IMintAndBurnable(p.oldToken).burn(amount)) revert BurnFailed();

        Leg[] storage legs = _legs[programId];
        bool delivered;
        for (uint256 i = 0; i < legs.length; ++i) {
            uint256 out = Math.mulDiv(amount, legs[i].total, snapshot);
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
    ///         token to a custody address and close it. OPS-only. Deadline-gated so committed funds
    ///         cannot be pulled out from under holders who can still claim.
    function sweepUnclaimed(uint256 programId, address to) external onlyRole(OPS_ROLE) nonReentrant {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();
        if (p.state != uint8(State.Active)) revert NotActive();
        if (block.timestamp <= p.deadline) revert ClaimStillOpen();
        if (to == address(0)) revert ZeroAddress();

        p.state = uint8(State.Closed);
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

    /// @dev Storage gap for upgrade-safe additions. 4 vars (programs, _legs, reserved,
    ///      programCount) + 46 = 50 slots reserved.
    uint256[46] private __gap;
}
