// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./SecuritiesToken.sol";
import "../compliance/ICompliance.sol";
import "../pauseManager/IPauseManager.sol";

/**
 * @title  TokenizedSecuritiesFactory
 * @notice Factory contract that deploys new SecuritiesToken instances as BeaconProxy contracts.
 *         All proxies share the same SecuritiesToken logic via a single UpgradeableBeacon.
 *         Upgrading the beacon upgrades ALL token instances simultaneously.
 *
 * @dev    Deployment flow:
 *         1. Deploy SecuritiesTokenFactory(compliance, pauseManager, owner, proxyAdmin)
 *            — the factory deploys the SecuritiesToken implementation and UpgradeableBeacon
 *              internally, then transfers beacon ownership to proxyAdmin
 *         2. Call factory.deployToken("Apple Inc.", "AAPL", "US0378331005", _admin, issuers) → creates BeaconProxy
 *            — _admin receives DEFAULT_ADMIN_ROLE on the new token (must not be the deployer EOA)
 *
 *         On BSCScan, each BeaconProxy will show as a proxy contract that
 *         delegates to the SecuritiesToken implementation via the beacon.
 *
 *         Ownership model:
 *          - owner (DEFAULT_ADMIN_ROLE)
 *              ├── Deploy new tokens
 *              ├── Set compliance / pause manager
 *              └── Grant/revoke roles
 *          - proxyAdmin (Beacon owner)
 *              └── Upgrade implementation via beacon.upgradeTo()
 */
contract SecuritiesTokenFactory is AccessControlEnumerable, ReentrancyGuard {
    /// The beacon that all token proxies point to
    UpgradeableBeacon public immutable beacon;

    /// Default compliance address for new tokens
    address public compliance;

    /// Default token pause manager address for new tokens
    address public pauseManager;

    /// Array of all deployed token proxy addresses
    address[] private deployedTokens;

    /// Mapping from token symbol to proxy address
    mapping(string => address) public tokenBySymbol;

    /**
     * @notice Emitted when a new token proxy is deployed
     * @param  proxy       The address of the newly deployed BeaconProxy
     * @param  name        The token name
     * @param  symbol      The token symbol
     * @param  identifier  The token identifier (e.g. ISIN, CUSIP)
     * @param  admin       The address that received DEFAULT_ADMIN_ROLE on the token
     * @param  issuers     The addresses that received ISSUER_ROLE on the token
     * @param  operators   The addresses that received OPS_ROLE on the token
     * @param  deployer    The address that triggered the deployment
     */
    event TokenDeployed(
        address indexed proxy,
        string name,
        string symbol,
        string identifier,
        address indexed admin,
        address[] issuers,
        address[] operators,
        address indexed deployer
    );

    /**
     * @notice Emitted when the compliance address is updated
     * @param  oldCompliance The previous compliance address
     * @param  newCompliance The new compliance address
     */
    event ComplianceUpdated(address indexed oldCompliance, address indexed newCompliance);

    /**
     * @notice Emitted when the token pause manager address is updated
     * @param  oldPauseManager The previous pause manager address
     * @param  newPauseManager The new pause manager address
     */
    event PauseManagerUpdated(address indexed oldPauseManager, address indexed newPauseManager);

    /**
     * @notice Emitted when a token's symbol mapping is updated in the factory
     * @param  token      The token proxy address
     * @param  oldSymbol  The previous symbol
     * @param  newSymbol  The new symbol
     */
    event SymbolUpdated(address indexed token, string oldSymbol, string newSymbol);

    /// Error thrown when a token with the same symbol already exists
    error TokenSymbolAlreadyExists(string symbol);

    /// Error thrown when a zero address is provided
    error ZeroAddress();

    /// Error thrown when an empty string is provided
    error EmptyString();

    /// Error thrown when the address does not implement the expected interface
    error InvalidComplianceContract();

    /// Error thrown when the address does not implement the expected interface
    error InvalidPauseManagerContract();

    /// Error thrown when oldSymbol does not match the factory's current record for the token
    error SymbolMismatch(string expected, string provided);

    /// Error thrown when a symbol contains invalid characters or exceeds maximum length
    /// @dev Symbols must be 1–32 ASCII letters (A-Z, a-z), digits (0-9), or hyphens (-)
    error InvalidSymbol(string symbol);

    /**
     * @param  _compliance       Default compliance address for new tokens
     * @param  _pauseManager Default token pause manager address for new tokens
     * @param  _owner            The address that receives DEFAULT_ADMIN_ROLE (deploys tokens, manages settings)
     * @param  _proxyAdmin       The address that receives beacon ownership (can upgrade implementation)
     */
    constructor(address _compliance, address _pauseManager, address _owner, address _proxyAdmin) {
        _validateCompliance(_compliance);
        _validatePauseManager(_pauseManager);
        if (_owner == address(0)) revert ZeroAddress();
        if (_proxyAdmin == address(0)) revert ZeroAddress();

        // Deploy implementation and beacon internally
        beacon = new UpgradeableBeacon(address(new SecuritiesToken()), _proxyAdmin);

        compliance = _compliance;
        pauseManager = _pauseManager;

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    }

    /**
     * @notice Deploys a new SecuritiesToken instance as a BeaconProxy
     * @param  _name       The token name (e.g., "Apple Inc.")
     * @param  _symbol     The token symbol (e.g., "AAPL")
     *                     Must be 1–32 ASCII letters (A-Z, a-z), digits (0-9), or hyphens (-)
     *                     No spaces or other special characters.
     *                     Comparison is byte-exact — the caller must ensure canonical form.
     * @param  _identifier The token identifier (e.g. ISIN "US0378331005", CUSIP, or internal ref).
     *                     Must be non-empty. Reverts with EmptyString() if blank.
     * @param  _admin      The address that will receive DEFAULT_ADMIN_ROLE on the new token.
     *                     Must not be zero. Should be a multisig or governance contract —
     *                     never the deployer EOA.
     * @param  _issuers    Addresses that will receive ISSUER_ROLE on the new token.
     *                     May be an empty array if no issuers are needed at deployment time.
     * @param  _operators  Addresses that will receive OPS_ROLE on the new token (manages
     *                     UI multiplier scheduling). May be an empty array.
     * @return proxy       The address of the newly deployed BeaconProxy
     * @dev    The proxy's initialize() is called atomically during deployment.
     */
    function deployToken(
        string memory _name,
        string memory _symbol,
        string memory _identifier,
        address _admin,
        address[] memory _issuers,
        address[] memory _operators
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant returns (address proxy) {
        if (bytes(_name).length == 0) revert EmptyString();
        if (bytes(_symbol).length == 0) revert EmptyString();
        if (bytes(_identifier).length == 0) revert EmptyString();
        if (_admin == address(0)) revert ZeroAddress();
        _validateSymbol(_symbol);
        if (tokenBySymbol[_symbol] != address(0)) revert TokenSymbolAlreadyExists(_symbol);

        // Encode the initialize() call that will be executed on the new proxy
        bytes memory initData = abi.encodeWithSignature(
            "initialize(string,string,string,address,address,address,address[],address[])",
            _name,
            _symbol,
            _identifier,
            compliance,
            pauseManager,
            _admin,
            _issuers,
            _operators
        );

        // Deploy a new BeaconProxy pointing to our beacon
        // The initData is executed via delegatecall during construction
        BeaconProxy beaconProxy = new BeaconProxy(address(beacon), initData);

        proxy = address(beaconProxy);
        deployedTokens.push(proxy);
        tokenBySymbol[_symbol] = proxy;

        require(SecuritiesToken(proxy).hasRole(DEFAULT_ADMIN_ROLE, _admin), "SecuritiesToken: init check failed");

        emit TokenDeployed(proxy, _name, _symbol, _identifier, _admin, _issuers, _operators, msg.sender);
    }

    /**
     * @notice Returns the number of deployed tokens
     * @return The count of deployed token proxies
     */
    function deployedTokenCount() external view returns (uint256) {
        return deployedTokens.length;
    }

    /**
     * @notice Returns all deployed token addresses
     * @return Array of deployed token proxy addresses
     * @dev    WARNING: This returns the full unbounded array. May exceed the block gas limit
     *         if a large number of tokens have been deployed. Prefer {getDeployedTokens} with
     *         pagination for production use.
     */
    function getAllDeployedTokens() external view returns (address[] memory) {
        return deployedTokens;
    }

    /**
     * @notice Returns a paginated slice of deployed token addresses
     * @param  offset The index to start from (0-based)
     * @param  limit  Maximum number of addresses to return
     * @return slice  Array of up to `limit` deployed token proxy addresses starting at `offset`
     * @dev    Returns an empty array if `offset` is >= the total count.
     *         The returned slice may be shorter than `limit` if fewer entries remain.
     *         Use {deployedTokenCount} to determine total count for pagination.
     */
    function getDeployedTokens(uint256 offset, uint256 limit) external view returns (address[] memory slice) {
        uint256 total = deployedTokens.length;
        if (offset >= total || limit == 0) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 size = end - offset;
        slice = new address[](size);
        for (uint256 i = 0; i < size; ++i) {
            slice[i] = deployedTokens[offset + i];
        }
    }

    /**
     * @notice Updates the default compliance address for future deployments
     * @param  _compliance The new compliance address
     * @dev    Validates that the address is a contract implementing ICompliance
     */
    function setCompliance(address _compliance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_compliance == address(0)) revert ZeroAddress();
        _validateCompliance(_compliance);
        emit ComplianceUpdated(compliance, _compliance);
        compliance = _compliance;
    }

    /**
     * @notice Updates the default token pause manager address for future deployments
     * @param  _pauseManager The new token pause manager address
     * @dev    Validates that the address is a contract implementing IPauseManager
     */
    function setPauseManager(address _pauseManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_pauseManager == address(0)) revert ZeroAddress();
        _validatePauseManager(_pauseManager);
        emit PauseManagerUpdated(pauseManager, _pauseManager);
        pauseManager = _pauseManager;
    }

    /**
     * @notice Validates that an address is a contract implementing ICompliance
     * @param  _compliance The address to validate
     */
    function _validateCompliance(address _compliance) internal view {
        uint256 size;
        assembly {
            size := extcodesize(_compliance)
        }
        if (size == 0) revert InvalidComplianceContract();
        try ICompliance(_compliance).checkIsCompliant(address(this), address(this)) {}
        catch (bytes memory) {
            revert InvalidComplianceContract();
        }
    }

    /**
     * @notice Validates that an address is a contract implementing IPauseManager
     * @param  _pauseManager The address to validate
     */
    function _validatePauseManager(address _pauseManager) internal view {
        uint256 size;
        assembly {
            size := extcodesize(_pauseManager)
        }
        if (size == 0) revert InvalidPauseManagerContract();
        try IPauseManager(_pauseManager).isTokenPaused(address(this)) {}
        catch (bytes memory) {
            revert InvalidPauseManagerContract();
        }
    }

    /**
     * @notice Validates that a symbol is canonical: 1–32 ASCII letters (A-Z, a-z), digits (0-9), or hyphens (-)
     * @dev    Symbols must be normalised before calling deployToken / updateSymbol.
     *         The duplicate-symbol check in {deployToken} is byte-exact, so "AAPL" and "aapl"
     *         would be treated as different symbols.
     * @param  _symbol The symbol to validate
     */
    function _validateSymbol(string memory _symbol) internal pure {
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

    /**
     * @notice Updates the factory's symbol mapping after a token's symbol has been changed
     * @param  token      The token proxy address whose symbol was changed
     * @param  oldSymbol  The symbol currently recorded in the factory mapping (must match)
     * @param  newSymbol  The new symbol to register (must not already be taken)
     * @dev    This function only updates the factory mapping — it does NOT call setSymbol()
     *         on the token itself. The caller is responsible for calling SecuritiesToken.setSymbol()
     *         first, then calling this function to keep the factory in sync.
     *         Reverts if oldSymbol does not match the factory's current record, or if
     *         newSymbol is already taken by another token.
     */
    function updateSymbol(address token, string calldata oldSymbol, string calldata newSymbol)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (bytes(newSymbol).length == 0) revert EmptyString();
        _validateSymbol(newSymbol);
        if (tokenBySymbol[oldSymbol] != token) {
            revert SymbolMismatch(oldSymbol, "token not registered under oldSymbol");
        }
        if (tokenBySymbol[newSymbol] != address(0)) revert TokenSymbolAlreadyExists(newSymbol);

        delete tokenBySymbol[oldSymbol];
        tokenBySymbol[newSymbol] = token;

        emit SymbolUpdated(token, oldSymbol, newSymbol);
    }
}
