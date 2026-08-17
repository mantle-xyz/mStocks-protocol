// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IPauseRegistry} from "./IPauseRegistry.sol";

/// @notice Per-token and global pause switches consulted by token transfer hooks.
///         PAUSE_ROLE pauses, UNPAUSE_ROLE unpauses; admin only grants the roles
///         (separation of duties — pausing and unpausing are split).
contract PauseRegistry is IPauseRegistry, AccessControlEnumerable {
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant UNPAUSE_ROLE = keccak256("UNPAUSE_ROLE");

    /// @notice token => paused.
    mapping(address => bool) public pausedTokens;

    /// @notice Global kill-switch; when true every token reports as paused.
    bool public globalPaused;

    event TokenPaused(address indexed token, address indexed pauser);
    event TokenUnpaused(address indexed token, address indexed unpauser);
    event GlobalPaused(address indexed pauser);
    event GlobalUnpaused(address indexed unpauser);

    error MissingPauseRole();
    error MissingUnpauseRole();
    error ZeroAddress();
    error SelfGrantNotAllowed();
    error TokenAlreadyPaused();
    error TokenNotPaused();
    error AlreadyGloballyPaused();
    error NotGloballyPaused();
    error CannotRenounceLastAdmin();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(PAUSE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(UNPAUSE_ROLE, DEFAULT_ADMIN_ROLE);
    }

    modifier onlyPauser() {
        if (!hasRole(PAUSE_ROLE, _msgSender())) revert MissingPauseRole();
        _;
    }

    modifier onlyUnpauser() {
        if (!hasRole(UNPAUSE_ROLE, _msgSender())) revert MissingUnpauseRole();
        _;
    }

    function pauseToken(address token) external onlyPauser {
        if (pausedTokens[token]) revert TokenAlreadyPaused();
        pausedTokens[token] = true;
        emit TokenPaused(token, msg.sender);
    }

    function unpauseToken(address token) external onlyUnpauser {
        if (!pausedTokens[token]) revert TokenNotPaused();
        pausedTokens[token] = false;
        emit TokenUnpaused(token, msg.sender);
    }

    function pauseGlobally() external onlyPauser {
        if (globalPaused) revert AlreadyGloballyPaused();
        globalPaused = true;
        emit GlobalPaused(msg.sender);
    }

    function unpauseGlobally() external onlyUnpauser {
        if (!globalPaused) revert NotGloballyPaused();
        globalPaused = false;
        emit GlobalUnpaused(msg.sender);
    }

    /// @notice True if `_token` is individually paused or the global switch is on.
    function isTokenPaused(address _token) external view override returns (bool) {
        return pausedTokens[_token] || globalPaused;
    }

    /// @notice Disallows self-grant — admin must delegate PAUSE_ROLE / UNPAUSE_ROLE to separate accounts.
    function grantRole(bytes32 role, address account) public virtual override(AccessControl, IAccessControl) {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

    /// @notice Blocks renouncing the final DEFAULT_ADMIN_ROLE holder, which would
    ///         permanently strip this non-upgradeable contract of admin capability.
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
