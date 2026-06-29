// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// Minimal interface for the mint/burn side of SecuritiesToken — both operate on caller.
interface ISecuritiesTokenMintBurn {
    function mint(uint256 amount) external returns (bool);
    function burn(uint256 amount) external returns (bool);
}

/**
 * @title  DexTokenIssuer
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
contract DexTokenIssuer is AccessControlEnumerable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// Role held by the brokerage backend(s) that sign off on individual trades. The
    /// broker_admin commits to the order terms (price, disclosure, etc.) off-chain;
    /// the on-chain OPS_ROLE then submits the signed order to be executed.
    bytes32 public constant BROKER_ADMIN_ROLE = keccak256("BROKER_ADMIN_ROLE");

    /// Role required on the security token for DexTokenIssuer to mint / burn it.
    /// Must match SecuritiesToken.ISSUER_ROLE.
    bytes32 public constant TOKEN_ISSUER_ROLE = keccak256("ISSUER_ROLE");

    // ─── EIP-712 typed-data structs (off-chain signed by BROKER_ADMIN_ROLE) ───

    struct PurchaseOrder {
        address user;            // end-user being served
        address stable;          // payment stablecoin (must be whitelisted)
        uint256 stableAmount;
        address token;           // security token to buy (must be whitelisted)
        uint256 tokenAmount;
        bytes32 disclosureHash;  // committed disclosure document hash (off-chain audit)
        uint256 nonce;           // must match user's current orderNonces value
        uint256 deadline;        // unix timestamp after which the order is no longer valid
    }

    struct SellOrder {
        address user;
        address token;
        uint256 tokenAmount;
        address stable;
        uint256 stableAmount;
        bytes32 disclosureHash;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 private constant PURCHASE_ORDER_TYPEHASH = keccak256(
        "PurchaseOrder(address user,address stable,uint256 stableAmount,address token,uint256 tokenAmount,bytes32 disclosureHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant SELL_ORDER_TYPEHASH = keccak256(
        "SellOrder(address user,address token,uint256 tokenAmount,address stable,uint256 stableAmount,bytes32 disclosureHash,uint256 nonce,uint256 deadline)"
    );

    /// Per-user monotonic order nonce — orders signed by broker_admin must include the
    /// user's current value to be valid. Consumed (incremented) on every successful fill.
    mapping(address => uint256) public orderNonces;

    /// Destination address for pulled stablecoins.
    address public treasury;

    /// Whitelisted stablecoin contracts (USDC / USDT / etc.).
    mapping(address => bool) public approvedStable;

    /// Whitelisted security token contracts that this DexTokenIssuer can mint.
    mapping(address => bool) public approvedToken;

    // ─── Events ───

    /**
     * @notice Emitted on every successful purchase (broker-signed order).
     * @param  operator       This DexTokenIssuer contract (= the emitter; included explicitly so
     *                        off-chain aggregators that index multiple DexTokenIssuers can
     *                        filter without inspecting the log's emitter address).
     * @param  user           End user who paid stable and received the security token.
     * @param  token          Security token that was minted.
     * @param  stable         Stablecoin pulled from the user.
     * @param  stableAmount   Amount of stable pulled.
     * @param  tokenAmount    Amount of security token minted to the user.
     * @param  disclosureHash Committed disclosure document hash from the order.
     * @param  nonce          Order nonce consumed.
     * @param  brokerAdmin    Address holding BROKER_ADMIN_ROLE whose signature authorised the order.
     */
    event Purchased(
        address indexed operator,
        address indexed user,
        address indexed token,
        address stable,
        uint256 stableAmount,
        uint256 tokenAmount,
        bytes32 disclosureHash,
        uint256 nonce,
        address brokerAdmin
    );

    /**
     * @notice Emitted on every successful sell (broker-signed order). Symmetric to {Purchased}.
     */
    event Sold(
        address indexed operator,
        address indexed user,
        address indexed token,
        address stable,
        uint256 tokenAmount,
        uint256 stableAmount,
        bytes32 disclosureHash,
        uint256 nonce,
        address brokerAdmin
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

    /// This DexTokenIssuer does not hold ISSUER_ROLE on the target token, so it cannot
    /// mint or burn. Caught explicitly so the failure surfaces before any user funds
    /// are moved.
    error MissingIssuerRole();

    /// Order deadline has passed (block.timestamp > order.deadline).
    error OrderExpired();

    /// Order nonce does not match the user's current orderNonces value (out of sync,
    /// replay, or front-run).
    error OrderNonceMismatch(uint256 expected, uint256 provided);

    /// Recovered signer of the order does not hold BROKER_ADMIN_ROLE.
    error InvalidBrokerSignature();

    /**
     * @param admin     Address that receives DEFAULT_ADMIN_ROLE.
     * @param _treasury Destination for pulled stablecoins. May be set later via setTreasury;
     *                  pass address(0) to defer the decision.
     */
    constructor(address admin, address _treasury) EIP712("mStocks DexTokenIssuer", "1") {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(BROKER_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
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

    /// Adds / removes a security-token contract from the whitelist. The DexTokenIssuer must
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
     *           - this DexTokenIssuer contract holds ISSUER_ROLE on `token`
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
    /**
     * @notice Fill a broker-signed PurchaseOrder. Every purchase must be authorized by
     *         a BROKER_ADMIN_ROLE off-chain signature — there is no plain `purchase(...)`
     *         path that bypasses broker consent.
     *
     *         Pre-requisites:
     *           - user has set sufficient stable allowance (via approve OR a separate
     *             permit tx). User's allowance flow is independent of this entry.
     *           - this DexTokenIssuer contract holds ISSUER_ROLE on `order.token`.
     *           - `order.token` is not paused; `order.user` is not blocked/sanctioned.
     *
     * @param order            EIP-712 PurchaseOrder struct signed by broker_admin.
     * @param brokerSignature  65-byte ECDSA signature over the EIP-712 digest.
     */
    function purchase(PurchaseOrder calldata order, bytes calldata brokerSignature)
        external
        onlyRole(OPS_ROLE)
        nonReentrant
        returns (bool)
    {
        address signer = _consumePurchaseOrder(order, brokerSignature);
        _purchase(order.user, order.stable, order.stableAmount, order.token, order.tokenAmount);
        emit Purchased(
            address(this),
            order.user,
            order.token,
            order.stable,
            order.stableAmount,
            order.tokenAmount,
            order.disclosureHash,
            order.nonce,
            signer
        );
        return true;
    }

    function _purchase(
        address user,
        address stable,
        uint256 stableAmount,
        address token,
        uint256 tokenAmount
    ) internal {
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
    }

    /**
     * @notice Fill a broker-signed SellOrder. Every sell must be authorized by a
     *         BROKER_ADMIN_ROLE off-chain signature.
     *
     *         Pre-requisites:
     *           - user has set sufficient token allowance (via approve OR a separate
     *             permit tx)
     *           - treasury has called stable.approve(operator, ≥ stableAmount)
     *           - this DexTokenIssuer contract holds ISSUER_ROLE on `order.token`
     *           - `order.token` is not paused; `order.user` is not blocked/sanctioned
     *           - token.burnEnabled() is true
     *
     * @param order            EIP-712 SellOrder struct signed by broker_admin.
     * @param brokerSignature  65-byte ECDSA signature over the EIP-712 digest.
     */
    function sell(SellOrder calldata order, bytes calldata brokerSignature)
        external
        onlyRole(OPS_ROLE)
        nonReentrant
        returns (bool)
    {
        address signer = _consumeSellOrder(order, brokerSignature);
        _sell(order.user, order.token, order.tokenAmount, order.stable, order.stableAmount);
        emit Sold(
            address(this),
            order.user,
            order.token,
            order.stable,
            order.tokenAmount,
            order.stableAmount,
            order.disclosureHash,
            order.nonce,
            signer
        );
        return true;
    }

    /**
     * @notice Returns the EIP-712 domain separator. Off-chain signers need this to
     *         compute the correct digest (or use a typed-data library that does so
     *         automatically given (name, version, chainId, verifyingContract)).
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _consumePurchaseOrder(PurchaseOrder calldata order, bytes calldata sig)
        internal
        returns (address signer)
    {
        if (block.timestamp > order.deadline) revert OrderExpired();
        uint256 expected = orderNonces[order.user];
        if (order.nonce != expected) revert OrderNonceMismatch(expected, order.nonce);

        bytes32 structHash = keccak256(
            abi.encode(
                PURCHASE_ORDER_TYPEHASH,
                order.user,
                order.stable,
                order.stableAmount,
                order.token,
                order.tokenAmount,
                order.disclosureHash,
                order.nonce,
                order.deadline
            )
        );
        signer = ECDSA.recover(_hashTypedDataV4(structHash), sig);
        if (!hasRole(BROKER_ADMIN_ROLE, signer)) revert InvalidBrokerSignature();

        orderNonces[order.user] = expected + 1;
    }

    function _consumeSellOrder(SellOrder calldata order, bytes calldata sig)
        internal
        returns (address signer)
    {
        if (block.timestamp > order.deadline) revert OrderExpired();
        uint256 expected = orderNonces[order.user];
        if (order.nonce != expected) revert OrderNonceMismatch(expected, order.nonce);

        bytes32 structHash = keccak256(
            abi.encode(
                SELL_ORDER_TYPEHASH,
                order.user,
                order.token,
                order.tokenAmount,
                order.stable,
                order.stableAmount,
                order.disclosureHash,
                order.nonce,
                order.deadline
            )
        );
        signer = ECDSA.recover(_hashTypedDataV4(structHash), sig);
        if (!hasRole(BROKER_ADMIN_ROLE, signer)) revert InvalidBrokerSignature();

        orderNonces[order.user] = expected + 1;
    }

    function _sell(
        address user,
        address token,
        uint256 tokenAmount,
        address stable,
        uint256 stableAmount
    ) internal {
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
        //    DexTokenIssuer for the stablecoin.
        IERC20(stable).safeTransferFrom(treasury, user, stableAmount);
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
