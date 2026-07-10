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

    /// @dev recipient => 1-based index in `approvedRecipients`. 0 means "not approved".
    mapping(address => uint256) private recipientIndex;
    /// @notice Enumerable whitelist of mint/burn counterparties.
    address[] public approvedRecipients;

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

    error ZeroAddress();
    error RecipientAlreadyApproved();
    error RecipientNotApproved();
    error CannotBeSelf();
    error FromNotApproved();
    error MintFailed();
    error BurnFailed();
    error SelfGrantNotAllowed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

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

    /// @notice Emergency sweep of native (`token == address(0)`) or ERC-20 balance to the caller.
    function withdraw(address token) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 assetBalance;
        address to = _msgSender();
        if (token == address(0)) {
            assetBalance = address(this).balance;
            if (assetBalance != 0) {
                (bool ok,) = payable(to).call{value: assetBalance}("");
                require(ok, "TokenIssuer: native withdraw failed");
            }
        } else {
            assetBalance = IERC20(token).balanceOf(address(this));
            if (assetBalance != 0) {
                IERC20(token).safeTransfer(to, assetBalance);
            }
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

    /// @dev Storage gap for upgrade-safe additions. 2 vars (recipientIndex, approvedRecipients)
    ///      + 48 = 50 slots reserved, matching the convention used by ScaledToken / ERC8056Base
    ///      / Guards. TokenIssuer is deployed behind a TransparentUpgradeableProxy — upgrade
    ///      authority lives on the auto-created ProxyAdmin (owned by `cfg.proxyAdmin`),
    ///      separate from `DEFAULT_ADMIN_ROLE` (day-to-day ops).
    uint256[48] private __gap;
}
