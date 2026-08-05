// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WarrantRegistry} from "../src/privatization/WarrantRegistry.sol";

/// @notice Deploy + operate the upgradeable WarrantRegistry (docs/corporate-actions-td.md §7).
///         Deployed behind a TransparentUpgradeableProxy, like TokenIssuer.
///
///         Warrant flow: deploy → createProgram(root, settlementToken, settleRate, deadline) →
///         fund → users claim (off-chain proofs against the root). If settlement resolves later:
///         createProgram with settlementToken=0, then configureSettlement + fund when ready.
///
///         配资 (leverage): just deploy + createProgram(root, 0, 0, deadline) to anchor the
///         credit-line root on-chain; no fund / claim (settled elsewhere).
contract WarrantRegistryOps is Script {
    /// @notice Deploy behind a TransparentUpgradeableProxy. `proxyAdmin` owns upgrades; `admin`
    ///         gets DEFAULT_ADMIN_ROLE.
    function deploy(address proxyAdmin, address admin) external returns (address registry) {
        require(proxyAdmin != address(0) && admin != address(0), "zero addr");
        vm.startBroadcast();
        WarrantRegistry impl = new WarrantRegistry();
        bytes memory initData = abi.encodeWithSelector(WarrantRegistry.initialize.selector, admin);
        registry = address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, initData));
        vm.stopBroadcast();
        console.log("WarrantRegistry impl: ", address(impl));
        console.log("WarrantRegistry proxy:", registry);
        console.log("proxyAdmin:           ", proxyAdmin);
        console.log("admin:                ", admin);
    }

    /// @notice Register a program from a record-date snapshot root. `settlementToken` may be 0
    ///         (set later via configureSettlement, or leave 0 for a 配资 record anchor).
    ///         Broadcaster must hold DEFAULT_ADMIN_ROLE.
    function createProgram(address registry, bytes32 root, address settlementToken, uint256 settleRate, uint64 deadline)
        external
        returns (uint256 programId)
    {
        vm.startBroadcast();
        programId = WarrantRegistry(registry).createProgram(root, settlementToken, settleRate, deadline);
        vm.stopBroadcast();
        console.log("createProgram id:", programId);
        console.log("  settlementToken:", settlementToken);
        console.log("  settleRate:", settleRate);
        console.log("  deadline:", deadline);
    }

    /// @notice Set / update the convertible settlement asset (e.g. once a milestone resolves).
    ///         Broadcaster must hold DEFAULT_ADMIN_ROLE.
    function configureSettlement(address registry, uint256 programId, address token, uint256 rate) external {
        vm.startBroadcast();
        WarrantRegistry(registry).configureSettlement(programId, token, rate);
        vm.stopBroadcast();
        console.log("Configured settlement for program", programId);
        console.log("  token/rate:", token, rate);
    }

    /// @notice Fund + reserve settlement U for a program. Broadcaster must hold OPS_ROLE and own
    ///         `amount` of the program's settlement token; this approves + funds.
    function fund(address registry, uint256 programId, uint256 amount) external {
        (, address settlementToken,,,) = WarrantRegistry(registry).programs(programId);
        require(settlementToken != address(0), "settlement not set");
        vm.startBroadcast();
        IERC20(settlementToken).approve(registry, amount);
        WarrantRegistry(registry).fund(programId, amount);
        vm.stopBroadcast();
        console.log("Funded program", programId, amount);
        console.log("  settleReserve now:", WarrantRegistry(registry).settleReserve(programId));
    }

    /// @notice After the deadline, sweep unclaimed settlement U to custody. Broadcaster must hold
    ///         DEFAULT_ADMIN_ROLE.
    function sweep(address registry, uint256 programId, address to) external {
        vm.startBroadcast();
        WarrantRegistry(registry).sweepUnclaimed(programId, to);
        vm.stopBroadcast();
        console.log("Swept program", programId);
        console.log("  to:", to);
    }
}
