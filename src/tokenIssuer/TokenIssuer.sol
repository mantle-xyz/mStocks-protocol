// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMintAndBurnable} from "./IMintAndBurnable.sol";

/// @notice Custodial issuer that holds ISSUER_ROLE on one or more ScaledToken contracts
///         and routes mint/burn flow through a whitelisted set of approved recipients.
///
///         Admin (DEFAULT_ADMIN_ROLE) manages the recipient whitelist, pauses the issuer,
///         and may emergency-sweep assets. OPS_ROLE performs day-to-day mint / burn / transfer.
///         Self-grant is disallowed so the admin and operator must be distinct accounts.
contract TokenIssuer is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// @notice Fixed-point scale for privatization rates. 1e18 == "1.0 per old raw unit".
    uint256 public constant RATE_SCALE = 1e18;

    /// @dev recipient => 1-based index in `approvedRecipients`. 0 means "not approved".
    mapping(address => uint256) private recipientIndex;
    /// @notice Enumerable whitelist of mint/burn counterparties.
    address[] public approvedRecipients;

    /// @notice Per-old-token privatization / delisting configuration (方案二 of
    ///         docs/corporate-actions-td.md). When `active`, holders of `oldToken` may
    ///         {claimPrivatization} to swap it, at a fixed per-share rate, for `newToken`
    ///         (minted on demand) and/or `usdc` (pre-funded into this issuer).
    struct PrivatizationConfig {
        address newToken; // address(0) = no stock leg
        address usdc; // address(0) = no cash leg
        uint256 newRate; // newToken raw delivered per RATE_SCALE of old raw surrendered
        uint256 usdcRate; // usdc units delivered per RATE_SCALE of old raw surrendered
        uint64 deadline; // claims accepted up to and including this timestamp
        bool active;
    }

    /// @notice oldToken => its privatization configuration.
    mapping(address => PrivatizationConfig) public privatizations;

    event RecipientApproved(address indexed recipient);
    event RecipientRevoked(address indexed recipient);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted on every successful mint routed through this issuer. `issuer` is the
    ///         emitter itself, included so aggregators indexing many issuers can filter without
    ///         inspecting the log emitter.
    event Minted(address indexed issuer, address indexed token, address indexed recipient, uint256 amount);

    /// @notice Emitted on every successful burn routed through this issuer. `from` is either
    ///         this issuer (burning held inventory) or an approved recipient that pre-approved
    ///         the issuer to pull tokens.
    event Burned(address indexed issuer, address indexed token, address indexed from, uint256 amount);

    /// @notice Emitted on every successful transfer of held inventory routed through this issuer.
    ///         `issuer` is the emitter itself, included so aggregators indexing many issuers can
    ///         filter without inspecting the log emitter.
    event Transferred(address indexed issuer, address indexed token, address indexed recipient, uint256 amount);

    /// @notice Emitted when a privatization is configured (or reconfigured) for `oldToken`.
    event PrivatizationConfigured(
        address indexed oldToken, address newToken, address usdc, uint256 newRate, uint256 usdcRate, uint64 deadline
    );
    /// @notice Emitted when a privatization is closed for `oldToken`.
    event PrivatizationClosed(address indexed oldToken);
    /// @notice Emitted on every successful privatization claim.
    event PrivatizationClaimed(
        address indexed oldToken, address indexed holder, uint256 oldAmount, uint256 newOut, uint256 usdcOut
    );

    error ZeroAddress();
    error RecipientAlreadyApproved();
    error RecipientNotApproved();
    error CannotBeSelf();
    error FromNotApproved();
    error MintFailed();
    error BurnFailed();
    error SelfGrantNotAllowed();
    error CannotRenounceLastAdmin();
    error NoConsiderationConfigured();
    error PrivatizationInactive();
    error PrivatizationClaimClosed();
    error ZeroAmount();
    error NothingToDeliver();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        __Pausable_init();
        // ReentrancyGuardTransient (v5, EIP-1153 TSTORE) uses transient storage — no initializer needed.

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
    }

    function isApprovedRecipient(address account) public view returns (bool) {
        return recipientIndex[account] > 0;
    }

    function numApprovedRecipients() external view returns (uint256) {
        return approvedRecipients.length;
    }

    function addApprovedRecipient(address recipient) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == address(this)) revert CannotBeSelf();
        if (recipientIndex[recipient] != 0) revert RecipientAlreadyApproved();
        approvedRecipients.push(recipient);
        recipientIndex[recipient] = approvedRecipients.length;
        emit RecipientApproved(recipient);
    }

    function removeApprovedRecipient(address recipient) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 idx = recipientIndex[recipient];
        if (idx == 0) revert RecipientNotApproved();
        if (idx != approvedRecipients.length) {
            approvedRecipients[idx - 1] = approvedRecipients[approvedRecipients.length - 1];
            recipientIndex[approvedRecipients[idx - 1]] = idx;
        }
        approvedRecipients.pop();
        delete recipientIndex[recipient];
        emit RecipientRevoked(recipient);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency sweep of an ERC-20 balance held by this issuer to the caller.
    ///         TokenIssuer intentionally does not accept native tokens (no `receive()`), so this
    ///         function only supports ERC-20 assets. Deliberately not gated by `whenNotPaused` —
    ///         emergency asset recovery must remain available while the issuer is paused (which
    ///         is the state right after an incident).
    function withdraw(address token) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (token == address(0)) revert ZeroAddress();
        address to = _msgSender();
        uint256 assetBalance = IERC20(token).balanceOf(address(this));
        if (assetBalance != 0) {
            IERC20(token).safeTransfer(to, assetBalance);
        }
        emit Withdrawn(token, to, assetBalance);
    }

    /// @notice Mints `amount` of `token` (this issuer must hold ISSUER_ROLE on it) and either
    ///         keeps the inventory on the issuer (recipient == self) or forwards to an approved
    ///         recipient.
    function mint(address token, address recipient, uint256 amount)
        external
        whenNotPaused
        onlyRole(OPS_ROLE)
        nonReentrant
    {
        if (recipient != address(this) && !isApprovedRecipient(recipient)) revert RecipientNotApproved();
        if (!IMintAndBurnable(token).mint(amount)) revert MintFailed();
        if (recipient != address(this)) {
            IERC20(token).safeTransfer(recipient, amount);
        }
        emit Minted(address(this), token, recipient, amount);
    }

    /// @notice Burns `amount` of `token` from this issuer (`from == self`) or from an approved
    ///         recipient that has pre-approved the issuer to pull tokens.
    function burn(address token, address from, uint256 amount)
        external
        whenNotPaused
        onlyRole(OPS_ROLE)
        nonReentrant
    {
        if (from != address(this) && !isApprovedRecipient(from)) revert FromNotApproved();
        if (from != address(this)) {
            IERC20(token).safeTransferFrom(from, address(this), amount);
        }
        if (!IMintAndBurnable(token).burn(amount)) revert BurnFailed();
        emit Burned(address(this), token, from, amount);
    }

    /// @notice Transfers `amount` of `token` already held by this issuer to an approved recipient.
    function transfer(address token, address recipient, uint256 amount)
        external
        whenNotPaused
        onlyRole(OPS_ROLE)
        nonReentrant
    {
        if (!isApprovedRecipient(recipient)) revert RecipientNotApproved();
        IERC20(token).safeTransfer(recipient, amount);
        emit Transferred(address(this), token, recipient, amount);
    }

    // ─── Privatization / delisting (方案二) ──────────────────────────────────────
    // A retired mStocks security (`oldToken`) is swapped, at a fixed per-share rate, for a
    // new mStocks token and/or USDC. This issuer already holds ISSUER_ROLE on the tokens it
    // manages, so it burns the surrendered old token and mints the new one on demand. The
    // fixed rate + a frozen old-token supply (`ScaledToken.setMintAllowed(false)`) mean no
    // record-date snapshot / Merkle / escrow is needed — see docs/corporate-actions-td.md §4.

    /// @notice Configure (or reconfigure) the privatization of `oldToken`. Admin-only: this
    ///         sets economic parameters, not an operational action. Requires at least one
    ///         consideration leg (stock or cash) with a non-zero rate. Operator must
    ///         separately: freeze the old token's supply, grant this issuer ISSUER_ROLE on
    ///         both `oldToken` and `newToken`, and fund this issuer with the owed USDC.
    function configurePrivatization(
        address oldToken,
        address newToken,
        address usdc,
        uint256 newRate,
        uint256 usdcRate,
        uint64 deadline
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oldToken == address(0)) revert ZeroAddress();
        bool hasStock = newToken != address(0) && newRate != 0;
        bool hasCash = usdc != address(0) && usdcRate != 0;
        if (!hasStock && !hasCash) revert NoConsiderationConfigured();
        privatizations[oldToken] = PrivatizationConfig({
            newToken: newToken,
            usdc: usdc,
            newRate: newRate,
            usdcRate: usdcRate,
            deadline: deadline,
            active: true
        });
        emit PrivatizationConfigured(oldToken, newToken, usdc, newRate, usdcRate, deadline);
    }

    /// @notice Close a privatization (stops further claims). Leftover USDC can be recovered
    ///         with {withdraw}.
    function closePrivatization(address oldToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        privatizations[oldToken].active = false;
        emit PrivatizationClosed(oldToken);
    }

    /// @notice Consideration for surrendering `oldAmount` (raw) of `oldToken`.
    function previewPrivatizationClaim(address oldToken, uint256 oldAmount)
        public
        view
        returns (uint256 newOut, uint256 usdcOut)
    {
        PrivatizationConfig memory cfg = privatizations[oldToken];
        newOut = cfg.newToken == address(0) ? 0 : Math.mulDiv(oldAmount, cfg.newRate, RATE_SCALE);
        usdcOut = cfg.usdc == address(0) ? 0 : Math.mulDiv(oldAmount, cfg.usdcRate, RATE_SCALE);
    }

    /// @notice Surrender `amount` (raw) of `oldToken` and receive the fixed-rate consideration.
    ///         Caller must `approve` this issuer for `amount` first. The old tokens are pulled
    ///         in and burned; the new token is minted on demand and USDC paid from inventory.
    ///         A compliance-blocked holder's new-token transfer reverts, rolling back the whole
    ///         claim — they keep the old token and can retry once unblocked (no escrow needed).
    function claimPrivatization(address oldToken, uint256 amount) external whenNotPaused nonReentrant {
        PrivatizationConfig memory cfg = privatizations[oldToken];
        if (!cfg.active) revert PrivatizationInactive();
        if (block.timestamp > cfg.deadline) revert PrivatizationClaimClosed();
        if (amount == 0) revert ZeroAmount();

        uint256 newOut = cfg.newToken == address(0) ? 0 : Math.mulDiv(amount, cfg.newRate, RATE_SCALE);
        uint256 usdcOut = cfg.usdc == address(0) ? 0 : Math.mulDiv(amount, cfg.usdcRate, RATE_SCALE);
        if (newOut == 0 && usdcOut == 0) revert NothingToDeliver();

        // Pull the old token in and burn it (this issuer holds ISSUER_ROLE on `oldToken`).
        IERC20(oldToken).safeTransferFrom(msg.sender, address(this), amount);
        if (!IMintAndBurnable(oldToken).burn(amount)) revert BurnFailed();

        // Deliver consideration: mint the new token on demand, pay USDC from inventory.
        if (newOut != 0) {
            if (!IMintAndBurnable(cfg.newToken).mint(newOut)) revert MintFailed();
            IERC20(cfg.newToken).safeTransfer(msg.sender, newOut);
        }
        if (usdcOut != 0) {
            IERC20(cfg.usdc).safeTransfer(msg.sender, usdcOut);
        }

        emit PrivatizationClaimed(oldToken, msg.sender, amount, newOut, usdcOut);
    }

    /// @notice Disallows self-grant — admin must delegate OPS_ROLE to a separate account.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

    /// @notice Blocks renouncing the final DEFAULT_ADMIN_ROLE holder, which would
    ///         permanently strip the contract of admin capability.
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

    /// @dev Storage gap for upgrade-safe additions. 3 vars (recipientIndex, approvedRecipients,
    ///      privatizations) + 47 = 50 slots reserved, matching the convention used by
    ///      ScaledToken / ERC8056Base / Guards. TokenIssuer is deployed behind a
    ///      TransparentUpgradeableProxy — upgrade authority lives on the auto-created
    ///      ProxyAdmin (owned by `cfg.proxyAdmin`), separate from `DEFAULT_ADMIN_ROLE`
    ///      (day-to-day ops).
    uint256[47] private __gap;
}
