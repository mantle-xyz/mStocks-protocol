// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "../ERC8056/ERC8056BaseUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import "../compliance/ComplianceClientUpgradeable.sol";
import "../pauseManager/PauseManagerClientUpgradeable.sol";

/**
 * @title  TokenizedSecurities
 * @notice Token implementation with compliance, pause, and EIP-8056 scaled UI amount
 * @notice These tokens are Certificates which have been deemed to be Securities pursuant to a written determination of the Abu Dhabi Global Markets Financial Services Regulatory Authority under section 58(2)(b) of the Financial Services and Markets Regulations 2015
 */
contract SecuritiesToken is
    ERC8056BaseUpgradeable,
    AccessControlEnumerableUpgradeable,
    ComplianceClientUpgradeable,
    PauseManagerClientUpgradeable
{
    /// Role for automated issuance and redemption tasks
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// Whether minting is enabled for ISSUER_ROLE operations
    bool public mintEnabled;
    /// Whether burning is enabled for ISSUER_ROLE operations
    bool public burnEnabled;

    /// Override for the name allowing the name to be changed after deployment
    string private _nameOverride;
    /// Override for the symbol allowing the symbol to be changed after deployment
    string private _symbolOverride;

    /// Identifier string for this token (e.g. ISIN, CUSIP, or internal reference)
    string public identifier;

    /**
     * @notice Emitted when minting is enabled or disabled
     * @param  enabled The new mint enabled flag
     */
    event MintEnabledSet(bool enabled);

    /**
     * @notice Emitted when burning is enabled or disabled
     * @param  enabled The new burn enabled flag
     */
    event BurnEnabledSet(bool enabled);

    /**
     * @notice Emitted when the token name is changed
     * @param  oldName The old token name
     * @param  newName The new token name
     */
    event NameChanged(string oldName, string newName);

    /**
     * @notice Emitted when the token symbol is changed
     * @param  oldSymbol The old token symbol
     * @param  newSymbol The new token symbol
     */
    event SymbolChanged(string oldSymbol, string newSymbol);

    /**
     * @notice Emitted when the identifier is changed
     * @param  oldIdentifier The old identifier
     * @param  newIdentifier The new identifier
     */
    event IdentifierChanged(string oldIdentifier, string newIdentifier);

    /// Error emitted when minting is disabled
    error MintDisabled();
    /// Error emitted when burning is disabled
    error BurnDisabled();
    /// Error emitted when sender lacks admin or issuer permissions
    error UnauthorizedRole();
    /// Error emitted when an empty string is provided
    error EmptyString();
    /// Error emitted when a zero address is provided
    error ZeroAddress();
    /// Error emitted when an account attempts to grant a role to itself
    error SelfGrantNotAllowed();

    /**
     * @notice Checks that the caller has DEFAULT_ADMIN_ROLE or ISSUER_ROLE
     */
    modifier onlyAdminOrIssuer() {
        _checkAdminOrIssuer();
        _;
    }

    function _checkAdminOrIssuer() private view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(ISSUER_ROLE, msg.sender)) {
            revert UnauthorizedRole();
        }
    }

    function _checkAdminOrOperator() private view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender) && !hasRole(OPS_ROLE, msg.sender)) {
            revert UnauthorizedRole();
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the SecuritiesToken contract
     * @param  nameOverride_      The initial name of the token
     * @param  symbolOverride_    The initial symbol of the token
     * @param  identifier_        The initial identifier of the token (e.g. ISIN, CUSIP)
     * @param  compliance_        The address of the compliance contract
     * @param  pauseManager_      The address of the token pause manager contract
     * @param  admin_             The address that will receive DEFAULT_ADMIN_ROLE
     * @param  issuers_           Addresses that will receive ISSUER_ROLE on deployment
     * @param  operators_         Addresses that will receive OPS_ROLE on deployment
     * @dev    This function can only be called once during deployment via the proxy pattern
     */
    function initialize(
        string memory nameOverride_,
        string memory symbolOverride_,
        string memory identifier_,
        address compliance_,
        address pauseManager_,
        address admin_,
        address[] memory issuers_,
        address[] memory operators_
    ) public initializer {
        __securitiesToken_init(
            nameOverride_, symbolOverride_, identifier_, compliance_, pauseManager_, admin_, issuers_, operators_
        );
    }

    /**
     * @notice Internal initialization function for SecuritiesToken
     * @param  nameOverride_      The initial name of the token
     * @param  symbolOverride_    The initial symbol of the token
     * @param  identifier_        The initial identifier of the token (e.g. ISIN, CUSIP)
     * @param  compliance_        The address of the compliance contract
     * @param  pauseManager_      The address of the token pause manager contract
     * @param  admin_             The address that will receive DEFAULT_ADMIN_ROLE
     * @param  issuers_           Addresses that will receive ISSUER_ROLE on deployment
     * @param  operators_         Addresses that will receive OPS_ROLE on deployment
     * @dev    Initializes all parent contracts and sets up the SecuritiesToken-specific state
     */
    function __securitiesToken_init(
        string memory nameOverride_,
        string memory symbolOverride_,
        string memory identifier_,
        address compliance_,
        address pauseManager_,
        address admin_,
        address[] memory issuers_,
        address[] memory operators_
    ) internal onlyInitializing {
        if (bytes(nameOverride_).length == 0) revert EmptyString();
        if (bytes(symbolOverride_).length == 0) revert EmptyString();
        if (bytes(identifier_).length == 0) revert EmptyString();
        __AccessControlEnumerable_init();
        __erc8056Base_init(nameOverride_, symbolOverride_);
        _nameOverride = nameOverride_;
        _symbolOverride = symbolOverride_;
        identifier = identifier_;
        __ComplianceClientInitializable_init_unchained(compliance_);
        __PauseManagerClientInitializable_init_unchained(pauseManager_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _setRoleAdmin(ISSUER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
        for (uint256 i = 0; i < issuers_.length; ++i) {
            if (issuers_[i] == address(0)) revert ZeroAddress();
            _grantRole(ISSUER_ROLE, issuers_[i]);
        }
        for (uint256 i = 0; i < operators_.length; ++i) {
            if (operators_[i] == address(0)) revert ZeroAddress();
            _grantRole(OPS_ROLE, operators_[i]);
        }
        mintEnabled = true;
        burnEnabled = true;
        emit MintEnabledSet(true);
        emit BurnEnabledSet(true);
    }

    // ═══════════════════════════════════════════════
    //              Name / Symbol overrides
    // ═══════════════════════════════════════════════

    /**
     * @notice Returns the name of the token
     * @dev    Overrides the default ERC20 name function to return the `_nameOverride` variable,
     *         allowing the name to be changed after deployment
     */
    function name() public view virtual override returns (string memory) {
        return _nameOverride;
    }

    /**
     * @notice Returns the ticker symbol of the token
     * @dev    Overrides the default ERC20 symbol function to return the `_symbolOverride` variable,
     *         allowing the symbol to be changed after deployment
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbolOverride;
    }

    /**
     * @notice Sets the token name
     * @param  nameOverride_ New token name
     */
    function setName(string memory nameOverride_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setName(nameOverride_);
    }

    /**
     * @notice Sets the token symbol
     * @param  symbolOverride_ New token symbol
     */
    function setSymbol(string memory symbolOverride_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSymbol(symbolOverride_);
    }

    /**
     * @notice Sets the token identifier
     * @param  identifier_ New identifier value (e.g. ISIN, CUSIP, or internal reference)
     */
    function setIdentifier(string memory identifier_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(identifier_).length == 0) revert EmptyString();
        emit IdentifierChanged(identifier, identifier_);
        identifier = identifier_;
    }

    /**
     * @notice Internal function to set the token name
     * @param  nameOverride_ New token name
     */
    function _setName(string memory nameOverride_) internal {
        if (bytes(nameOverride_).length == 0) revert EmptyString();
        emit NameChanged(_nameOverride, nameOverride_);
        _nameOverride = nameOverride_;
    }

    /**
     * @notice Internal function to set the token symbol
     * @param  symbolOverride_ New token symbol
     */
    function _setSymbol(string memory symbolOverride_) internal {
        if (bytes(symbolOverride_).length == 0) revert EmptyString();
        emit SymbolChanged(_symbolOverride, symbolOverride_);
        _symbolOverride = symbolOverride_;
    }

    // ═══════════════════════════════════════════════
    //              Mint / Burn controls
    // ═══════════════════════════════════════════════

    /**
     * @notice Sets whether minting is enabled
     * @param  _mintEnabled The new mint enabled flag
     */
    function setMintEnabled(bool _mintEnabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mintEnabled = _mintEnabled;
        emit MintEnabledSet(_mintEnabled);
    }

    /**
     * @notice Sets whether burning is enabled
     * @param  _burnEnabled The new burn enabled flag
     */
    function setBurnEnabled(bool _burnEnabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        burnEnabled = _burnEnabled;
        emit BurnEnabledSet(_burnEnabled);
    }

    /**
     * @notice Mints a specific amount of tokens to the caller
     * @param  amount The amount of tokens to be minted
     * @dev    Callable by DEFAULT_ADMIN_ROLE and ISSUER_ROLE while minting is enabled
     */
    function mint(uint256 amount) external onlyAdminOrIssuer returns (bool) {
        if (!mintEnabled) revert MintDisabled();
        _mint(msg.sender, amount);
        return true;
    }

    /**
     * @notice Burns a specific amount of tokens from the caller
     * @param  amount The amount of tokens to be burned
     * @dev    Callable by DEFAULT_ADMIN_ROLE and ISSUER_ROLE while burning is enabled
     */
    function burn(uint256 amount) external onlyAdminOrIssuer returns (bool) {
        if (!burnEnabled) revert BurnDisabled();
        _burn(msg.sender, amount);
        return true;
    }

    // ═══════════════════════════════════════════════
    //          Compliance / Pause setters
    // ═══════════════════════════════════════════════

    /**
     * @notice Sets the compliance address
     * @param  _compliance New compliance address
     */
    function setCompliance(address _compliance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCompliance(_compliance);
    }

    /**
     * @notice Sets the token pause manager address
     * @param  _pauseManager New token pause manager address
     */
    function setPauseManager(address _pauseManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPauseManager(_pauseManager);
    }

    // ═══════════════════════════════════════════════
    //              Internal hooks
    // ═══════════════════════════════════════════════

    /**
     * @dev Restricts multiplier updates to accounts with DEFAULT_ADMIN_ROLE or OPS_ROLE.
     *      Called by {ERC8056BaseUpgradeable-setUIMultiplier} before executing the update.
     */
    function _authorizeMultiplierUpdate() internal view override {
        _checkAdminOrOperator();
    }

    /**
     * @dev Validates that a proposed multiplier falls within safe bounds.
     *
     *      Multipliers use 1e18 as the base (1e18 == 1.0x). The allowed range is:
     *        - Minimum: 1e9  — represents a 1e-9x multiplier (0.000000001x)
     *        - Maximum: 1e27 — represents a 1e9x  multiplier (1000000000x)
     *
     *      A near-zero multiplier (below 1e9) would make {toUIAmount} return 0 for
     *      virtually all balances, hiding holdings in the UI, and {fromUIAmount} would
     *      return astronomically large raw amounts.
     *
     *      An excessively large multiplier (above 1e27) risks overflow in {toUIAmount}
     *      even with {Math-mulDiv} safe arithmetic.
     *
     * @param newMultiplier The proposed new multiplier value (1e18 == 1.0x)
     */
    function _validateMultiplier(uint256 newMultiplier) internal pure override {
        require(newMultiplier >= 1e9, "SecuritiesToken: multiplier below minimum (1e-9x)");
        require(newMultiplier <= 1e27, "SecuritiesToken: multiplier above maximum (1e9x)");
    }

    /**
     * @dev Enforces a maximum scheduling horizon of 365 days on multiplier changes.
     *      The base library permits any future timestamp; this override restricts it
     *      to a product-appropriate window so no single scheduled change can lock the
     *      multiplier indefinitely.
     *
     * @param newMultiplier        The proposed new multiplier value (1e18 == 1.0x)
     * @param effectiveAtTimestamp Unix timestamp when the multiplier should take effect
     */
    function _setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) internal override {
        require(effectiveAtTimestamp <= block.timestamp + 365 days, "SecuritiesToken: effective time too far in future");
        super._setUIMultiplier(newMultiplier, effectiveAtTimestamp);
    }

    /**
     * @notice Hook that is called during any transfer of tokens
     * @param  from   The address tokens are transferred from (0x0 for minting)
     * @param  to     The address tokens are transferred to (0x0 for burning)
     * @param  value  The amount of tokens being transferred
     * @dev    Checks if token is paused and validates compliance for all parties involved
     */
    function _update(address from, address to, uint256 value) internal override(ERC8056BaseUpgradeable) {
        // Revert if the token is paused
        _checkTokenIsPaused();
        // Check constraints when `transferFrom` is called to facilitate
        // a transfer between two parties that are not `from` or `to`.
        if (from != msg.sender && to != msg.sender) {
            _checkIsCompliant(msg.sender);
        }

        if (from != address(0)) {
            // If not minting
            _checkIsCompliant(from);
        }

        if (to != address(0)) {
            // If not burning
            _checkIsCompliant(to);
        }

        super._update(from, to, value);
    }

    // ═══════════════════════════════════════════════
    //                ERC-165
    // ═══════════════════════════════════════════════

    /**
     * @notice Returns whether an interface is supported
     * @param  interfaceId The interface identifier, as specified in ERC-165
     * @return True if the interface is supported
     */
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

    // ═══════════════════════════════════════════════
    //                Role-grant guard
    // ═══════════════════════════════════════════════

    /**
     * @notice Grants `role` to `account`, with an extra constraint: the caller cannot
     *         grant any role to itself. Forces separation of duties — an admin must
     *         delegate operational roles (ISSUER_ROLE / OPS_ROLE) to a different
     *         account before those roles can be exercised.
     * @dev    Internal `_grantRole` is NOT overridden, so the constructor / initializer
     *         can still seed the admin and the initial issuer / operator lists.
     */
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControlUpgradeable, IAccessControl)
    {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[46] private __gap;
}
