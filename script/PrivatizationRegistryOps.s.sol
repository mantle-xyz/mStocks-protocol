// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrivatizationRegistry} from "../src/privatization/PrivatizationRegistry.sol";
import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";

/// @notice Deploy + operate the upgradeable PrivatizationRegistry (docs/corporate-actions-td.md
///         §4, privatization-runbook.md §2). Deployed behind a TransparentUpgradeableProxy, like
///         TokenIssuer. Each entrypoint is broadcast by the appropriate role — run them in order.
///
///         1)  deploy                 — deployer (proxyAdmin owns upgrades; admin = DEFAULT_ADMIN_ROLE)
///         2)  createProgram          — registry OPS (legs = token + total; program starts Created)
///         3a) wireBurnRole           — OLD token ADMIN (grant registry BURN_ROLE)
///         3b) freezeSupply           — OLD token OPS   (setMintAllowed=false; ≠ admin — self-grant blocked)
///         4)  configureProgram       — registry OPS (supply frozen totalSupply as snapshot + window;
///                                      leave state 0 — any 0 field keeps the stored value)
///         5)  fund                   — registry OPS (holds reward tokens; Created-only)
///         5b) configureProgram       — registry OPS (state=Active; refused until every leg's
///                                      reserve covers its total)
///         6)  registerSweepRecipients — registry ADMIN, before Step 7 (allowlist the sweep destination)
///         7)  sweep                  — registry OPS, after the program deadline; `to` must already
///                                      be on the {registerSweepRecipients} allowlist
///
///         The whole program lifecycle (2/4/5/7) is OPS-driven; registry admin only grants OPS_ROLE
///         and maintains the sweep-recipient allowlist (Step 6).
contract PrivatizationRegistryOps is Script {
    /// @notice Step 1 — deploy behind a TransparentUpgradeableProxy. `proxyAdmin` owns the
    ///         auto-created ProxyAdmin (sole upgrade authority); `admin` gets DEFAULT_ADMIN_ROLE.
    function deploy(address proxyAdmin, address admin, address[] calldata ops) external returns (address registry) {
        require(proxyAdmin != address(0) && admin != address(0), "zero addr");
        vm.startBroadcast();
        PrivatizationRegistry impl = new PrivatizationRegistry();
        bytes memory initData = abi.encodeWithSelector(PrivatizationRegistry.initialize.selector, admin, ops);
        registry = address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, initData));
        vm.stopBroadcast();
        console.log("PrivatizationRegistry impl: ", address(impl));
        console.log("PrivatizationRegistry proxy:", registry);
        console.log("proxyAdmin (upgrade auth):  ", proxyAdmin);
        console.log("admin (DEFAULT_ADMIN_ROLE): ", admin);
        console.log("OPS_ROLE granted at init to", ops.length, "address(es)");
        for (uint256 i = 0; i < ops.length; ++i) {
            console.log("  ", ops[i]);
        }
    }

    /// @notice Step 2a — grant the registry BURN_ROLE on the old token (burn-only: it can burn
    ///         surrendered balances but never mint). Broadcaster must be the OLD token ADMIN
    ///         (DEFAULT_ADMIN_ROLE). Split from {freezeSupply} because that is OPS-gated and the
    ///         admin and OPS must be different accounts (self-grant is blocked).
    function wireBurnRole(address oldToken, address registry) external {
        bytes32 burnRole = ScaledToken(oldToken).BURN_ROLE();
        vm.startBroadcast();
        ScaledToken(oldToken).grantRole(burnRole, registry);
        vm.stopBroadcast();
        console.log("Granted BURN_ROLE to registry on:", oldToken);
    }

    /// @notice Step 2b — freeze the old token's supply so nobody can mint more and dilute the
    ///         fixed-rate consideration. `setMintAllowed` is OPS-gated, so the broadcaster must
    ///         hold the token's OPS_ROLE — a DIFFERENT address than the admin used in {wireBurnRole}.
    function freezeSupply(address oldToken) external {
        vm.startBroadcast();
        ScaledToken(oldToken).setMintAllowed(false);
        vm.stopBroadcast();
        console.log("Froze old supply (setMintAllowed=false):", oldToken);
    }

    /// @notice Step 2 — register a delisting program from parallel reward-leg arrays
    ///         (`tokens[i]` distributing `totals[i]` across the whole old supply). Program starts in
    ///         `Created`; the supply snapshot + claim window are set later by {configureProgram}.
    ///         Broadcaster must hold OPS_ROLE on the registry.
    function createProgram(address registry, address oldToken, address[] calldata tokens, uint256[] calldata totals)
        external
        returns (uint256 programId)
    {
        require(tokens.length == totals.length && tokens.length > 0, "legs mismatch");
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            legs[i] = PrivatizationRegistry.Leg({token: tokens[i], total: totals[i]});
        }
        vm.startBroadcast();
        programId = PrivatizationRegistry(registry).createProgram(oldToken, legs);
        vm.stopBroadcast();
        console.log("createProgram id:", programId);
        console.log("  oldToken:", oldToken);
        console.log("  legs:", tokens.length);
    }

    /// @notice Steps 4 / 5b — configure while Created, then activate only after funding.
    ///         Broadcaster must hold OPS_ROLE. After freezeSupply (Step 3b), set the claim window
    ///         and `oldSupplySnapshot` to the old token's frozen `totalSupply()`, leaving `state` = 0.
    ///         Next fund every reward token to cover its aggregate leg totals (Step 5). Then call
    ///         again with `state` = 2 (Active) and all other patch fields 0 to keep the funded terms.
    ///         This helper never changes `oldToken`; zero-valued patch fields keep stored values.
    function configureProgram(
        address registry,
        uint256 programId,
        uint64 startTime,
        uint64 deadline,
        uint256 oldSupplySnapshot,
        uint8 state
    ) external {
        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: startTime,
            deadline: deadline,
            oldSupplySnapshot: oldSupplySnapshot,
            state: state
        });
        vm.startBroadcast();
        PrivatizationRegistry(registry).configureProgram(programId, cfg);
        vm.stopBroadcast();
        console.log("configureProgram id:", programId);
        console.log("  startTime:", startTime);
        console.log("  deadline: ", deadline);
    }

    /// @notice Step 5 — fund + reserve a reward token for a program. Broadcaster must hold
    ///         OPS_ROLE on the registry and own `amount` of `token`; this approves + funds.
    function fund(address registry, uint256 programId, address token, uint256 amount) external {
        vm.startBroadcast();
        IERC20(token).approve(registry, amount);
        PrivatizationRegistry(registry).fund(programId, token, amount);
        vm.stopBroadcast();
        console.log("Funded program", programId);
        console.log("  token/amount:", token, amount);
        console.log("  reserved now:", PrivatizationRegistry(registry).reserved(programId, token));
    }

    /// @notice Step 6 — allowlist one or more {sweepUnclaimed} destinations. Broadcaster must hold
    ///         DEFAULT_ADMIN_ROLE. Run before Step 7 — sweep reverts NotRegisteredSweepRecipient
    ///         otherwise.
    function registerSweepRecipients(address registry, address[] calldata recipients) external {
        vm.startBroadcast();
        PrivatizationRegistry(registry).registerSweepRecipients(recipients);
        vm.stopBroadcast();
        console.log("Registered", recipients.length, "sweep recipient(s) on", registry);
        for (uint256 i = 0; i < recipients.length; ++i) {
            console.log("  ", recipients[i]);
        }
    }

    /// @notice Remove a {sweepUnclaimed} destination from the allowlist. Broadcaster must hold
    ///         DEFAULT_ADMIN_ROLE.
    function deregisterSweepRecipient(address registry, address to) external {
        vm.startBroadcast();
        PrivatizationRegistry(registry).deregisterSweepRecipient(to);
        vm.stopBroadcast();
        console.log("Deregistered sweep recipient:", to);
    }

    /// @notice Step 7 — after the program deadline, sweep unclaimed reserve to an already-allowlisted
    ///         destination (Step 6). Broadcaster must hold OPS_ROLE.
    function sweep(address registry, uint256 programId, address to) external {
        vm.startBroadcast();
        PrivatizationRegistry(registry).sweepUnclaimed(programId, to);
        vm.stopBroadcast();
        console.log("Swept program", programId);
        console.log("  to:", to);
    }
}
