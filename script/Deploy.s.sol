// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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
///   deployPauseRegistry()                   — PauseRegistry
///   deployFactory(address,address)          — ScaledTokenFactory(compliance, pauseRegistry);
///                                              minMultiplierNotice read from [factory] config
///   deployToken(address)                    — BeaconProxy address via factory; must be broadcast
///                                              by a factory OPS signer (createToken is OPS-gated);
///                                              grants the token's OPS_ROLE to [token].opsRole
///   deployTokenIssuer(address[])            — TokenIssuer behind TransparentUpgradeableProxy
///                                              (upgrade authority = auto-created ProxyAdmin
///                                              owned by cfg.proxyAdmin); auto-grants ISSUER_ROLE
///                                              on each passed token to the new issuer
///
/// Admin model (Ledger-first): every freshly deployed contract receives DEFAULT_ADMIN_ROLE on
/// the BROADCASTER (the deploy signer — e.g. a Ledger) so the deploy itself can perform all
/// role grants and createToken without being blocked. `config.finalAdmin` is NOT used at construction;
/// it is the FINAL admin (handover target) — after deploy + wiring, run TransferAdmin.s.sol to
/// grant DEFAULT_ADMIN_ROLE to `config.finalAdmin` and revoke it from the broadcaster.
///
/// `config.proxyAdmin` (beacon owner / proxy upgrade authority) IS set to its final value at
/// deploy — the broadcaster never needs it, so it requires no handover.
///
/// Role grants are gated on the broadcaster actually holding DEFAULT_ADMIN_ROLE on the target
/// (always true on the fresh full-stack path; checked on-chain so standalone re-runs against
/// pre-existing contracts skip gracefully instead of reverting). The initial token deploy
/// (deployToken) is instead gated on the broadcaster holding the factory's OPS_ROLE, since
/// createToken is OPS-gated and no admin backdoor is granted at deploy.
contract Deploy is Script {
    using stdToml for string;

    struct Config {
        // Per-contract FINAL admins (handover targets), read from each [section].finalAdmin.
        // Informational here (deploy uses the broadcaster as the temporary admin); the actual
        // handover is performed by TransferAdmin.s.sol, which REVERTS on a missing/zero value.
        // 0 here just means "not configured yet" for the header printout.
        address complianceAdmin;
        address pauseAdmin;
        address factoryAdmin;
        address tokenIssuerAdmin;
        address proxyAdmin;
        uint256 minMultiplierNotice;
        address[] complianceOps;
        address[] pauseRole;
        address[] unpauseRole;
        address[] tokenIssuerOps;
        address[] tokenIssuerApprovedRecipients;
        address[] factoryOps;
        bool deployInitialToken;
        string tokenName;
        string tokenSymbol;
        string tokenIdentifier;
        address[] issuers;
        address[] multiplierSchedulers;
        address[] tokenOps;
    }

    function run()
        external
        returns (
            ComplianceRegistry compliance,
            PauseRegistry pauseRegistry,
            ScaledTokenFactory factory,
            address initialToken
        )
    {
        Config memory cfg = _loadConfig();
        _printHeader(cfg);

        vm.startBroadcast();
        compliance = _deployCompliance(cfg);
        pauseRegistry = _deployPauseRegistry(cfg);
        factory = _deployFactory(cfg, address(compliance), address(pauseRegistry));
        vm.stopBroadcast();
    }

    function deployCompliance() external returns (ComplianceRegistry compliance) {
        Config memory cfg = _loadConfig();

        vm.startBroadcast();
        compliance = _deployCompliance(cfg);
        vm.stopBroadcast();
    }

    function deployPauseRegistry() external returns (PauseRegistry pauseRegistry) {
        Config memory cfg = _loadConfig();

        vm.startBroadcast();
        pauseRegistry = _deployPauseRegistry(cfg);
        vm.stopBroadcast();
    }

    function deployFactory(address compliance, address pauseRegistry) external returns (ScaledTokenFactory factory) {
        require(compliance != address(0), "Deploy: compliance is zero");
        require(pauseRegistry != address(0), "Deploy: pauseRegistry is zero");
        Config memory cfg = _loadConfig();

        vm.startBroadcast();
        factory = _deployFactory(cfg, compliance, pauseRegistry);
        vm.stopBroadcast();
    }

    function deployToken(address factory) external returns (address proxy) {
        require(factory != address(0), "Deploy: factory is zero");
        Config memory cfg = _loadConfig();
        require(cfg.deployInitialToken, "Deploy: [token] section missing from config");

        vm.startBroadcast();
        proxy = _deployToken(cfg, ScaledTokenFactory(factory));
        vm.stopBroadcast();
    }

    /// @notice Deploys TokenIssuer behind an ERC1967 proxy, grants OPS_ROLE per config, registers
    ///         any pre-configured approved recipients, and grants each `tokens[i]` its ISSUER_ROLE
    ///         to the freshly-deployed issuer. Pass the ScaledToken proxy address(es) the issuer
    ///         should be able to mint/burn — so `[token].issuers` can be left empty. `[tokenIssuer]`
    ///         config is optional.
    function deployTokenIssuer(address[] calldata tokens) external returns (TokenIssuer issuer) {
        Config memory cfg = _loadConfig();

        vm.startBroadcast();
        issuer = _deployTokenIssuer(cfg);
        for (uint256 i = 0; i < tokens.length; ++i) {
            _grantIssuerRole(tokens[i], address(issuer));
        }
        vm.stopBroadcast();
    }

    /// @dev Grants `token`'s ISSUER_ROLE to `issuer`. Requires the broadcaster to hold the token's
    ///      DEFAULT_ADMIN_ROLE (true when the token was created with the broadcaster as temp admin,
    ///      i.e. before TransferAdmin). ISSUER_ROLE is contract-gated, which the issuer proxy
    ///      satisfies. Skips with a hint if the broadcaster is not the token admin.
    function _grantIssuerRole(address token, address issuer) internal {
        if (token == address(0)) return;
        if (!_broadcasterIsAdminOf(token)) {
            console.log("Skipping ISSUER_ROLE grant (broadcaster != token admin) on:", token);
            return;
        }
        ScaledToken(token).grantRole(ScaledToken(token).ISSUER_ROLE(), issuer);
        console.log("  granted ISSUER_ROLE to issuer on token", token);
    }

    function _deployCompliance(Config memory cfg) internal returns (ComplianceRegistry compliance) {
        compliance = new ComplianceRegistry(_deployAdmin());
        console.log("ComplianceRegistry: ", address(compliance));
        _grantRoles(address(compliance), compliance.OPS_ROLE(), "OPS_ROLE (ComplianceRegistry)", cfg.complianceOps);
    }

    function _deployPauseRegistry(Config memory cfg) internal returns (PauseRegistry pauseRegistry) {
        pauseRegistry = new PauseRegistry(_deployAdmin());
        console.log("PauseRegistry:      ", address(pauseRegistry));
        _grantRoles(address(pauseRegistry), pauseRegistry.PAUSE_ROLE(), "PAUSE_ROLE (PauseRegistry)", cfg.pauseRole);
        _grantRoles(
            address(pauseRegistry), pauseRegistry.UNPAUSE_ROLE(), "UNPAUSE_ROLE (PauseRegistry)", cfg.unpauseRole
        );
    }

    function _deployFactory(Config memory cfg, address compliance, address pauseRegistry)
        internal
        returns (ScaledTokenFactory factory)
    {
        // Owner (DEFAULT_ADMIN_ROLE) = deploy admin (broadcaster / Ledger), handed over later.
        // proxyAdmin (beacon owner) = final value from config; no handover needed.
        factory =
            new ScaledTokenFactory(compliance, pauseRegistry, _deployAdmin(), cfg.proxyAdmin, cfg.minMultiplierNotice);
        console.log("Factory:            ", address(factory));
        console.log("Beacon:             ", address(factory.beacon()));
        console.log("MinMultiplierNotice:", cfg.minMultiplierNotice);


        // createToken / rename are OPS_ROLE-gated. Deliberately do NOT self-grant OPS to the deploy
        // admin here — that backdoor would linger until someone remembers to revoke it. Grant only
        // the configured operational addresses; deployToken must be run by a factory OPS signer.
        _grantRoles(address(factory), factory.OPS_ROLE(), "OPS_ROLE (Factory)", cfg.factoryOps);
    }

    function _deployTokenIssuer(Config memory cfg) internal returns (TokenIssuer issuer) {
        TokenIssuer impl = new TokenIssuer();
        // admin = deploy admin (broadcaster / Ledger), handed over later via TransferAdmin.
        bytes memory initData = abi.encodeWithSelector(TokenIssuer.initialize.selector, _deployAdmin());
        issuer = TokenIssuer(payable(address(new TransparentUpgradeableProxy(address(impl), cfg.proxyAdmin, initData))));

        // Auto-created ProxyAdmin address is stored in EIP-1967 admin slot.
        address tokenIssuerProxyAdmin = address(
            uint160(
                uint256(vm.load(address(issuer), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103))
            )
        );
        console.log("TokenIssuer impl:        ", address(impl));
        console.log("TokenIssuer proxy:       ", address(issuer));
        console.log("TokenIssuer ProxyAdmin:  ", tokenIssuerProxyAdmin);
        console.log("  (owner = cfg.proxyAdmin, sole upgrade authority)");

        _grantRoles(address(issuer), issuer.OPS_ROLE(), "OPS_ROLE (TokenIssuer)", cfg.tokenIssuerOps);

        if (cfg.tokenIssuerApprovedRecipients.length > 0) {
            if (!_broadcasterIsAdminOf(address(issuer))) {
                console.log("Skipping approved recipients: broadcaster lacks DEFAULT_ADMIN_ROLE.");
            } else {
                for (uint256 i = 0; i < cfg.tokenIssuerApprovedRecipients.length; ++i) {
                    issuer.addApprovedRecipient(cfg.tokenIssuerApprovedRecipients[i]);
                    console.log("  added approved recipient", cfg.tokenIssuerApprovedRecipients[i]);
                }
            }
        }
    }

    function _deployToken(Config memory cfg, ScaledTokenFactory factory) internal returns (address proxy) {
        // createToken is OPS_ROLE-gated on the factory (no admin backdoor is granted at deploy), so
        // deployToken must be broadcast by a factory OPS signer (an address in [factory].opsRole).
        if (!IAccessControl(address(factory)).hasRole(factory.OPS_ROLE(), _broadcaster())) {
            console.log("Skipping token deploy: broadcaster lacks factory OPS_ROLE (createToken is OPS-gated).");
            console.log("Run deployToken from a factory OPS signer, or add it to [factory].opsRole.");
            return address(0);
        }
        // Create the token with the BROADCASTER as its temporary admin — uniform with every other
        // contract. `[token].finalAdmin` is NOT read here; it is the handover target consumed only
        // by TransferAdmin. Keeping the broadcaster as admin lets deployTokenIssuer auto-grant
        // ISSUER_ROLE afterwards.
        proxy = factory.createToken(
            cfg.tokenName,
            cfg.tokenSymbol,
            cfg.tokenIdentifier,
            _deployAdmin(),
            cfg.issuers,
            cfg.multiplierSchedulers,
            cfg.tokenOps
        );
        console.log("Token (proxy):      ", proxy);
    }

    /// @dev Grants `role` on `target` to every address in `grantees`. Skips with a hint when the
    ///      broadcaster does not hold DEFAULT_ADMIN_ROLE on the target (AccessControl would
    ///      otherwise reject the call). On the fresh full-stack path this is always satisfied
    ///      because the contract was just deployed with the broadcaster as admin.
    function _grantRoles(address target, bytes32 role, string memory roleName, address[] memory grantees) internal {
        if (grantees.length == 0) return;
        if (!_broadcasterIsAdminOf(target)) {
            console.log("Skipping role grants for", roleName, "- broadcaster != admin.");
            return;
        }
        for (uint256 i = 0; i < grantees.length; ++i) {
            (bool ok,) = target.call(abi.encodeWithSignature("grantRole(bytes32,address)", role, grantees[i]));
            require(ok, string.concat("grantRole failed: ", roleName));
            console.log("  granted", roleName, "to", grantees[i]);
        }
    }

    /// @dev True when the broadcaster currently holds DEFAULT_ADMIN_ROLE (bytes32(0)) on `target`.
    function _broadcasterIsAdminOf(address target) internal view returns (bool) {
        return IAccessControl(target).hasRole(bytes32(0), _broadcaster());
    }

    /// @dev The temporary admin every fresh contract is deployed with — the broadcaster (Ledger).
    ///      Handed over to `config.finalAdmin` afterwards via TransferAdmin.s.sol.
    function _deployAdmin() internal view returns (address) {
        return _broadcaster();
    }

    function _printHeader(Config memory cfg) internal view {
        console.log("=== Deployment ===");
        console.log("Broadcaster:        ", _broadcaster());
        console.log("Deploy admin (temp):", _deployAdmin());
        console.log("Proxy admin:        ", cfg.proxyAdmin);
        console.log("-- Final admin targets (0x0 = not set; required before handover) --");
        console.log("  compliance:   ", cfg.complianceAdmin);
        console.log("  pauseRegistry: ", cfg.pauseAdmin);
        console.log("  factory:      ", cfg.factoryAdmin);
        console.log("  tokenIssuer:  ", cfg.tokenIssuerAdmin);
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        string memory path = vm.envOr("DEPLOY_CONFIG_PATH", string("./config.toml"));
        string memory toml = vm.readFile(path);
        address broadcaster = _broadcaster();

        // Final admin (handover target). Zero => broadcaster, i.e. "keep admin on the deployer"
        // (TransferAdmin then no-ops since target == broadcaster).
        // Per-contract final admins read straight from each [section].finalAdmin (no global
        // default, no fallback). 0 = not configured — informational only for the header;
        // TransferAdmin enforces non-zero at handover time.
        cfg.complianceAdmin = _sectionFinalAdmin(toml, ".compliance.finalAdmin");
        cfg.pauseAdmin = _sectionFinalAdmin(toml, ".pauseRegistry.finalAdmin");
        cfg.factoryAdmin = _sectionFinalAdmin(toml, ".factory.finalAdmin");
        cfg.tokenIssuerAdmin = _sectionFinalAdmin(toml, ".tokenIssuer.finalAdmin");

        cfg.proxyAdmin = toml.readAddress(".proxyAdmin");
        if (cfg.proxyAdmin == address(0)) cfg.proxyAdmin = broadcaster;

        // Minimum multiplier-scheduling notice baked into the factory's beacon implementation.
        // Defaults to 24h when the key is absent (validated on-chain: non-zero, <= 365 days).
        cfg.minMultiplierNotice = vm.keyExistsToml(toml, ".factory.minMultiplierNotice")
            ? toml.readUint(".factory.minMultiplierNotice")
            : 24 hours;

        cfg.complianceOps = _readAddressArrayOr(toml, ".compliance.opsRole");
        cfg.pauseRole = _readAddressArrayOr(toml, ".pauseRegistry.pauseRole");
        cfg.unpauseRole = _readAddressArrayOr(toml, ".pauseRegistry.unpauseRole");
        cfg.tokenIssuerOps = _readAddressArrayOr(toml, ".tokenIssuer.opsRole");
        cfg.tokenIssuerApprovedRecipients = _readAddressArrayOr(toml, ".tokenIssuer.approvedRecipients");
        cfg.factoryOps = _readAddressArrayOr(toml, ".factory.opsRole");

        cfg.deployInitialToken = vm.keyExistsToml(toml, ".token");
        if (cfg.deployInitialToken) {
            cfg.tokenName = toml.readString(".token.name");
            cfg.tokenSymbol = toml.readString(".token.symbol");
            cfg.tokenIdentifier = toml.readString(".token.identifier");
            // Note: the token is created with the broadcaster as its temporary admin (see
            // _deployToken). `[token].finalAdmin` is the handover target, read only by
            // TransferAdmin — not here.
            cfg.issuers = _readAddressArrayOr(toml, ".token.issuers");
            cfg.multiplierSchedulers = _readAddressArrayOr(toml, ".token.multiplierSchedulers");
            cfg.tokenOps = _readAddressArrayOr(toml, ".token.opsRole");
        }
    }

    function _readAddressArrayOr(string memory toml, string memory key) internal view returns (address[] memory) {
        return vm.keyExistsToml(toml, key) ? toml.readAddressArray(key) : new address[](0);
    }

    /// @dev Reads a per-section `finalAdmin` (e.g. ".compliance.finalAdmin"), or address(0) when the
    ///      key is absent. Informational for the header only — no fallback; TransferAdmin enforces
    ///      a valid non-zero value at handover time.
    function _sectionFinalAdmin(string memory toml, string memory key) internal view returns (address admin) {
        if (vm.keyExistsToml(toml, key)) admin = toml.readAddress(key);
    }

    /// @dev Mirrors forge-script's signer resolution: PRIVATE_KEY env, else tx.origin.
    function _broadcaster() internal view returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return vm.addr(pk);
        return msg.sender;
    }
}
