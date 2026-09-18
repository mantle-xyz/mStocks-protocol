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

import {PrivatizationRegistry} from "./PrivatizationRegistry.sol";

/// @notice Custody router that lets CEX hot wallets participate in a privatization claim — see
///         docs/corporate-actions-td.md §5.1.
///
///         A CEX hot wallet, for compliance, can only `transfer` — it cannot call arbitrary
///         contracts (not even `approve`). So it cannot drive `PrivatizationRegistry.claim`
///         itself. This router bridges that gap:
///
///           1. hot wallet `oldToken.transfer(router, amount)` — a plain ERC-20 transfer.
///           2. an `OPS_ROLE` operator, reconciling against the CEX's / on-chain transfer log,
///              calls `claimFor(programId, hotWallet, amount)`.
///           3. the router claims from the registry with its OWN balance (approve + claim; the
///              registry pulls + burns the old token and pays the basket back to the router),
///              then — in the same transaction — forwards the whole basket to `hotWallet`.
///
///         Trust is bounded on every axis:
///           - **Hot-wallet allowlist**: `claimFor` only ever pays a `registerHotWallet`-ed
///             address, so funds can never be routed to an arbitrary address.
///           - **Duty separation**: the allowlist is `DEFAULT_ADMIN_ROLE`; only claim *triggering*
///             is `OPS_ROLE`. A leaked OPS key can neither add a hot wallet nor pay a non-listed
///             one, so it cannot exfiltrate anything.
///           - **Amount ceiling**: a claim can only consume old tokens the router actually holds
///             (the registry's `transferFrom` reverts otherwise), so OPS cannot conjure amounts.
///           - **Atomic**: claim + forward happen in one `nonReentrant` call; the basket never
///             lingers in the router.
///
///         `rescue` lets the admin recover assets that were transferred in but not (yet) claimed,
///         or anything sent here by mistake.
///
///         Upgradeable: deployed behind a TransparentUpgradeableProxy (like {PrivatizationRegistry}
///         / {TokenIssuer}); upgrade authority lives on the auto-created ProxyAdmin, separate from
///         DEFAULT_ADMIN_ROLE.
contract CustodyClaimRouter is Initializable, AccessControlEnumerableUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// @notice The privatization registry this router claims against. Set once at {initialize};
    ///         one router (deployment) per registry.
    PrivatizationRegistry public registry;

    /// @notice Admin-maintained allowlist of legitimate CEX hot wallets. `claimFor` refuses to pay
    ///         anyone not on it.
    mapping(address => bool) public isHotWallet;

    event HotWalletRegistered(address indexed hotWallet);
    event HotWalletDeregistered(address indexed hotWallet);
    event ClaimedFor(uint256 indexed programId, address indexed hotWallet, address indexed caller, uint256 oldAmount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotRegisteredHotWallet();
    error UnknownProgram();
    error NothingForwarded();
    error SelfGrantNotAllowed();
    error CannotRenounceLastAdmin();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param ops Initial OPS_ROLE holders (may be empty — grant later via {grantRole}), matching
    ///        the pattern {ScaledToken.initialize} already uses for its own opsRoles_.
    function initialize(address registry_, address admin, address[] calldata ops) external initializer {
        if (registry_ == address(0) || admin == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        // ReentrancyGuardTransient (EIP-1153 TSTORE) uses transient storage — no initializer needed.
        registry = PrivatizationRegistry(registry_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
        for (uint256 i = 0; i < ops.length; ++i) {
            if (ops[i] == address(0)) revert ZeroAddress();
            _grantRole(OPS_ROLE, ops[i]);
        }
    }

    // ── hot-wallet allowlist (admin) ────────────────────────────────────────────

    /// @notice Add a hot wallet to the allowlist. Admin-only (more sensitive than triggering a
    ///         claim, hence separated from OPS_ROLE).
    function registerHotWallet(address hotWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hotWallet == address(0)) revert ZeroAddress();
        isHotWallet[hotWallet] = true;
        emit HotWalletRegistered(hotWallet);
    }

    /// @notice Batch variant of {registerHotWallet}.
    function registerHotWallets(address[] calldata hotWallets) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < hotWallets.length; ++i) {
            if (hotWallets[i] == address(0)) revert ZeroAddress();
            isHotWallet[hotWallets[i]] = true;
            emit HotWalletRegistered(hotWallets[i]);
        }
    }

    function deregisterHotWallet(address hotWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isHotWallet[hotWallet] = false;
        emit HotWalletDeregistered(hotWallet);
    }

    // ── claim on behalf of a hot wallet (OPS) ────────────────────────────────────

    /// @notice Claim `amount` of a program's old token — already sitting in this router because
    ///         `hotWallet` transferred it in — and forward the whole reward basket back to
    ///         `hotWallet`, atomically. OPS-only; `hotWallet` must be allowlisted.
    function claimFor(uint256 programId, address hotWallet, uint256 amount) external onlyRole(OPS_ROLE) nonReentrant {
        if (!isHotWallet[hotWallet]) revert NotRegisteredHotWallet();
        if (amount == 0) revert ZeroAmount();

        (address oldToken,,,, uint8 state) = registry.programs(programId);
        if (state == 0) revert UnknownProgram(); // State.None — program id never created

        // Snapshot each DISTINCT reward-leg token's balance before the claim, so we can forward
        // exactly what arrives (self-correcting against dust legs / repeated tokens).
        uint256 n = registry.legsCount(programId);
        address[] memory tokens = new address[](n);
        uint256[] memory balBefore = new uint256[](n);
        uint256 uniq;
        for (uint256 i = 0; i < n; ++i) {
            address t = registry.legAt(programId, i).token;
            bool seen;
            for (uint256 j = 0; j < uniq; ++j) {
                if (tokens[j] == t) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                tokens[uniq] = t;
                balBefore[uniq] = IERC20(t).balanceOf(address(this));
                ++uniq;
            }
        }

        // Claim with the router's own old-token balance: registry pulls + burns, pays basket here.
        IERC20(oldToken).forceApprove(address(registry), amount);
        registry.claim(programId, amount);

        // Forward each leg token's delta to the hot wallet, in the same transaction.
        bool forwarded;
        for (uint256 k = 0; k < uniq; ++k) {
            uint256 delta = IERC20(tokens[k]).balanceOf(address(this)) - balBefore[k];
            if (delta > 0) {
                IERC20(tokens[k]).safeTransfer(hotWallet, delta);
                forwarded = true;
            }
        }
        if (!forwarded) revert NothingForwarded();

        emit ClaimedFor(programId, hotWallet, msg.sender, amount);
    }

    // ── admin rescue ─────────────────────────────────────────────────────────────

    /// @notice Recover `amount` of `token` from the router (e.g. a hot wallet transferred in but
    ///         the claim was never driven, or an unrelated asset was sent here by mistake).
    function rescue(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ── role guards (repo convention) ────────────────────────────────────────────

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

    /// @dev Storage gap for upgrade-safe additions. 2 vars (registry, isHotWallet) + 48 = 50 slots.
    uint256[48] private __gap;
}
