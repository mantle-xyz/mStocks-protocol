// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {CustodyClaimRouter} from "../src/privatization/CustodyClaimRouter.sol";

/// @notice Deploy + operate the CustodyClaimRouter (docs/corporate-actions-td.md §5.1) — the
///         bridge that lets CEX hot wallets (transfer-only) take part in a privatization claim.
///         The router is NOT upgradeable (plain constructor, immutable registry ref). Each
///         entrypoint is broadcast by the appropriate role — run them in order.
///
///         0) (prereq) whitelist the router on the ComplianceRegistry so it can receive/send the
///            old token and any reward mStock legs (compliance ops — separate script).
///         1) deploy             — deployer (admin = DEFAULT_ADMIN_ROLE on the router)
///         2) grantOps           — router admin (delegate OPS_ROLE to the operator)
///         3) registerHotWallets — router admin (allowlist the CEX hot wallets)
///         4) claimFor           — OPS (after a hot wallet has transferred old tokens into router)
///         5) rescue             — router admin (recover stray / unclaimed assets)
contract CustodyClaimRouterOps is Script {
    /// @notice Step 1 — deploy the router bound to `registry`; `admin` gets DEFAULT_ADMIN_ROLE
    ///         (maintains the hot-wallet allowlist and can rescue). OPS_ROLE is granted separately.
    function deploy(address registry, address admin) external returns (address router) {
        require(registry != address(0) && admin != address(0), "zero addr");
        vm.startBroadcast();
        router = address(new CustodyClaimRouter(registry, admin));
        vm.stopBroadcast();
        console.log("CustodyClaimRouter:        ", router);
        console.log("  registry:                ", registry);
        console.log("  admin (DEFAULT_ADMIN):   ", admin);
        console.log("  NOTE: whitelist this router on the ComplianceRegistry before use.");
    }

    /// @notice Step 2 — delegate OPS_ROLE to the operator that will drive claims. Broadcaster must
    ///         hold DEFAULT_ADMIN_ROLE on the router (self-grant is blocked, so use a separate ops).
    function grantOps(address router, address ops) external {
        vm.startBroadcast();
        CustodyClaimRouter(router).grantRole(CustodyClaimRouter(router).OPS_ROLE(), ops);
        vm.stopBroadcast();
        console.log("Granted router OPS_ROLE to:", ops);
    }

    /// @notice Step 3 — allowlist the CEX hot wallets that `claimFor` is allowed to pay.
    ///         Broadcaster must hold DEFAULT_ADMIN_ROLE.
    function registerHotWallets(address router, address[] calldata hotWallets) external {
        require(hotWallets.length > 0, "no hot wallets");
        vm.startBroadcast();
        CustodyClaimRouter(router).registerHotWallets(hotWallets);
        vm.stopBroadcast();
        console.log("Registered hot wallets:", hotWallets.length);
        for (uint256 i = 0; i < hotWallets.length; ++i) {
            console.log("  ", hotWallets[i]);
        }
    }

    /// @notice Step 3b — remove a hot wallet from the allowlist. Broadcaster = router admin.
    function deregisterHotWallet(address router, address hotWallet) external {
        vm.startBroadcast();
        CustodyClaimRouter(router).deregisterHotWallet(hotWallet);
        vm.stopBroadcast();
        console.log("Deregistered hot wallet:", hotWallet);
    }

    /// @notice Step 4 — after `hotWallet` has transferred `amount` of the program's old token into
    ///         the router, claim it and forward the reward basket back to `hotWallet`, atomically.
    ///         Broadcaster must hold OPS_ROLE on the router.
    function claimFor(address router, uint256 programId, address hotWallet, uint256 amount) external {
        vm.startBroadcast();
        CustodyClaimRouter(router).claimFor(programId, hotWallet, amount);
        vm.stopBroadcast();
        console.log("claimFor program", programId);
        console.log("  hotWallet:", hotWallet);
        console.log("  oldAmount:", amount);
    }

    /// @notice Step 5 — recover `amount` of `token` from the router (transferred in but never
    ///         claimed, or sent by mistake). Broadcaster must hold DEFAULT_ADMIN_ROLE.
    function rescue(address router, address token, address to, uint256 amount) external {
        vm.startBroadcast();
        CustodyClaimRouter(router).rescue(token, to, amount);
        vm.stopBroadcast();
        console.log("Rescued from router:");
        console.log("  token/amount:", token, amount);
        console.log("  to:", to);
    }
}
