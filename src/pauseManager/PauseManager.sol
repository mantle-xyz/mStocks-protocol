// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import "./IPauseManager.sol";

/**
 * @title  PauseManager
 * @notice Manages pause states for token contracts.
 *
 *         Role hierarchy:
 *          - DEFAULT_ADMIN_ROLE (Owner)
 *              ├── Manages grant/revoke of all roles
 *              └── pause/unpause
 *          - OPS_ROLE
 *              └── pause/unpause
 */
contract PauseManager is IPauseManager, AccessControlEnumerable {
    /// Operational role for day-to-day management
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// Tracks paused state of individual tokens
    mapping(address => bool) public pausedTokens;

    /// Tracks global paused state for all tokens
    bool public allTokensPaused;

    /**
     * @notice Emitted when a token is paused
     * @param  token  The address of the paused token
     * @param  pauser The address that initiated the pause
     */
    event TokenPaused(address indexed token, address indexed pauser);

    /**
     * @notice Emitted when a token is unpaused
     * @param  token    The address of the unpaused token
     * @param  unpauser The address that initiated the unpause
     */
    event TokenUnpaused(address indexed token, address indexed unpauser);

    /**
     * @notice Emitted when all tokens are paused
     * @param  pauser The address that initiated the pause
     */
    event AllTokensPaused(address indexed pauser);

    /**
     * @notice Emitted when all tokens are unpaused
     * @param  unpauser The address that initiated the unpause
     */
    event AllTokensUnpaused(address indexed unpauser);

    /// Error thrown when caller lacks a pause management role
    error MissingPauseRole();

    /// Error thrown when the admin address is zero
    error ZeroAddress();

    /// Error thrown when an account attempts to grant a role to itself
    error SelfGrantNotAllowed();

    /**
     * @param admin The address which will be granted the default admin role
     */
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
    }

    /**
     * @notice Modifier that restricts access to pause management roles
     * @dev    Allows DEFAULT_ADMIN_ROLE or OPS_ROLE
     */
    modifier onlyPauseRole() {
        _checkPauseRole();
        _;
    }

    function _checkPauseRole() private view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !hasRole(OPS_ROLE, _msgSender())) {
            revert MissingPauseRole();
        }
    }

    /**
     * @notice Pauses a token
     * @param  token The address of the token to pause
     * @dev    Callable by DEFAULT_ADMIN_ROLE or OPS_ROLE
     */
    function pauseToken(address token) external onlyPauseRole {
        pausedTokens[token] = true;
        emit TokenPaused(token, msg.sender);
    }

    /**
     * @notice Unpauses a token
     * @param  token The address of the token to unpause
     * @dev    Callable by DEFAULT_ADMIN_ROLE or OPS_ROLE
     */
    function unpauseToken(address token) external onlyPauseRole {
        pausedTokens[token] = false;
        emit TokenUnpaused(token, msg.sender);
    }

    /**
     * @notice Pauses all tokens
     * @dev    Callable by DEFAULT_ADMIN_ROLE or OPS_ROLE
     */
    function pauseAllTokens() external onlyPauseRole {
        allTokensPaused = true;
        emit AllTokensPaused(msg.sender);
    }

    /**
     * @notice Unpauses all tokens
     * @dev    Callable by DEFAULT_ADMIN_ROLE or OPS_ROLE
     */
    function unpauseAllTokens() external onlyPauseRole {
        allTokensPaused = false;
        emit AllTokensUnpaused(msg.sender);
    }

    /**
     * @notice Checks if a specific token is paused
     * @param  _token The address of the token to check
     * @return True if the token is paused, false otherwise
     * @dev    Returns true if the specific token is paused or if all tokens are paused
     */
    function isTokenPaused(address _token) external view override returns (bool) {
        return pausedTokens[_token] || allTokensPaused;
    }

    /**
     * @notice Grants `role` to `account`, with an extra constraint: the caller cannot
     *         grant any role to itself. Forces separation of duties — admin must
     *         delegate OPS_ROLE to a different account.
     * @dev    Internal `_grantRole` is NOT overridden, so the constructor can still
     *         seed the admin with DEFAULT_ADMIN_ROLE.
     */
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControl, IAccessControl)
    {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }
}
