// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Compliance} from "../src/compliance/Compliance.sol";
import {PauseManager} from "../src/pauseManager/PauseManager.sol";
import {SecuritiesTokenFactory} from "../src/securitiesToken/SecuritiesTokenFactory.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";

/**
 * @title  Deploy
 * @notice Full-stack deployment script driven by config.toml.
 *
 *         Usage:
 *           forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast
 *           forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --private-key $PK --broadcast
 *
 *         Steps:
 *           1. Compliance        (non-upgradeable)
 *              - grant OPS_ROLE / COMPLIANCE_ROLE per config (if broadcaster == admin)
 *           2. PauseManager      (non-upgradeable)
 *              - grant OPS_ROLE per config (if broadcaster == admin)
 *           3. SecuritiesTokenFactory
 *              - internally deploys the SecuritiesToken implementation + UpgradeableBeacon
 *              - beacon owner = config.proxyAdmin
 *           4. (optional) factory.deployToken() → BeaconProxy for the first token
 *              triggered when config.toml contains a `[token]` section
 *
 *         Any address field set to address(0) in the config is replaced with the broadcaster.
 *         Role grants and the initial token deploy require DEFAULT_ADMIN_ROLE, so they only
 *         run when the broadcaster is the admin; otherwise the script prints a hint.
 */
contract Deploy is Script {
    using stdToml for string;

    struct Config {
        address admin;
        address proxyAdmin;
        address[] complianceOps;
        address[] complianceCompliance;
        address[] pauseManagerOps;
        bool deployInitialToken;
        string tokenName;
        string tokenSymbol;
        string tokenIdentifier;
        address tokenAdmin;
        address[] issuers;
    }

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
        address broadcaster = _broadcaster();
        bool broadcasterIsAdmin = broadcaster == cfg.admin;

        console.log("=== Deployment ===");
        console.log("Broadcaster:    ", broadcaster);
        console.log("Admin:          ", cfg.admin);
        console.log("Proxy admin:    ", cfg.proxyAdmin);

        vm.startBroadcast();

        compliance = new Compliance(cfg.admin);
        console.log("Compliance:     ", address(compliance));
        _grantRoles(
            address(compliance),
            compliance.OPS_ROLE(),
            "OPS_ROLE (Compliance)",
            cfg.complianceOps,
            broadcasterIsAdmin
        );
        _grantRoles(
            address(compliance),
            compliance.COMPLIANCE_ROLE(),
            "COMPLIANCE_ROLE",
            cfg.complianceCompliance,
            broadcasterIsAdmin
        );

        pauseManager = new PauseManager(cfg.admin);
        console.log("PauseManager:   ", address(pauseManager));
        _grantRoles(
            address(pauseManager),
            pauseManager.OPS_ROLE(),
            "OPS_ROLE (PauseManager)",
            cfg.pauseManagerOps,
            broadcasterIsAdmin
        );

        factory = new SecuritiesTokenFactory(
            address(compliance),
            address(pauseManager),
            cfg.admin,
            cfg.proxyAdmin
        );
        console.log("Factory:        ", address(factory));
        console.log("Beacon:         ", address(factory.beacon()));

        // factory.deployToken requires DEFAULT_ADMIN_ROLE on the factory.
        if (cfg.deployInitialToken) {
            if (broadcasterIsAdmin) {
                initialToken = factory.deployToken(
                    cfg.tokenName,
                    cfg.tokenSymbol,
                    cfg.tokenIdentifier,
                    cfg.tokenAdmin,
                    cfg.issuers
                );
                console.log("Token (proxy):  ", initialToken);
            } else {
                console.log("Skipping initial token: broadcaster != admin.");
                console.log("Run factory.deployToken(...) from admin to mint the first token.");
            }
        }

        vm.stopBroadcast();
    }

    /// Grants `role` on `target` (via AccessControl) to every address in `grantees`.
    /// Falls back to a printed hint when the broadcaster is not the admin.
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
        // AccessControl exposes grantRole(bytes32,address). Encode the call rather than
        // importing the interface so this helper works for both Compliance and PauseManager.
        for (uint256 i = 0; i < grantees.length; ++i) {
            (bool ok,) = target.call(abi.encodeWithSignature("grantRole(bytes32,address)", role, grantees[i]));
            require(ok, string.concat("grantRole failed: ", roleName));
            console.log("  granted", roleName, "to", grantees[i]);
        }
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
        cfg.complianceCompliance = _readAddressArrayOr(toml, ".compliance.complianceRole");
        cfg.pauseManagerOps = _readAddressArrayOr(toml, ".pauseManager.opsRole");

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
