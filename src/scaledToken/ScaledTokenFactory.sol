// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ScaledToken} from "./ScaledToken.sol";
import {IComplianceRegistry} from "../complianceRegistry/IComplianceRegistry.sol";
import {IPauseRegistry} from "../pauseRegistry/IPauseRegistry.sol";

/// @notice Deploys ScaledToken instances behind a shared UpgradeableBeacon. Each deployment
///         is a BeaconProxy; upgrading the beacon upgrades every token at once.
///
///         owner (DEFAULT_ADMIN_ROLE) creates tokens and rotates the default compliance /
///         pause registries. proxyAdmin owns the beacon and is the only address that can
///         upgrade the implementation.
contract ScaledTokenFactory is AccessControlEnumerable, ReentrancyGuard {
    UpgradeableBeacon public immutable beacon;

    /// @notice Default compliance registry passed to every new token.
    address public defaultCompliance;
    /// @notice Default pause registry passed to every new token.
    address public defaultPauseManager;

    address[] private tokens;
    /// @notice Reverse lookup: symbol => proxy.
    mapping(string => address) public tokenBySymbol;
    /// @notice Reverse lookup: asset code (ISIN / CUSIP / internal reference) => proxy.
    ///         Two tokens claiming the same real-world instrument would be a data-integrity
    ///         failure for a regulated tokenized-security protocol, so this mapping guards
    ///         uniqueness at creation and rename time.
    mapping(string => address) public tokenByAssetCode;

    event TokenCreated(
        address indexed proxy,
        string name,
        string symbol,
        string assetCode,
        address indexed admin,
        address[] issuers,
        address[] multiplierSchedulers,
        address indexed deployer
    );
    event DefaultComplianceUpdated(address indexed oldCompliance, address indexed newCompliance);
    event DefaultPauseManagerUpdated(address indexed oldPauseManager, address indexed newPauseManager);
    event SymbolRenamed(address indexed token, string oldSymbol, string newSymbol);
    event AssetCodeRenamed(address indexed token, string oldAssetCode, string newAssetCode);

    error TokenSymbolAlreadyExists(string symbol);
    error AssetCodeAlreadyExists(string assetCode);
    error ZeroAddress();
    error EmptyString();
    error InvalidComplianceContract();
    error InvalidPauseManagerContract();
    /// @dev Reverts when the token's actual `symbol()` does not match the value expected here
    ///      — used by {renameSymbol} to guard against factory-map / on-token symbol divergence.
    error SymbolMismatch(string expected, string provided);
    /// @dev Reverts when a token address is not registered in `tokenBySymbol` under the given symbol.
    error TokenNotRegisteredUnderSymbol(address token, string providedSymbol);
    error AssetCodeMismatch(string expected, string provided);
    error TokenNotRegisteredUnderAssetCode(address token, string providedAssetCode);
    /// @dev Symbols must be 1–32 characters of [A-Za-z0-9-].
    error InvalidSymbol(string symbol);
    /// @dev Asset codes must be 1–32 characters of [A-Za-z0-9-] (accommodates ISIN, CUSIP, internal refs).
    error InvalidAssetCode(string assetCode);
    error CannotRenounceLastAdmin();

    /// @param _minMultiplierNotice Minimum lead time for scheduled UI-multiplier changes, baked
    ///        into the INITIAL beacon implementation (validated in the ScaledToken constructor:
    ///        non-zero and <= 365 days). Not stored on the factory: a later beacon upgrade points
    ///        at a new implementation carrying its own value, so the live figure is read from the
    ///        current implementation via {minMultiplierNotice}.
    constructor(
        address _compliance,
        address _pauseManager,
        address _owner,
        address _proxyAdmin,
        uint256 _minMultiplierNotice
    ) {
        _assertCompliance(_compliance);
        _assertPauseManager(_pauseManager);
        if (_owner == address(0)) revert ZeroAddress();
        if (_proxyAdmin == address(0)) revert ZeroAddress();

        beacon = new UpgradeableBeacon(address(new ScaledToken(_minMultiplierNotice)), _proxyAdmin);

        defaultCompliance = _compliance;
        defaultPauseManager = _pauseManager;

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    }

    /// @notice Deploys a new ScaledToken behind a BeaconProxy and initializes it atomically.
    ///         `_admin` receives DEFAULT_ADMIN_ROLE on the new token (use a multisig, not an EOA);
    ///         `_issuers` receive ISSUER_ROLE (must be contracts); `_multiplierSchedulers`
    ///         receive MULTIPLIER_SCHEDULER_ROLE.
    function createToken(
        string memory _name,
        string memory _symbol,
        string memory _assetCode,
        address _admin,
        address[] memory _issuers,
        address[] memory _multiplierSchedulers
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (address proxy) {
        if (bytes(_name).length == 0) revert EmptyString();
        if (bytes(_symbol).length == 0) revert EmptyString();
        if (bytes(_assetCode).length == 0) revert EmptyString();
        if (_admin == address(0)) revert ZeroAddress();
        _assertSymbol(_symbol);
        _assertAssetCode(_assetCode);
        if (tokenBySymbol[_symbol] != address(0)) revert TokenSymbolAlreadyExists(_symbol);
        if (tokenByAssetCode[_assetCode] != address(0)) revert AssetCodeAlreadyExists(_assetCode);

        bytes memory initData = abi.encodeWithSignature(
            "initialize(string,string,string,address,address,address,address[],address[])",
            _name,
            _symbol,
            _assetCode,
            defaultCompliance,
            defaultPauseManager,
            _admin,
            _issuers,
            _multiplierSchedulers
        );

        BeaconProxy beaconProxy = new BeaconProxy(address(beacon), initData);

        proxy = address(beaconProxy);
        tokens.push(proxy);
        tokenBySymbol[_symbol] = proxy;
        tokenByAssetCode[_assetCode] = proxy;

        require(ScaledToken(proxy).hasRole(DEFAULT_ADMIN_ROLE, _admin), "ScaledToken: init check failed");

        emit TokenCreated(proxy, _name, _symbol, _assetCode, _admin, _issuers, _multiplierSchedulers, msg.sender);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    /// @notice Minimum multiplier-scheduling notice enforced by every token this factory has
    ///         deployed, read live from the beacon's CURRENT implementation. Upgrading the beacon
    ///         to a new implementation (with its own constructor value) updates this figure, and
    ///         with it the window enforced by all existing token proxies.
    function minMultiplierNotice() external view returns (uint256) {
        return ScaledToken(beacon.implementation()).minMultiplierNotice();
    }

    /// @notice Returns every deployed token. Unbounded — prefer {getTokens} in production.
    function getAllTokens() external view returns (address[] memory) {
        return tokens;
    }

    /// @notice Paginated view of deployed tokens. Returns an empty array if `offset` is out of
    ///         range and may return fewer than `limit` entries near the tail.
    function getTokens(uint256 offset, uint256 limit) external view returns (address[] memory slice) {
        uint256 total = tokens.length;
        if (offset >= total || limit == 0) return new address[](0);
        // Clamp against the remaining count rather than computing `offset + limit`, so an
        // arbitrarily large `limit` returns the tail slice instead of overflowing and reverting.
        uint256 remaining = total - offset;
        uint256 size = limit < remaining ? limit : remaining;
        slice = new address[](size);
        for (uint256 i = 0; i < size; ++i) {
            slice[i] = tokens[offset + i];
        }
    }

    function setDefaultCompliance(address _compliance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_compliance == address(0)) revert ZeroAddress();
        _assertCompliance(_compliance);
        emit DefaultComplianceUpdated(defaultCompliance, _compliance);
        defaultCompliance = _compliance;
    }

    function setDefaultPauseManager(address _pauseManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_pauseManager == address(0)) revert ZeroAddress();
        _assertPauseManager(_pauseManager);
        emit DefaultPauseManagerUpdated(defaultPauseManager, _pauseManager);
        defaultPauseManager = _pauseManager;
    }

    function _assertCompliance(address _compliance) internal view {
        uint256 size;
        assembly { size := extcodesize(_compliance) }
        if (size == 0) revert InvalidComplianceContract();
        try IComplianceRegistry(_compliance).checkIsCompliant(address(this), address(this)) {}
        catch (bytes memory) {
            revert InvalidComplianceContract();
        }
    }

    function _assertPauseManager(address _pauseManager) internal view {
        uint256 size;
        assembly { size := extcodesize(_pauseManager) }
        if (size == 0) revert InvalidPauseManagerContract();
        try IPauseRegistry(_pauseManager).isTokenPaused(address(this)) {}
        catch (bytes memory) {
            revert InvalidPauseManagerContract();
        }
    }

    /// @dev Comparison in {createToken} is byte-exact, so callers must normalise symbols.
    function _assertSymbol(string memory _symbol) internal pure {
        bytes memory b = bytes(_symbol);
        if (b.length == 0 || b.length > 32) revert InvalidSymbol(_symbol);
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (
                (c < 0x41 || c > 0x5A) // not A-Z
                    && (c < 0x61 || c > 0x7A) // not a-z
                    && (c < 0x30 || c > 0x39) // not 0-9
                    && c != 0x2D // not hyphen (-)
            ) {
                revert InvalidSymbol(_symbol);
            }
        }
    }

    /// @dev Same charset and length rules as {_assertSymbol}: 1–32 chars of [A-Za-z0-9-].
    ///      Accommodates ISIN (12), CUSIP (9) and short internal reference codes while
    ///      keeping enough structure to catch typos and truly-malformed inputs.
    function _assertAssetCode(string memory _assetCode) internal pure {
        bytes memory b = bytes(_assetCode);
        if (b.length == 0 || b.length > 32) revert InvalidAssetCode(_assetCode);
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (
                (c < 0x41 || c > 0x5A) // not A-Z
                    && (c < 0x61 || c > 0x7A) // not a-z
                    && (c < 0x30 || c > 0x39) // not 0-9
                    && c != 0x2D // not hyphen (-)
            ) {
                revert InvalidAssetCode(_assetCode);
            }
        }
    }

    /// @notice Updates the factory's symbol mapping after a token's symbol changes. Caller must
    ///         have already called {ScaledToken.updateSymbol} on the token itself — this method
    ///         verifies that the on-token `symbol()` already equals `newSymbol` and refuses to
    ///         sync the map otherwise, closing the drift between factory registry and reality.
    function renameSymbol(address token, string calldata oldSymbol, string calldata newSymbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();
        if (bytes(newSymbol).length == 0) revert EmptyString();
        _assertSymbol(newSymbol);
        if (tokenBySymbol[oldSymbol] != token) {
            revert TokenNotRegisteredUnderSymbol(token, oldSymbol);
        }
        // Guard against factory-map / on-token symbol drift: the token must already reflect
        // the new symbol (via ScaledToken.updateSymbol) before we sync the factory registry.
        string memory actualSymbol = ScaledToken(token).symbol();
        if (keccak256(bytes(actualSymbol)) != keccak256(bytes(newSymbol))) {
            revert SymbolMismatch({expected: actualSymbol, provided: newSymbol});
        }
        if (tokenBySymbol[newSymbol] != address(0)) revert TokenSymbolAlreadyExists(newSymbol);

        delete tokenBySymbol[oldSymbol];
        tokenBySymbol[newSymbol] = token;

        emit SymbolRenamed(token, oldSymbol, newSymbol);
    }

    /// @notice Updates the factory's asset-code mapping after a token's asset code changes.
    ///         Caller must have already called {ScaledToken.updateAssetCode} on the token
    ///         itself — this method verifies that the on-token `assetCode()` already equals
    ///         `newAssetCode` and refuses to sync the map otherwise.
    function renameAssetCode(address token, string calldata oldAssetCode, string calldata newAssetCode)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();
        if (bytes(newAssetCode).length == 0) revert EmptyString();
        _assertAssetCode(newAssetCode);
        if (tokenByAssetCode[oldAssetCode] != token) {
            revert TokenNotRegisteredUnderAssetCode(token, oldAssetCode);
        }
        // Guard against factory-map / on-token drift: the token must already reflect the
        // new asset code (via ScaledToken.updateAssetCode) before we sync the registry.
        string memory actualAssetCode = ScaledToken(token).assetCode();
        if (keccak256(bytes(actualAssetCode)) != keccak256(bytes(newAssetCode))) {
            revert AssetCodeMismatch({expected: actualAssetCode, provided: newAssetCode});
        }
        if (tokenByAssetCode[newAssetCode] != address(0)) revert AssetCodeAlreadyExists(newAssetCode);

        delete tokenByAssetCode[oldAssetCode];
        tokenByAssetCode[newAssetCode] = token;

        emit AssetCodeRenamed(token, oldAssetCode, newAssetCode);
    }

    /// @notice Blocks renouncing the final DEFAULT_ADMIN_ROLE holder, which would
    ///         permanently strip this non-upgradeable factory of admin capability
    ///         (no more token creation or default-registry rotation).
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
