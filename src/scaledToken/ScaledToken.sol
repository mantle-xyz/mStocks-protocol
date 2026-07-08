// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ERC8056BaseUpgradeable} from "../ERC8056/ERC8056BaseUpgradeable.sol";
import {ComplianceGuardUpgradeable} from "../complianceRegistry/ComplianceGuardUpgradeable.sol";
import {PauseGuardUpgradeable} from "../pauseRegistry/PauseGuardUpgradeable.sol";

/// @notice ERC-20 with compliance, pause, EIP-2612 permit and EIP-8056 UI multiplier
///         (stock split / dividend factor). Certificates issued under section 58(2)(b)
///         of the ADGM Financial Services and Markets Regulations 2015.
contract ScaledToken is
    ERC8056BaseUpgradeable,
    AccessControlEnumerableUpgradeable,
    ERC20PermitUpgradeable,
    ComplianceGuardUpgradeable,
    PauseGuardUpgradeable
{
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant MULTIPLIER_SCHEDULER_ROLE = keccak256("MULTIPLIER_SCHEDULER_ROLE");

    bool public mintAllowed;
    bool public burnAllowed;

    string private _storedName;
    string private _storedSymbol;

    /// @notice External instrument code such as ISIN, CUSIP, or internal reference.
    string public assetCode;

    event MintAllowedSet(bool allowed);
    event BurnAllowedSet(bool allowed);
    event NameUpdated(string oldName, string newName);
    event SymbolUpdated(string oldSymbol, string newSymbol);
    event AssetCodeUpdated(string oldCode, string newCode);

    error MintNotAllowed();
    error BurnNotAllowed();
    error UnauthorizedRole();
    error EmptyString();
    error ZeroAddress();
    error SelfGrantNotAllowed();
    /// @dev ISSUER_ROLE governs mint/burn and must be held by a contract with its own
    ///      access control — never a plain EOA.
    error IssuerNotContract();

    modifier onlyIssuer() {
        _requireIssuer();
        _;
    }

    function _requireIssuer() private view {
        if (!hasRole(ISSUER_ROLE, msg.sender)) revert UnauthorizedRole();
    }

    function _requireMultiplierScheduler() private view {
        if (!hasRole(MULTIPLIER_SCHEDULER_ROLE, msg.sender)) revert UnauthorizedRole();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        string memory assetCode_,
        address compliance_,
        address pauseManager_,
        address admin_,
        address[] memory issuers_,
        address[] memory multiplierSchedulers_
    ) public initializer {
        __scaledToken_init(name_, symbol_, assetCode_, compliance_, pauseManager_, admin_, issuers_, multiplierSchedulers_);
    }

    function __scaledToken_init(
        string memory name_,
        string memory symbol_,
        string memory assetCode_,
        address compliance_,
        address pauseManager_,
        address admin_,
        address[] memory issuers_,
        address[] memory multiplierSchedulers_
    ) internal onlyInitializing {
        if (bytes(name_).length == 0) revert EmptyString();
        if (bytes(symbol_).length == 0) revert EmptyString();
        if (bytes(assetCode_).length == 0) revert EmptyString();
        // Defense in depth: factory already rejects zero admin in createToken, but initialize()
        // is a public entrypoint on the impl and any BeaconProxy pointing at the shared beacon
        // could bypass that check. Match the pattern used for compliance/pauseManager/issuers.
        if (admin_ == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        __erc8056Base_init(name_, symbol_);
        // EIP-712 domain commits to the *initial* name; later updateName() does not
        // refresh it. Off-chain clients should query eip712Domain() for the live domain.
        __ERC20Permit_init(name_);
        _storedName = name_;
        _storedSymbol = symbol_;
        assetCode = assetCode_;
        __ComplianceGuard_init_unchained(compliance_);
        __PauseGuard_init_unchained(pauseManager_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _setRoleAdmin(ISSUER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(MULTIPLIER_SCHEDULER_ROLE, DEFAULT_ADMIN_ROLE);
        for (uint256 i = 0; i < issuers_.length; ++i) {
            if (issuers_[i] == address(0)) revert ZeroAddress();
            _grantRole(ISSUER_ROLE, issuers_[i]);
        }
        for (uint256 i = 0; i < multiplierSchedulers_.length; ++i) {
            if (multiplierSchedulers_[i] == address(0)) revert ZeroAddress();
            _grantRole(MULTIPLIER_SCHEDULER_ROLE, multiplierSchedulers_[i]);
        }
        mintAllowed = true;
        burnAllowed = true;
        emit MintAllowedSet(true);
        emit BurnAllowedSet(true);
    }

    function name() public view virtual override returns (string memory) {
        return _storedName;
    }

    function symbol() public view virtual override returns (string memory) {
        return _storedSymbol;
    }

    function updateName(string memory name_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(name_).length == 0) revert EmptyString();
        emit NameUpdated(_storedName, name_);
        _storedName = name_;
    }

    function updateSymbol(string memory symbol_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(symbol_).length == 0) revert EmptyString();
        emit SymbolUpdated(_storedSymbol, symbol_);
        _storedSymbol = symbol_;
    }

    function updateAssetCode(string memory assetCode_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(assetCode_).length == 0) revert EmptyString();
        emit AssetCodeUpdated(assetCode, assetCode_);
        assetCode = assetCode_;
    }

    function setMintAllowed(bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mintAllowed = allowed;
        emit MintAllowedSet(allowed);
    }

    function setBurnAllowed(bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        burnAllowed = allowed;
        emit BurnAllowedSet(allowed);
    }

    /// @notice Mints `amount` to the caller. Requires ISSUER_ROLE and mintAllowed.
    function mint(uint256 amount) external onlyIssuer returns (bool) {
        if (!mintAllowed) revert MintNotAllowed();
        _mint(msg.sender, amount);
        return true;
    }

    /// @notice Burns `amount` from the caller. Requires ISSUER_ROLE and burnAllowed.
    function burn(uint256 amount) external onlyIssuer returns (bool) {
        if (!burnAllowed) revert BurnNotAllowed();
        _burn(msg.sender, amount);
        return true;
    }

    function updateCompliance(address _compliance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCompliance(_compliance);
    }

    function updatePauseManager(address _pauseManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPauseManager(_pauseManager);
    }

    /// @dev MULTIPLIER_SCHEDULER_ROLE authorises scheduled multiplier updates; admin only grants the role.
    function _authorizeMultiplierUpdate() internal view override {
        _requireMultiplierScheduler();
    }

    /// @dev Multipliers use 1e18 == 1.0x. Allowed range [1e9, 1e27] guards against UI
    ///      values rounding to zero on one end and overflow risk on the other.
    function _validateMultiplier(uint256 newMultiplier) internal pure override {
        require(newMultiplier >= 1e9, "ScaledToken: multiplier below minimum (1e-9x)");
        require(newMultiplier <= 1e27, "ScaledToken: multiplier above maximum (1e9x)");
    }

    /// @dev Caps the scheduling horizon at 365 days so no single change can lock the
    ///      multiplier indefinitely.
    function _setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) internal override {
        require(effectiveAtTimestamp <= block.timestamp + 365 days, "ScaledToken: effective time too far in future");
        super._setUIMultiplier(newMultiplier, effectiveAtTimestamp);
    }

    /// @dev Pause + compliance gate on every transfer. When a third party initiates the
    ///      transfer via {transferFrom}, that party is checked too.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC8056BaseUpgradeable, ERC20Upgradeable)
    {
        _checkTokenIsPaused();
        if (from != msg.sender && to != msg.sender) {
            _checkIsCompliant(msg.sender);
        }
        if (from != address(0)) {
            _checkIsCompliant(from);
        }
        if (to != address(0)) {
            _checkIsCompliant(to);
        }
        super._update(from, to, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC8056BaseUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return ERC8056BaseUpgradeable.supportsInterface(interfaceId)
            || AccessControlEnumerableUpgradeable.supportsInterface(interfaceId);
    }

    /// @notice Disallows self-grant — admin must delegate operational roles to a separate account.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

    /// @dev Covers both the public grantRole flow and the initializer path (initial issuers
    ///      are seeded via internal _grantRole, bypassing the public override). Enforces
    ///      that ISSUER_ROLE may only be granted to a contract.
    function _grantRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        if (role == ISSUER_ROLE && account.code.length == 0) revert IssuerNotContract();
        return super._grantRole(role, account);
    }

    /// @dev Storage gap for upgrade-safe inheritance.
    uint256[46] private __gap;
}
