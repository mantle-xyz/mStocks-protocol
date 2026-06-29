// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMintAndBurnable} from "./IMintAndBurnable.sol";

/**
 * @title  CexTokenIssuer
 * @notice Custodial wallet that holds ISSUER_ROLE on one or more SecuritiesToken contracts
 *         and routes minted tokens out to a whitelisted set of "hot wallets".
 *
 *         Role model (mirrors the rest of the protocol — strict separation of duties):
 *           - DEFAULT_ADMIN_ROLE (admin)
 *               ├── grantRole / revokeRole
 *               ├── addHotWallet / removeHotWallet
 *               ├── pause / unpause
 *               ├── withdraw (emergency funds recovery)
 *               └── execTransaction (governance escape hatch)
 *           - OPS_ROLE
 *               ├── mint     — mints token (caller must hold ISSUER_ROLE on token) and
 *               │             routes to a hot wallet (or keeps on this contract)
 *               └── transfer — sends tokens from this contract to a hot wallet
 *
 *         Self-grant guard: admin cannot grant any role to itself (forces a separate
 *         OPS_ROLE account).
 */
contract CexTokenIssuer is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// Role required on the security token for this wallet to mint / burn it.
    /// Must match SecuritiesToken.ISSUER_ROLE.
    bytes32 public constant TOKEN_ISSUER_ROLE = keccak256("ISSUER_ROLE");

    /// Maps a hot wallet address to its 1-based index in `hotWallets` (0 = not whitelisted).
    mapping(address => uint256) private hotWalletsMap;
    /// Enumerable hot wallet list.
    address[] public hotWallets;

    event HotWalletAdded(address indexed hotwallet);
    event HotWalletRemoved(address indexed hotwallet);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Executed(address indexed to, uint256 value, bytes data, bool success);

    /**
     * @notice Emitted on every successful mint routed through this wallet.
     * @param  wallet    This CexTokenIssuer (= the emitter; included explicitly so off-chain
     *                   aggregators that index multiple wallets can filter without inspecting
     *                   the log's emitter address)
     * @param  token     The security token contract that was minted
     * @param  recipient The address that received the freshly minted tokens (this wallet
     *                   itself, or a hot wallet from the whitelist)
     * @param  amount    Amount minted (raw, 18 decimals)
     */
    event Minted(
        address indexed wallet,
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    /**
     * @notice Emitted on every successful burn routed through this wallet.
     * @param  wallet This CexTokenIssuer (= the emitter; included for cross-wallet indexing)
     * @param  token  The security token contract that was burned
     * @param  from   The address whose tokens were burned — either this wallet itself (when
     *                burning held inventory) or a hot wallet that pre-approved the wallet
     * @param  amount Amount burned (raw, 18 decimals)
     */
    event Burned(
        address indexed wallet,
        address indexed token,
        address indexed from,
        uint256 amount
    );

    error ZeroAddress();
    error HotWalletAlreadyExists();
    error HotWalletNotFound();
    error CannotBeSelf();
    error RecipientNotHotWallet();
    error FromNotHotWallet();
    error MintFailed();
    error BurnFailed();
    /// This wallet does not hold ISSUER_ROLE on the target token, so it cannot mint or
    /// burn. Caught explicitly so the failure surfaces before any tokens are moved.
    error MissingIssuerRole();
    error SelfGrantNotAllowed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /**
     * @param admin Address that receives DEFAULT_ADMIN_ROLE. Must be non-zero.
     */
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        __Pausable_init();
        // ReentrancyGuard (v5) uses ERC-7201 namespaced storage and needs no initializer.

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
    }

    // ═══════════════════════════════════════════════
    //                       Views
    // ═══════════════════════════════════════════════

    function isHotWallet(address account) public view returns (bool) {
        return hotWalletsMap[account] > 0;
    }

    function numOfHotWallets() external view returns (uint256) {
        return hotWallets.length;
    }

    // ═══════════════════════════════════════════════
    //              Admin — hot wallet mgmt
    // ═══════════════════════════════════════════════

    function addHotWallet(address hotwallet) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hotwallet == address(0)) revert ZeroAddress();
        if (hotWalletsMap[hotwallet] != 0) revert HotWalletAlreadyExists();
        if (hotwallet == address(this)) revert CannotBeSelf();
        hotWallets.push(hotwallet);
        hotWalletsMap[hotwallet] = hotWallets.length;
        emit HotWalletAdded(hotwallet);
    }

    function removeHotWallet(address hotwallet) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hotwallet == address(0)) revert ZeroAddress();
        if (hotWalletsMap[hotwallet] == 0) revert HotWalletNotFound();
        uint256 idx = hotWalletsMap[hotwallet];
        if (idx != hotWallets.length) {
            hotWallets[idx - 1] = hotWallets[hotWallets.length - 1];
            hotWalletsMap[hotWallets[idx - 1]] = idx;
        }
        hotWallets.pop();
        delete hotWalletsMap[hotwallet];
        emit HotWalletRemoved(hotwallet);
    }

    // ═══════════════════════════════════════════════
    //               Admin — emergency
    // ═══════════════════════════════════════════════

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Withdraw native (token == address(0)) or ERC20 to the caller.
     *         Emergency / sweep utility — restricted to admin.
     */
    function withdraw(address token) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 assetBalance;
        address to = _msgSender();
        if (token == address(0)) {
            assetBalance = address(this).balance;
            if (assetBalance != 0) {
                (bool ok,) = payable(to).call{value: assetBalance}("");
                require(ok, "CexTokenIssuer: native withdraw failed");
            }
        } else {
            assetBalance = IERC20(token).balanceOf(address(this));
            if (assetBalance != 0) {
                IERC20(token).safeTransfer(to, assetBalance);
            }
        }
        emit Withdrawn(token, to, assetBalance);
    }


    // ═══════════════════════════════════════════════
    //                  OPS — operations
    // ═══════════════════════════════════════════════

    /**
     * @notice Mint `amount` of `token` (this wallet must hold ISSUER_ROLE on it) and
     *         either keep on this wallet (recipient == self) or forward to a hot wallet.
     */
    function mint(address token, address recipient, uint256 amount)
        external
        whenNotPaused
        onlyRole(OPS_ROLE)
        nonReentrant
    {
        if (recipient != address(this) && !isHotWallet(recipient)) revert RecipientNotHotWallet();
        _requireIssuerRole(token);
        if (!IMintAndBurnable(token).mint(amount)) revert MintFailed();
        if (recipient != address(this)) {
            IERC20(token).safeTransfer(recipient, amount);
        }
        emit Minted(address(this), token, recipient, amount);
    }

    function burn(address token, address from, uint256 amount)
        external
        whenNotPaused
        onlyRole(OPS_ROLE)
        nonReentrant
    {
        if (from != address(this) && !isHotWallet(from)) revert FromNotHotWallet();
        _requireIssuerRole(token);
        if (from != address(this)) {
            IERC20(token).safeTransferFrom(from, address(this), amount);
        }
        if (!IMintAndBurnable(token).burn(amount)) revert BurnFailed();
        emit Burned(address(this), token, from, amount);
    }

    /// Reverts with {MissingIssuerRole} if this wallet is not authorised to mint/burn
    /// the given security token. Pre-flight check so the failure happens before any
    /// tokens are pulled in (cheaper / cleaner trace than letting the token's mint/burn
    /// revert later with a generic UnauthorizedRole).
    function _requireIssuerRole(address token) internal view {
        if (!IAccessControl(token).hasRole(TOKEN_ISSUER_ROLE, address(this))) {
            revert MissingIssuerRole();
        }
    }

    /// Transfer `amount` of `token` already held by this wallet to a hot wallet.
    function transfer(address token, address recipient, uint256 amount)
        external
        whenNotPaused
        onlyRole(OPS_ROLE)
        nonReentrant
    {
        if (!isHotWallet(recipient)) revert RecipientNotHotWallet();
        IERC20(token).safeTransfer(recipient, amount);
    }

    // ═══════════════════════════════════════════════
    //                Role-grant guard
    // ═══════════════════════════════════════════════

    /**
     * @notice Disallows self-grant — admin must delegate OPS_ROLE to a separate account.
     * @dev    Internal `_grantRole` is NOT overridden, so the initializer can still seed
     *         the admin with DEFAULT_ADMIN_ROLE.
     */
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

    /// Reserved storage gap for upgradeable storage layout.
    uint256[47] private __gap;
}
