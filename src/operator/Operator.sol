// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Minimal interface for the mint/burn side of SecuritiesToken — both operate on caller.
interface ISecuritiesTokenMintBurn {
    function mint(uint256 amount) external returns (bool);
    function burn(uint256 amount) external returns (bool);
}

/**
 * @title  Operator
 * @notice Off-ramp helper for fiat-on-ramp / brokerage flows. An OPS_ROLE account, acting
 *         on behalf of a user who has approved this contract for a stablecoin, atomically:
 *           1. pulls `stableAmount` of the approved stablecoin from `user` to `treasury`;
 *           2. mints `tokenAmount` of the security token (this contract must hold the
 *              token's ISSUER_ROLE — minted tokens land in this contract);
 *           3. transfers the freshly-minted tokens to `user`.
 *
 *         If any step reverts (insufficient approval / paused token / blocked user),
 *         the entire purchase reverts — no partial state changes.
 *
 *         Role hierarchy:
 *           - DEFAULT_ADMIN_ROLE  → configures treasury / stable whitelist / token whitelist
 *           - OPS_ROLE            → calls purchase() on behalf of approved users
 *
 *         Self-grant guard: an admin cannot grant any role to itself, forcing operational
 *         duties to be delegated to a separate account.
 */
contract Operator is AccessControlEnumerable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// Role required on the security token for Operator to mint / burn it.
    /// Must match SecuritiesToken.ISSUER_ROLE.
    bytes32 public constant TOKEN_ISSUER_ROLE = keccak256("ISSUER_ROLE");

    /// Destination address for pulled stablecoins.
    address public treasury;

    /// Whitelisted stablecoin contracts (USDC / USDT / etc.).
    mapping(address => bool) public approvedStable;

    /// Whitelisted security token contracts that this Operator can mint.
    mapping(address => bool) public approvedToken;

    // ─── Events ───

    event Purchased(
        address indexed user,
        address indexed stable,
        uint256 stableAmount,
        address indexed token,
        uint256 tokenAmount,
        address operator
    );
    event Sold(
        address indexed user,
        address indexed token,
        uint256 tokenAmount,
        address indexed stable,
        uint256 stableAmount,
        address operator
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event StableApprovalSet(address indexed stable, bool approved);
    event TokenApprovalSet(address indexed token, bool approved);

    // ─── Errors ───

    /// Caller attempted to grant a role to itself (separation-of-duties).
    error SelfGrantNotAllowed();

    /// The provided stablecoin is not on the whitelist.
    error NotApprovedStable();

    /// The provided security token is not on the whitelist.
    error NotApprovedToken();

    /// A zero address was passed where one is not allowed.
    error ZeroAddress();

    /// A zero amount was passed.
    error ZeroAmount();

    /// Treasury has not been configured yet.
    error TreasuryNotSet();

    /// The token's mint() returned false (unexpected — wrapping for clarity).
    error MintFailed();

    /// The token's burn() returned false (unexpected — wrapping for clarity).
    error BurnFailed();

    /// This Operator does not hold ISSUER_ROLE on the target token, so it cannot
    /// mint or burn. Caught explicitly so the failure surfaces before any user funds
    /// are moved.
    error MissingIssuerRole();

    /**
     * @param admin     Address that receives DEFAULT_ADMIN_ROLE.
     * @param _treasury Destination for pulled stablecoins. May be set later via setTreasury;
     *                  pass address(0) to defer the decision.
     */
    constructor(address admin, address _treasury) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
        if (_treasury != address(0)) {
            treasury = _treasury;
            emit TreasuryUpdated(address(0), _treasury);
        }
    }

    // ═══════════════════════════════════════════════
    //                  Admin
    // ═══════════════════════════════════════════════

    /// Updates the destination address for pulled stablecoins.
    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    /// Adds / removes a stablecoin contract from the whitelist.
    function setApprovedStable(address stable, bool approved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (stable == address(0)) revert ZeroAddress();
        approvedStable[stable] = approved;
        emit StableApprovalSet(stable, approved);
    }

    /// Adds / removes a security-token contract from the whitelist. The Operator must
    /// separately be granted ISSUER_ROLE on that token by the token's admin before it
    /// can actually mint.
    function setApprovedToken(address token, bool approved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        approvedToken[token] = approved;
        emit TokenApprovalSet(token, approved);
    }

    // ═══════════════════════════════════════════════
    //                  OPS
    // ═══════════════════════════════════════════════

    /**
     * @notice Atomically pull `stableAmount` from `user` to treasury and mint `tokenAmount`
     *         of `token` to `user`.
     *
     *         Pre-requisites (checked by the relevant external contracts, not re-checked here):
     *           - user has called stable.approve(operator, ≥ stableAmount)
     *           - this Operator contract holds ISSUER_ROLE on `token`
     *           - `token` is not paused; `user` is not blocked/sanctioned for `token`
     *
     *         Reverts atomically if any step fails — no partial state changes.
     *
     * @param user         End-user paying the stablecoin and receiving the token.
     * @param stable       Whitelisted stablecoin contract.
     * @param stableAmount Amount of stable to pull (in the stablecoin's own decimals).
     * @param token        Whitelisted security-token contract.
     * @param tokenAmount  Amount of security token to mint to the user (18 decimals).
     */
    function purchase(
        address user,
        address stable,
        uint256 stableAmount,
        address token,
        uint256 tokenAmount
    ) external onlyRole(OPS_ROLE) nonReentrant returns (bool) {
        if (user == address(0)) revert ZeroAddress();
        if (stableAmount == 0 || tokenAmount == 0) revert ZeroAmount();
        if (!approvedStable[stable]) revert NotApprovedStable();
        if (!approvedToken[token]) revert NotApprovedToken();
        if (treasury == address(0)) revert TreasuryNotSet();
        _requireIssuerRole(token);

        // 1. Pull stable from user → treasury (will revert if approval / balance insufficient).
        IERC20(stable).safeTransferFrom(user, treasury, stableAmount);

        // 2. Mint security token. mint() mints to caller, so tokens land in this contract.
        if (!ISecuritiesTokenMintBurn(token).mint(tokenAmount)) revert MintFailed();

        // 3. Forward the freshly minted tokens to the user. Compliance / pause checks in
        //    the token's _update hook still apply — if user is blocked, this reverts and
        //    the whole tx unwinds.
        IERC20(token).safeTransfer(user, tokenAmount);

        emit Purchased(user, stable, stableAmount, token, tokenAmount, _msgSender());
        return true;
    }

    /**
     * @notice Reverse of purchase — atomically burn `tokenAmount` from `user` and pay
     *         `stableAmount` of `stable` from treasury to `user`.
     *
     *         Pre-requisites:
     *           - user has called token.approve(operator, ≥ tokenAmount)
     *           - treasury has called stable.approve(operator, ≥ stableAmount)
     *           - this Operator contract holds ISSUER_ROLE on `token`
     *           - `token` is not paused; `user` is not blocked/sanctioned for `token`
     *           - token.burnEnabled() is true
     *
     *         Reverts atomically if any step fails — no partial state changes.
     *
     * @param user         End-user redeeming the token and receiving the stable.
     * @param token        Whitelisted security-token contract.
     * @param tokenAmount  Amount of security token to burn (18 decimals).
     * @param stable       Whitelisted stablecoin contract.
     * @param stableAmount Amount of stable to pay out (in the stablecoin's own decimals).
     */
    function sell(
        address user,
        address token,
        uint256 tokenAmount,
        address stable,
        uint256 stableAmount
    ) external onlyRole(OPS_ROLE) nonReentrant returns (bool) {
        if (user == address(0)) revert ZeroAddress();
        if (tokenAmount == 0 || stableAmount == 0) revert ZeroAmount();
        if (!approvedToken[token]) revert NotApprovedToken();
        if (!approvedStable[stable]) revert NotApprovedStable();
        if (treasury == address(0)) revert TreasuryNotSet();
        _requireIssuerRole(token);

        // 1. Pull token from user → operator. Token's _update hook runs compliance + pause
        //    checks, so a blocked user / paused token reverts here.
        IERC20(token).safeTransferFrom(user, address(this), tokenAmount);

        // 2. Burn the security token (operator must hold ISSUER_ROLE on it).
        if (!ISecuritiesTokenMintBurn(token).burn(tokenAmount)) revert BurnFailed();

        // 3. Pay out stable from treasury → user. Treasury must have pre-approved this
        //    Operator for the stablecoin.
        IERC20(stable).safeTransferFrom(treasury, user, stableAmount);

        emit Sold(user, token, tokenAmount, stable, stableAmount, _msgSender());
        return true;
    }

    // ═══════════════════════════════════════════════
    //                  Internal helpers
    // ═══════════════════════════════════════════════

    /// Reverts with {MissingIssuerRole} if this contract is not authorised to mint/burn
    /// the given security token. Pre-flight check so the failure happens before any
    /// user-funds are moved (cheaper / less confusing than letting mint() / burn() revert
    /// later with a generic UnauthorizedRole from the token).
    function _requireIssuerRole(address token) internal view {
        if (!IAccessControl(token).hasRole(TOKEN_ISSUER_ROLE, address(this))) {
            revert MissingIssuerRole();
        }
    }

    // ═══════════════════════════════════════════════
    //                  Role-grant guard
    // ═══════════════════════════════════════════════

    /**
     * @notice Disallows self-grant — admin must delegate OPS_ROLE to a separate account.
     * @dev    Internal `_grantRole` is NOT overridden, so the constructor can still seed
     *         the admin with DEFAULT_ADMIN_ROLE.
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
