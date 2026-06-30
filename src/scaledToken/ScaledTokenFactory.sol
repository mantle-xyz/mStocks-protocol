// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
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

    event TokenCreated(
        address indexed proxy,
        string name,
        string symbol,
        string assetCode,
        address indexed admin,
        address[] issuers,
        address[] operators,
        address indexed deployer
    );
    event DefaultComplianceUpdated(address indexed oldCompliance, address indexed newCompliance);
    event DefaultPauseManagerUpdated(address indexed oldPauseManager, address indexed newPauseManager);
    event SymbolRenamed(address indexed token, string oldSymbol, string newSymbol);

    error TokenSymbolAlreadyExists(string symbol);
    error ZeroAddress();
    error EmptyString();
    error InvalidComplianceContract();
    error InvalidPauseManagerContract();
    error SymbolMismatch(string expected, string provided);
    /// @dev Symbols must be 1–32 characters of [A-Za-z0-9-].
    error InvalidSymbol(string symbol);

    constructor(address _compliance, address _pauseManager, address _owner, address _proxyAdmin) {
        _assertCompliance(_compliance);
        _assertPauseManager(_pauseManager);
        if (_owner == address(0)) revert ZeroAddress();
        if (_proxyAdmin == address(0)) revert ZeroAddress();

        beacon = new UpgradeableBeacon(address(new ScaledToken()), _proxyAdmin);

        defaultCompliance = _compliance;
        defaultPauseManager = _pauseManager;

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    }

    /// @notice Deploys a new ScaledToken behind a BeaconProxy and initializes it atomically.
    ///         `_admin` receives DEFAULT_ADMIN_ROLE on the new token (use a multisig, not an EOA);
    ///         `_issuers` receive ISSUER_ROLE (must be contracts); `_operators` receive OPS_ROLE.
    function createToken(
        string memory _name,
        string memory _symbol,
        string memory _assetCode,
        address _admin,
        address[] memory _issuers,
        address[] memory _operators
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (address proxy) {
        if (bytes(_name).length == 0) revert EmptyString();
        if (bytes(_symbol).length == 0) revert EmptyString();
        if (bytes(_assetCode).length == 0) revert EmptyString();
        if (_admin == address(0)) revert ZeroAddress();
        _assertSymbol(_symbol);
        if (tokenBySymbol[_symbol] != address(0)) revert TokenSymbolAlreadyExists(_symbol);

        bytes memory initData = abi.encodeWithSignature(
            "initialize(string,string,string,address,address,address,address[],address[])",
            _name,
            _symbol,
            _assetCode,
            defaultCompliance,
            defaultPauseManager,
            _admin,
            _issuers,
            _operators
        );

        BeaconProxy beaconProxy = new BeaconProxy(address(beacon), initData);

        proxy = address(beaconProxy);
        tokens.push(proxy);
        tokenBySymbol[_symbol] = proxy;

        require(ScaledToken(proxy).hasRole(DEFAULT_ADMIN_ROLE, _admin), "ScaledToken: init check failed");

        emit TokenCreated(proxy, _name, _symbol, _assetCode, _admin, _issuers, _operators, msg.sender);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
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
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 size = end - offset;
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

    /// @notice Updates the factory's symbol mapping after a token's symbol changes. Caller must
    ///         have already called {ScaledToken.updateSymbol} on the token itself.
    function renameSymbol(address token, string calldata oldSymbol, string calldata newSymbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (bytes(newSymbol).length == 0) revert EmptyString();
        _assertSymbol(newSymbol);
        if (tokenBySymbol[oldSymbol] != token) {
            revert SymbolMismatch(oldSymbol, "token not registered under oldSymbol");
        }
        if (tokenBySymbol[newSymbol] != address(0)) revert TokenSymbolAlreadyExists(newSymbol);

        delete tokenBySymbol[oldSymbol];
        tokenBySymbol[newSymbol] = token;

        emit SymbolRenamed(token, oldSymbol, newSymbol);
    }
}
