// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../src/pauseRegistry/PauseRegistry.sol";
import {ScaledTokenFactory} from "../src/scaledToken/ScaledTokenFactory.sol";
import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";
import {TokenIssuer} from "../src/tokenIssuer/TokenIssuer.sol";

/// @notice Deployment entry points, driven by config.toml.
///
/// Entry points (use --sig to pick which one):
///   run()                                   — full stack + optional initial token
///   deployCompliance()                      — ComplianceRegistry
///   deployPauseManager()                    — PauseRegistry
///   deployFactory(address,address)          — ScaledTokenFactory(compliance, pauseRegistry);
///                                              minMultiplierNotice read from [factory] config
///   deployToken(address)                    — BeaconProxy address via factory
///   deployTokenIssuer()                     — TokenIssuer behind TransparentUpgradeableProxy
///                                              (upgrade authority = auto-created ProxyAdmin
///                                              owned by cfg.proxyAdmin)
///
/// Address fields in config.toml that are address(0) fall back to the broadcaster.
/// Role grants and initial token deploy require DEFAULT_ADMIN_ROLE on the target; if the
/// broadcaster is not the admin they are skipped (not reverted) with a console hint.
contract Deploy is Script {
    using stdToml for string;

    struct Config {
        address admin;
        address proxyAdmin;
        uint256 minMultiplierNotice;
        address[] complianceOps;
        address[] pauseOps;
        address[] tokenIssuerOps;
        address[] tokenIssuerApprovedRecipients;
        bool deployInitialToken;
        string tokenName;
        string tokenSymbol;
        string tokenIdentifier;
        address tokenAdmin;
        address[] issuers;
        address[] multiplierSchedulers;
    }

    function run()
        external
        returns (
            ComplianceRegistry compliance,
            PauseRegistry pauseManager,
            ScaledTokenFactory factory,
            address initialToken
        )
    {
        Config memory cfg = _loadConfig();
        bool broadcasterIsAdmin = _broadcaster() == cfg.admin;
        _printHeader(cfg);

        vm.startBroadcast();
        compliance = _deployCompliance(cfg, broadcasterIsAdmin);
        pauseManager = _deployPauseManager(cfg, broadcasterIsAdmin);
        factory = _deployFactory(cfg, address(compliance), address(pauseManager));
        if (cfg.deployInitialToken) {
            initialToken = _deployToken(cfg, factory, broadcasterIsAdmin);
        }
        vm.stopBroadcast();
    }

    function deployCompliance() external returns (ComplianceRegistry compliance) {
        Config memory cfg = _loadConfig();
        bool broadcasterIsAdmin = _broadcaster() == cfg.admin;

        vm.startBroadcast();
        compliance = _deployCompliance(cfg, broadcasterIsAdmin);
        vm.stopBroadcast();
    }

    function deployPauseManager() external returns (PauseRegistry pauseManager) {
        Config memory cfg = _loadConfig();
        bool broadcasterIsAdmin = _broadcaster() == cfg.admin;

        vm.startBroadcast();
        pauseManager = _deployPauseManager(cfg, broadcasterIsAdmin);
        vm.stopBroadcast();
    }

    function deployFactory(address compliance, address pauseManager)
        external
        returns (ScaledTokenFactory factory)
    {
        require(compliance != address(0), "Deploy: compliance is zero");
        require(pauseManager != address(0), "Deploy: pauseManager is zero");
        Config memory cfg = _loadConfig();

        vm.startBroadcast();
        factory = _deployFactory(cfg, compliance, pauseManager);
        vm.stopBroadcast();
    }

    function deployToken(address factory) external returns (address proxy) {
        require(factory != address(0), "Deploy: factory is zero");
        Config memory cfg = _loadConfig();
        require(cfg.deployInitialToken, "Deploy: [token] section missing from config");
        bool broadcasterIsAdmin = _broadcaster() == cfg.admin;

        vm.startBroadcast();
        proxy = _deployToken(cfg, ScaledTokenFactory(factory), broadcasterIsAdmin);
        vm.stopBroadcast();
    }

    /// @notice Deploys TokenIssuer behind an ERC1967 proxy, grants OPS_ROLE per config, and
    ///         registers any pre-configured approved recipients. `[tokenIssuer]` is optional.
    function deployTokenIssuer() external returns (TokenIssuer issuer) {
        Config memory cfg = _loadConfig();
        bool broadcasterIsAdmin = _broadcaster() == cfg.admin;

        vm.startBroadcast();
        issuer = _deployTokenIssuer(cfg, broadcasterIsAdmin);
        vm.stopBroadcast();
    }

    function _deployCompliance(Config memory cfg, bool broadcasterIsAdmin)
        internal
        returns (ComplianceRegistry compliance)
    {
        compliance = new ComplianceRegistry(cfg.admin);
        console.log("ComplianceRegistry: ", address(compliance));
        _grantRoles(
            address(compliance),
            compliance.OPS_ROLE(),
            "OPS_ROLE (ComplianceRegistry)",
            cfg.complianceOps,
            broadcasterIsAdmin
        );
    }

    function _deployPauseManager(Config memory cfg, bool broadcasterIsAdmin)
        internal
        returns (PauseRegistry pauseManager)
    {
        pauseManager = new PauseRegistry(cfg.admin);
        console.log("PauseRegistry:      ", address(pauseManager));
        _grantRoles(
            address(pauseManager),
            pauseManager.OPS_ROLE(),
            "OPS_ROLE (PauseRegistry)",
            cfg.pauseOps,
            broadcasterIsAdmin
        );
    }

    function _deployFactory(Config memory cfg, address compliance, address pauseManager)
        internal
        returns (ScaledTokenFactory factory)
    {
        factory = new ScaledTokenFactory(
            compliance, pauseManager, cfg.admin, cfg.proxyAdmin, cfg.minMultiplierNotice
        );
        console.log("Factory:            ", address(factory));
        console.log("Beacon:             ", address(factory.beacon()));
        console.log("MinMultiplierNotice:", cfg.minMultiplierNotice);
    }

    function _deployTokenIssuer(Config memory cfg, bool broadcasterIsAdmin)
        internal
        returns (TokenIssuer issuer)
    {
        TokenIssuer impl = new TokenIssuer();
        bytes memory initData = abi.encodeWithSelector(TokenIssuer.initialize.selector, cfg.admin);
        issuer = TokenIssuer(payable(address(
            new TransparentUpgradeableProxy(address(impl), cfg.proxyAdmin, initData)
        )));

        // Auto-created ProxyAdmin address is stored in EIP-1967 admin slot.
        address tokenIssuerProxyAdmin = address(uint160(uint256(
            vm.load(address(issuer), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103)
        )));
        console.log("TokenIssuer impl:        ", address(impl));
        console.log("TokenIssuer proxy:       ", address(issuer));
        console.log("TokenIssuer ProxyAdmin:  ", tokenIssuerProxyAdmin);
        console.log("  (owner = cfg.proxyAdmin, sole upgrade authority)");

        _grantRoles(
            address(issuer),
            issuer.OPS_ROLE(),
            "OPS_ROLE (TokenIssuer)",
            cfg.tokenIssuerOps,
            broadcasterIsAdmin
        );

        if (cfg.tokenIssuerApprovedRecipients.length > 0) {
            if (!broadcasterIsAdmin) {
                console.log("Skipping approved recipients: broadcaster != admin.");
            } else {
                for (uint256 i = 0; i < cfg.tokenIssuerApprovedRecipients.length; ++i) {
                    issuer.addApprovedRecipient(cfg.tokenIssuerApprovedRecipients[i]);
                    console.log("  added approved recipient", cfg.tokenIssuerApprovedRecipients[i]);
                }
            }
        }
    }

    function _deployToken(Config memory cfg, ScaledTokenFactory factory, bool broadcasterIsAdmin)
        internal
        returns (address proxy)
    {
        if (!broadcasterIsAdmin) {
            console.log("Skipping token deploy: broadcaster != admin.");
            console.log("Run factory.createToken(...) from admin instead.");
            return address(0);
        }
        proxy = factory.createToken(
            cfg.tokenName,
            cfg.tokenSymbol,
            cfg.tokenIdentifier,
            cfg.tokenAdmin,
            cfg.issuers,
            cfg.multiplierSchedulers
        );
        console.log("Token (proxy):      ", proxy);
    }

    /// @dev Grants `role` on `target` to every address in `grantees`. Skips with a hint when
    ///      the broadcaster is not the admin (AccessControl would otherwise reject the call).
    function _grantRoles(
        address target,
        bytes32 role,
        string memory roleName,
        address[] memory grantees,
        bool broadcasterIsAdmin
    ) internal {
        if (grantees.length == 0) return;
        if (!broadcasterIsAdmin) {
            console.log("Skipping role grants for", roleName, "- broadcaster != admin.");
            return;
        }
        for (uint256 i = 0; i < grantees.length; ++i) {
            (bool ok,) = target.call(abi.encodeWithSignature("grantRole(bytes32,address)", role, grantees[i]));
            require(ok, string.concat("grantRole failed: ", roleName));
            console.log("  granted", roleName, "to", grantees[i]);
        }
    }

    function _printHeader(Config memory cfg) internal view {
        console.log("=== Deployment ===");
        console.log("Broadcaster:    ", _broadcaster());
        console.log("Admin:          ", cfg.admin);
        console.log("Proxy admin:    ", cfg.proxyAdmin);
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        string memory path = vm.envOr("DEPLOY_CONFIG_PATH", string("./config.toml"));
        string memory toml = vm.readFile(path);
        address broadcaster = _broadcaster();

        cfg.admin = toml.readAddress(".admin");
        if (cfg.admin == address(0)) cfg.admin = broadcaster;

        cfg.proxyAdmin = toml.readAddress(".proxyAdmin");
        if (cfg.proxyAdmin == address(0)) cfg.proxyAdmin = broadcaster;

        // Minimum multiplier-scheduling notice baked into the factory's beacon implementation.
        // Defaults to 24h when the key is absent (validated on-chain: non-zero, <= 365 days).
        cfg.minMultiplierNotice = vm.keyExistsToml(toml, ".factory.minMultiplierNotice")
            ? toml.readUint(".factory.minMultiplierNotice")
            : 24 hours;

        cfg.complianceOps = _readAddressArrayOr(toml, ".compliance.opsRole");
        cfg.pauseOps = _readAddressArrayOr(toml, ".pauseManager.opsRole");
        cfg.tokenIssuerOps = _readAddressArrayOr(toml, ".tokenIssuer.opsRole");
        cfg.tokenIssuerApprovedRecipients = _readAddressArrayOr(toml, ".tokenIssuer.approvedRecipients");

        cfg.deployInitialToken = vm.keyExistsToml(toml, ".token");
        if (cfg.deployInitialToken) {
            cfg.tokenName = toml.readString(".token.name");
            cfg.tokenSymbol = toml.readString(".token.symbol");
            cfg.tokenIdentifier = toml.readString(".token.identifier");

            cfg.tokenAdmin = vm.keyExistsToml(toml, ".token.admin")
                ? toml.readAddress(".token.admin")
                : address(0);
            if (cfg.tokenAdmin == address(0)) cfg.tokenAdmin = cfg.admin;

            cfg.issuers = _readAddressArrayOr(toml, ".token.issuers");
            cfg.multiplierSchedulers = _readAddressArrayOr(toml, ".token.multiplierSchedulers");
        }
    }

    function _readAddressArrayOr(string memory toml, string memory key)
        internal
        view
        returns (address[] memory)
    {
        return vm.keyExistsToml(toml, key) ? toml.readAddressArray(key) : new address[](0);
    }

    /// @dev Mirrors forge-script's signer resolution: PRIVATE_KEY env, else tx.origin.
    function _broadcaster() internal view returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return vm.addr(pk);
        return msg.sender;
    }
}
