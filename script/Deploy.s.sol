// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Compliance} from "../src/compliance/Compliance.sol";
import {PauseManager} from "../src/pauseManager/PauseManager.sol";
import {SecuritiesTokenFactory} from "../src/securitiesToken/SecuritiesTokenFactory.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";
import {CexTokenIssuer} from "../src/tokenIssuer/CexTokenIssuer.sol";

/**
 * @title  Deploy
 * @notice Deployment entry points, driven by config.toml.
 *
 *         Entry points (use --sig to pick which one):
 *
 *           run()
 *             Deploys the full stack: Compliance, PauseManager, Factory, and (if a
 *             [token] section exists) one initial BeaconProxy token. Role grants /
 *             initial token are skipped gracefully when broadcaster != admin.
 *
 *           deployCompliance()                    → Compliance
 *           deployPauseManager()                  → PauseManager
 *           deployFactory(address, address)       → SecuritiesTokenFactory
 *             args: compliance, pauseManager
 *           deployToken(address)                  → BeaconProxy address
 *             arg:  factory
 *
 *         All address fields set to address(0) in config.toml fall back to the broadcaster.
 *         Role grants and the initial token deploy require DEFAULT_ADMIN_ROLE on the target
 *         and are skipped (not reverted) when the broadcaster is not the admin.
 *
 *         Examples:
 *           forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast
 *
 *           forge script script/Deploy.s.sol:Deploy --sig "deployCompliance()" \
 *             --rpc-url $RPC --broadcast
 *
 *           forge script script/Deploy.s.sol:Deploy \
 *             --sig "deployFactory(address,address)" 0xCompliance 0xPauseManager \
 *             --rpc-url $RPC --broadcast
 *
 *           forge script script/Deploy.s.sol:Deploy \
 *             --sig "deployToken(address)" 0xFactory \
 *             --rpc-url $RPC --broadcast
 */
contract Deploy is Script {
    using stdToml for string;

    struct Config {
        address admin;
        address proxyAdmin;
        address[] complianceOps;
        address[] pauseManagerOps;
        address[] cexTokenIssuerOps;
        address[] cexTokenIssuerHotWallets;
        bool deployInitialToken;
        string tokenName;
        string tokenSymbol;
        string tokenIdentifier;
        address tokenAdmin;
        address[] issuers;
        address[] operators;
    }

    // ═══════════════════════════════════════════════
    //                Public entry points
    // ═══════════════════════════════════════════════

    /// Full-stack deploy: Compliance → PauseManager → Factory → (optional) initial token.
    function run()
        external
        returns (
            Compliance compliance,
            PauseManager pauseManager,
            SecuritiesTokenFactory factory,
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

    /// Deploy Compliance + apply role grants from config.
    function deployCompliance() external returns (Compliance compliance) {
        Config memory cfg = _loadConfig();
        bool broadcasterIsAdmin = _broadcaster() == cfg.admin;

        vm.startBroadcast();
        compliance = _deployCompliance(cfg, broadcasterIsAdmin);
        vm.stopBroadcast();
    }

    /// Deploy PauseManager + apply role grants from config.
    function deployPauseManager() external returns (PauseManager pauseManager) {
        Config memory cfg = _loadConfig();
        bool broadcasterIsAdmin = _broadcaster() == cfg.admin;

        vm.startBroadcast();
        pauseManager = _deployPauseManager(cfg, broadcasterIsAdmin);
        vm.stopBroadcast();
    }

    /// Deploy the factory, pointing at already-deployed compliance + pauseManager.
    function deployFactory(address compliance, address pauseManager)
        external
        returns (SecuritiesTokenFactory factory)
    {
        require(compliance != address(0), "Deploy: compliance is zero");
        require(pauseManager != address(0), "Deploy: pauseManager is zero");
        Config memory cfg = _loadConfig();

        vm.startBroadcast();
        factory = _deployFactory(cfg, compliance, pauseManager);
        vm.stopBroadcast();
    }

    /// Deploy a single BeaconProxy token through an existing factory, using the [token] config.
    function deployToken(address factory) external returns (address proxy) {
        require(factory != address(0), "Deploy: factory is zero");
        Config memory cfg = _loadConfig();
        require(cfg.deployInitialToken, "Deploy: [token] section missing from config");
        bool broadcasterIsAdmin = _broadcaster() == cfg.admin;

        vm.startBroadcast();
        proxy = _deployToken(cfg, SecuritiesTokenFactory(factory), broadcasterIsAdmin);
        vm.stopBroadcast();
    }

    /// Deploy an CexTokenIssuer behind an ERC1967 proxy, grant OPS_ROLE per config, and
    /// register any pre-configured hot wallets. `[cexTokenIssuer]` config section is optional.
    function deployCexTokenIssuer() external returns (CexTokenIssuer wallet) {
        Config memory cfg = _loadConfig();
        bool broadcasterIsAdmin = _broadcaster() == cfg.admin;

        vm.startBroadcast();
        wallet = _deployCexTokenIssuer(cfg, broadcasterIsAdmin);
        vm.stopBroadcast();
    }

    // ═══════════════════════════════════════════════
    //                Internal deploys
    // ═══════════════════════════════════════════════

    function _deployCompliance(Config memory cfg, bool broadcasterIsAdmin)
        internal
        returns (Compliance compliance)
    {
        compliance = new Compliance(cfg.admin);
        console.log("Compliance:     ", address(compliance));
        _grantRoles(
            address(compliance),
            compliance.OPS_ROLE(),
            "OPS_ROLE (Compliance)",
            cfg.complianceOps,
            broadcasterIsAdmin
        );
    }

    function _deployPauseManager(Config memory cfg, bool broadcasterIsAdmin)
        internal
        returns (PauseManager pauseManager)
    {
        pauseManager = new PauseManager(cfg.admin);
        console.log("PauseManager:   ", address(pauseManager));
        _grantRoles(
            address(pauseManager),
            pauseManager.OPS_ROLE(),
            "OPS_ROLE (PauseManager)",
            cfg.pauseManagerOps,
            broadcasterIsAdmin
        );
    }

    function _deployFactory(Config memory cfg, address compliance, address pauseManager)
        internal
        returns (SecuritiesTokenFactory factory)
    {
        factory = new SecuritiesTokenFactory(compliance, pauseManager, cfg.admin, cfg.proxyAdmin);
        console.log("Factory:        ", address(factory));
        console.log("Beacon:         ", address(factory.beacon()));
    }

    /// Deploys CexTokenIssuer behind an ERC1967 proxy + applies config-driven grants
    /// and hot wallets. Grants / hot wallets are skipped if broadcaster != admin (the
    /// wallet's admin is `cfg.admin`).
    function _deployCexTokenIssuer(Config memory cfg, bool broadcasterIsAdmin)
        internal
        returns (CexTokenIssuer wallet)
    {
        CexTokenIssuer impl = new CexTokenIssuer();
        bytes memory initData = abi.encodeWithSelector(CexTokenIssuer.initialize.selector, cfg.admin);
        wallet = CexTokenIssuer(payable(address(new ERC1967Proxy(address(impl), initData))));
        console.log("CexTokenIssuer impl:  ", address(impl));
        console.log("CexTokenIssuer proxy: ", address(wallet));

        _grantRoles(
            address(wallet),
            wallet.OPS_ROLE(),
            "OPS_ROLE (CexTokenIssuer)",
            cfg.cexTokenIssuerOps,
            broadcasterIsAdmin
        );

        if (cfg.cexTokenIssuerHotWallets.length > 0) {
            if (!broadcasterIsAdmin) {
                console.log("Skipping initial hot wallets: broadcaster != admin.");
            } else {
                for (uint256 i = 0; i < cfg.cexTokenIssuerHotWallets.length; ++i) {
                    wallet.addHotWallet(cfg.cexTokenIssuerHotWallets[i]);
                    console.log("  added hot wallet", cfg.cexTokenIssuerHotWallets[i]);
                }
            }
        }
    }

    /// Mints the initial token via `factory.deployToken`. Requires DEFAULT_ADMIN_ROLE on
    /// the factory, so it skips with a hint when broadcaster != admin.
    function _deployToken(Config memory cfg, SecuritiesTokenFactory factory, bool broadcasterIsAdmin)
        internal
        returns (address proxy)
    {
        if (!broadcasterIsAdmin) {
            console.log("Skipping token deploy: broadcaster != admin.");
            console.log("Run factory.deployToken(...) from admin instead.");
            return address(0);
        }
        proxy = factory.deployToken(
            cfg.tokenName,
            cfg.tokenSymbol,
            cfg.tokenIdentifier,
            cfg.tokenAdmin,
            cfg.issuers,
            cfg.operators
        );
        console.log("Token (proxy):  ", proxy);
    }

    // ═══════════════════════════════════════════════
    //                Helpers
    // ═══════════════════════════════════════════════

    /// Grants `role` on `target` to every address in `grantees`. Skips with a hint when
    /// the broadcaster is not the admin (since AccessControl will reject the call).
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

        cfg.complianceOps = _readAddressArrayOr(toml, ".compliance.opsRole");
        cfg.pauseManagerOps = _readAddressArrayOr(toml, ".pauseManager.opsRole");
        cfg.cexTokenIssuerOps = _readAddressArrayOr(toml, ".cexTokenIssuer.opsRole");
        cfg.cexTokenIssuerHotWallets = _readAddressArrayOr(toml, ".cexTokenIssuer.hotWallets");

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
            cfg.operators = _readAddressArrayOr(toml, ".token.operators");
        }
    }

    function _readAddressArrayOr(string memory toml, string memory key)
        internal
        view
        returns (address[] memory)
    {
        return vm.keyExistsToml(toml, key) ? toml.readAddressArray(key) : new address[](0);
    }

    /// Mirrors forge-script's signer resolution: prefer PRIVATE_KEY env, else fall back to
    /// the default tx.origin used by Script.
    function _broadcaster() internal view returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return vm.addr(pk);
        return msg.sender;
    }
}
