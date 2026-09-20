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
///         mStocks, a CVR-mStock, …), one {Leg} per token by convention. Duplicate-token legs are
///         uncommon but legitimate — the same token can serve two economically distinct purposes
///         in one basket (e.g. base consideration and a separately accounted premium), each kept
///         as its own leg so the split stays visible in the program terms — and the accounting is
///         written defensively for them (`reserved` is keyed by token, shared across duplicate
///         legs). Each leg carries a **`total`** — the whole amount of that reward token to be
///         distributed — and a holder surrendering `amount` of the old token receives a
///         **pro-rata** slice:
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
///         → configured (configureProgram: OPS supplies the frozen-supply snapshot + [startTime,
///         deadline] window) → funded (fund: every leg up to its `total` — Created-only) →
///         `Active` (configureProgram: state=Active, refused until every leg's reserve covers its
///         total) → claimed within the window → `Closed` (sweepUnclaimed after deadline).
///
///         Reward funds are accounted **per program** (`reserved[programId][token]`): a claim only
///         ever draws from its own program's reserve, so programs never touch each other's money,
///         and `sweepUnclaimed` is precise and deadline-gated. Its destination is further bound to
///         an admin-maintained allowlist ({isSweepRecipient}) — a leaked or malicious OPS key can
///         trigger the sweep, but never redirect it to an address of its own choosing.
///
///         `oldToken` / `oldSupplySnapshot` are frozen by {configureProgram} once any leg has been
///         funded, and the whole patch is refused once any {claim} has succeeded — see
///         {configureProgram} for why.
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
///              totalSupply, state: 0})` (any 0 field keeps its stored value; stays Created)
///           4. `fund(programId, token, amount)` each reward token up to its `total`
///           5. `configureProgram(programId, {state: Active})` — only possible once every leg's
///              reserve covers its total
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
    /// @notice oldToken => true while a program currently targets it (set by {createProgram} or a
    ///         {configureProgram} repoint, cleared for the replaced token when a repoint moves a
    ///         program off it). Never cleared once the program leaves Created — a retired security
    ///         is delisted exactly once; two concurrent programs burning the same oldToken against
    ///         two independently-frozen supply snapshots would let it be redeemed twice over,
    ///         inconsistently, as its live supply shifts between them. A repointed-away token is
    ///         different: no claim can have happened against it (repoint requires Created and
    ///         unfunded), so it was never actually delisted and stays available for a real program.
    mapping(address => bool) public oldTokenRegistered;
    uint256 public programCount;
    /// @notice Admin-maintained allowlist of legitimate {sweepUnclaimed} destinations. A leaked or
    ///         malicious OPS key can trigger a sweep, but — same duty separation as
    ///         {CustodyClaimRouter}'s hot-wallet allowlist — it can only ever send the swept reserve
    ///         to an address the admin has already approved, never to one of its own choosing.
    mapping(address => bool) public isSweepRecipient;

    event ProgramCreated(uint256 indexed programId, address indexed oldToken);
    event ProgramConfigured(uint256 indexed programId, uint64 startTime, uint64 deadline, uint256 oldSupplySnapshot);
    event Funded(uint256 indexed programId, address indexed token, address indexed from, uint256 amount);
    event Claimed(uint256 indexed programId, address indexed holder, uint256 oldAmount);
    event Swept(uint256 indexed programId, address indexed to);
    event SweepRecipientRegistered(address indexed to);
    event SweepRecipientDeregistered(address indexed to);

    error ZeroAddress();
    error NoLegs();
    /// @notice A leg has a zero token/total, or its token equals `oldToken` — the latter would let
    ///         {claim} burn `oldToken` and then try to pay a leg in the very token it just burned,
    ///         out of a reserve that can never be funded (minting it back defeats the whole point
    ///         of retiring it), permanently DOSing every claim on the program.
    error BadLeg();
    /// @notice `oldToken` is already targeted by another program (see {oldTokenRegistered}).
    error OldTokenAlreadyRegistered(address oldToken);
    error UnknownProgram();
    error InvalidStateTransition();
    error TermsLockedAfterFund();
    error ConfigureLockedOnceActive();
    /// @notice {fund} ran before {configureProgram} set `oldSupplySnapshot`. Funding locks
    ///         the snapshot, so this order would leave the claim denominator at zero
    ///         permanently and every claim reverting.
    error SupplySnapshotNotSet();
    /// @notice A program cannot become Active until each token's reserve covers the sum
    ///         of all leg totals denominated in that token.
    error LegNotFullyFunded(address token, uint256 reserved, uint256 total);
    /// @notice {fund} was called with a token that is not one of `programId`'s legs. Crediting it
    ///         to `reserved` anyway would strand it forever — {claim} and {sweepUnclaimed} only
    ///         ever iterate over the program's legs.
    error NotALegToken(address token);
    /// @notice {fund} after the program opened. Funding is part of getting a program ready,
    ///         not a way to patch one that is already claimable.
    error FundLockedOnceActive();
    /// @notice {configureProgram} would leave `deadline` in the past, or not strictly after
    ///         `startTime`. Checked against whichever of the two the call is actually touching,
    ///         against the other's stored value.
    error InvalidWindow();
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
    /// @notice {sweepUnclaimed}'s `to` is not on the admin-maintained {isSweepRecipient} allowlist.
    error NotRegisteredSweepRecipient();
    /// @notice A sweep recipient may not be this registry itself — sweeping to address(this)
    ///         zeroes the reserve accounting and closes the program while the tokens never move,
    ///         stranding them with no recovery path (a Closed program cannot be reopened).
    error InvalidSweepRecipient(address to);

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
        if (oldTokenRegistered[oldToken]) revert OldTokenAlreadyRegistered(oldToken);
        oldTokenRegistered[oldToken] = true;

        programId = programCount++;
        programs[programId] =
            Program({oldToken: oldToken, startTime: 0, deadline: 0, oldSupplySnapshot: 0, state: uint8(State.Created)});
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].token == address(0) || legs[i].total == 0 || legs[i].token == oldToken) revert BadLeg();
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
    ///         Three guards on top of the free-overwrite rule, all because `claim` reads `oldToken`
    ///         and `oldSupplySnapshot` **live** rather than from a pre-committed per-account amount:
    ///           - `oldToken` / `oldSupplySnapshot` are frozen as soon as any leg has been funded
    ///             ({fund}) — they're the numerator token / denominator of every payout, and swapping
    ///             either after real reward tokens are already reserved would let a later claim burn
    ///             a different old token while dividing by a stale snapshot (or vice versa),
    ///             mis-scaling every payout from that point on.
    ///           - `state` must move strictly forward (`Created` → `Active`) and can never reach
    ///             `Closed` here — that transition is {sweepUnclaimed}'s exclusively, atomically
    ///             paired with sweeping the remaining reserve.
    ///           - Once any {claim} has succeeded, the ENTIRE patch is refused — every claimant of a
    ///             program must be settled under the exact same terms.
    ///
    ///         OPS-only and fully trusted otherwise: the contract does NOT read the snapshot on-chain
    ///         or verify the old supply is frozen. OPS is responsible for supplying the correct
    ///         `oldSupplySnapshot` — the old token's `totalSupply()` captured AFTER freezing it
    ///         (`setMintAllowed(false)` off-registry) — as the pro-rata denominator, and for setting
    ///         `state` to `Active` when the program is ready to claim. A wrong snapshot mis-scales
    ///         every payout, so freeze first, then snapshot, then fund.
    function configureProgram(uint256 programId, Program calldata program) external onlyRole(OPS_ROLE) {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();
        // Created is the only configurable state. Active means the terms are published and
        // the reserves committed, so everything this exposes is something a holder already
        // relies on; Closed means the program is history.
        //
        // This subsumes the previous "locked once a claim landed" rule — claiming requires
        // Active — and covers what that rule could not: a program nobody ever claims, whose
        // deadline stayed shrinkable and whose snapshot stayed rewritable indefinitely.
        if (p.state != uint8(State.Created)) revert ConfigureLockedOnceActive();

        if (program.oldToken != address(0) || program.oldSupplySnapshot != 0) {
            if (_isFunded(programId)) revert TermsLockedAfterFund();
            if (program.oldToken != address(0) && program.oldToken != p.oldToken) {
                if (oldTokenRegistered[program.oldToken]) revert OldTokenAlreadyRegistered(program.oldToken);
                // The replaced token was never actually delisted — this branch is only reachable
                // while Created and unfunded, so no claim can have burned it. Free it for a real
                // program (or a repoint back); without this a mis-repoint locks the ORIGINAL,
                // correct token out of the registry forever.
                oldTokenRegistered[p.oldToken] = false;
                oldTokenRegistered[program.oldToken] = true;
                p.oldToken = program.oldToken;
            }
            if (program.oldSupplySnapshot != 0) p.oldSupplySnapshot = program.oldSupplySnapshot;
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
            // Active means claimable, so it has to mean funded — on every leg. A holder
            // whose claim reverts InsufficientReserved cannot tell an under-funded program
            // from a broken one, and a basket that is short on one leg pays out on none of
            // them, since claim() delivers all legs or reverts.
            if (program.state == uint8(State.Active)) {
                if (p.deadline <= block.timestamp) revert InvalidWindow();
                Leg[] storage legs = _legs[programId];
                for (uint256 i = 0; i < legs.length; ++i) {
                    address token = legs[i].token;
                    uint256 required;
                    // Reserve is keyed by token, not by leg. Duplicate-token legs share it.
                    for (uint256 j = 0; j < legs.length; ++j) {
                        if (legs[j].token == token) required += legs[j].total;
                    }
                    uint256 r = reserved[programId][token];
                    if (r < required) revert LegNotFullyFunded(token, r, required);
                }
            }
            p.state = program.state;
        }

        emit ProgramConfigured(programId, p.startTime, p.deadline, p.oldSupplySnapshot);
    }

    /// @dev True once any leg of `programId` has a non-zero reserve, i.e. {fund} has run at least
    ///      once. Used to lock `oldToken` / `oldSupplySnapshot` in {configureProgram}.
    function _isFunded(uint256 programId) internal view returns (bool) {
        Leg[] storage legs = _legs[programId];
        for (uint256 i = 0; i < legs.length; ++i) {
            if (reserved[programId][legs[i].token] != 0) return true;
        }
        return false;
    }

    /// @dev True if `token` is one of `programId`'s legs. Used to reject {fund} deposits of a token
    ///      that isn't part of the basket — a wrong-token transfer would otherwise get credited to
    ///      `reserved` and then never be read by {claim} or {sweepUnclaimed}, both of which only
    ///      ever iterate over the program's legs, stranding it permanently.
    function _isLegToken(uint256 programId, address token) internal view returns (bool) {
        Leg[] storage legs = _legs[programId];
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].token == token) return true;
        }
        return false;
    }

    /// @notice Fund + reserve `amount` of `token` for `programId`. OPS-only, accounted so a claim
    ///         can never dip into another program's (or unrelated) balance. Caller must `approve`
    ///         this registry for `amount` first. Only allowed while the program is still Created —
    ///         Active asserts every leg's reserve covers its total, so reserves are frozen there.
    function fund(uint256 programId, address token, uint256 amount) external onlyRole(OPS_ROLE) nonReentrant {
        uint8 s = programs[programId].state;
        if (s == uint8(State.None)) revert UnknownProgram();
        // Funding belongs to the Created state. Active asserts that every leg's reserve
        // covers its total, and that assertion is worthless if the reserves can still move
        // afterwards. Closed falls under the same condition.
        if (s != uint8(State.Created)) revert FundLockedOnceActive();
        if (token == address(0)) revert ZeroAddress();
        if (!_isLegToken(programId, token)) revert NotALegToken(token);
        // oldToken and the legs are fixed at creation, but oldSupplySnapshot — the claim
        // denominator — is not, and funding locks it. Without this a caller could fund
        // straight after creating, stranding the snapshot at zero: previewClaim would
        // return zeros and every claim would revert on the division. The program would
        // look configured, hold the reserves, and deliver nothing.
        if (programs[programId].oldSupplySnapshot == 0) revert SupplySnapshotNotSet();
        if (amount == 0) revert ZeroAmount();
        reserved[programId][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(programId, token, msg.sender, amount);
    }

    // ── sweep recipient allowlist (admin) ────────────────────────────────────────

    /// @notice Add a {sweepUnclaimed} destination to the allowlist. Admin-only (more sensitive than
    ///         triggering a sweep, hence separated from OPS_ROLE — same pattern as
    ///         {CustodyClaimRouter.registerHotWallet}).
    function registerSweepRecipient(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert InvalidSweepRecipient(to);
        isSweepRecipient[to] = true;
        emit SweepRecipientRegistered(to);
    }

    /// @notice Batch variant of {registerSweepRecipient}.
    function registerSweepRecipients(address[] calldata recipients) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            if (recipients[i] == address(this)) revert InvalidSweepRecipient(recipients[i]);
            isSweepRecipient[recipients[i]] = true;
            emit SweepRecipientRegistered(recipients[i]);
        }
    }

    function deregisterSweepRecipient(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isSweepRecipient[to] = false;
        emit SweepRecipientDeregistered(to);
    }

    // ── views ─────────────────────────────────────────────────────────────────

    function legsCount(uint256 programId) external view returns (uint256) {
        return _legs[programId].length;
    }

    function legAt(uint256 programId, uint256 i) external view returns (Leg memory) {
        return _legs[programId][i];
    }

    /// @notice Per-leg consideration for surrendering `oldAmount` (raw), in leg order. Returns zeros
    ///         unless the program is currently `Active` (configured, funded, and open) — `Created`
    ///         has no committed reserve to preview against yet, and `Closed` no longer accepts
    ///         claims at all, so a snapshot-only check would keep previewing a payout that {claim}
    ///         would immediately revert on.
    function previewClaim(uint256 programId, uint256 oldAmount) public view returns (uint256[] memory outs) {
        Leg[] storage legs = _legs[programId];
        outs = new uint256[](legs.length);
        if (programs[programId].state != uint8(State.Active)) return outs;
        uint256 snapshot = programs[programId].oldSupplySnapshot;
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
    ///         cannot be pulled out from under holders who can still claim. `to` must be on the
    ///         admin-maintained {isSweepRecipient} allowlist — a leaked or malicious OPS key can
    ///         trigger the sweep, but never redirect it to an address of its own choosing.
    function sweepUnclaimed(uint256 programId, address to) external onlyRole(OPS_ROLE) nonReentrant {
        Program storage p = programs[programId];
        if (p.state == uint8(State.None)) revert UnknownProgram();
        if (p.state != uint8(State.Active)) revert NotActive();
        if (block.timestamp <= p.deadline) revert ClaimStillOpen();
        if (!isSweepRecipient[to]) revert NotRegisteredSweepRecipient();

        p.state = uint8(State.Closed);
        Leg[] storage legs = _legs[programId];
        bool swept;
        for (uint256 i = 0; i < legs.length; ++i) {
            address token = legs[i].token;
            uint256 r = reserved[programId][token];
            if (r != 0) {
                reserved[programId][token] = 0; // token may repeat across legs; second pass is a no-op
                IERC20(token).safeTransfer(to, r);
                swept = true;
            }
        }
        if (swept) emit Swept(programId, to);
    }

    // ── role guards (repo convention) ───────────────────────────────────────────

    /// @notice Disallows self-grant — admin must delegate OPS_ROLE to a separate account.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        // address(0) can never transact, but granting it a role still inflates
        // getRoleMemberCount — which the last-admin guards below count on.
        if (account == address(0)) revert ZeroAddress();
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

    /// @dev Six state slots + 44 reserved slots = 50 slots total.
    uint256[44] private __gap;
}
