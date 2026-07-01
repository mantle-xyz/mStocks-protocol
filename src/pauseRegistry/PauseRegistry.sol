// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IPauseRegistry} from "./IPauseRegistry.sol";

/// @notice Per-token and global pause switches consulted by token transfer hooks.
///         OPS_ROLE flips switches; admin only grants the role (separation of duties).
contract PauseRegistry is IPauseRegistry, AccessControlEnumerable {
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// @notice token => paused.
    mapping(address => bool) public pausedTokens;

    /// @notice Global kill-switch; when true every token reports as paused.
    bool public globalPaused;

    event TokenPaused(address indexed token, address indexed pauser);
    event TokenUnpaused(address indexed token, address indexed unpauser);
    event GlobalPaused(address indexed pauser);
    event GlobalUnpaused(address indexed unpauser);

    error MissingOpsRole();
    error ZeroAddress();
    error SelfGrantNotAllowed();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
    }

    modifier onlyOps() {
        _requireOps();
        _;
    }

    function _requireOps() private view {
        if (!hasRole(OPS_ROLE, _msgSender())) revert MissingOpsRole();
    }

    function pauseToken(address token) external onlyOps {
        pausedTokens[token] = true;
        emit TokenPaused(token, msg.sender);
    }

    function unpauseToken(address token) external onlyOps {
        pausedTokens[token] = false;
        emit TokenUnpaused(token, msg.sender);
    }

    function pauseGlobally() external onlyOps {
        globalPaused = true;
        emit GlobalPaused(msg.sender);
    }

    function unpauseGlobally() external onlyOps {
        globalPaused = false;
        emit GlobalUnpaused(msg.sender);
    }

    /// @notice True if `_token` is individually paused or the global switch is on.
    function isTokenPaused(address _token) external view override returns (bool) {
        return pausedTokens[_token] || globalPaused;
    }

    /// @notice Disallows self-grant — admin must delegate OPS_ROLE to a separate account.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControl, IAccessControl)
    {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }
}
