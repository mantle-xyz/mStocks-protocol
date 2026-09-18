// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WarrantRegistry} from "../src/privatization/WarrantRegistry.sol";

/// @notice Deploy + operate the upgradeable WarrantRegistry ([TD] Privatisation delisting + warrant issuance +
///         leverage records, Part II). Deployed behind a TransparentUpgradeableProxy, like TokenIssuer.
///
///         Warrant flow: deploy → createProgram(token, settlementToken) → configureProgram(root +
///         settleTotal + window, state left 0) → fund up to settleTotal (Created-only) →
///         configureProgram(state=Active; refused until the reserve covers settleTotal) → users
///         claim (off-chain proofs against the root). If settlement terms are not ready, keep the
///         program Created — funding and configuration both close at activation (any 0 field in a
///         patch keeps the stored value).
///
///         Leverage: deploy + createProgram(token, 0) + configureProgram(root + window +
///         state=Active, settlementToken/settleTotal left 0) to anchor the credit-line root
///         on-chain; no fund / claim (settled elsewhere).
///
///         Every entrypoint here (create / configure / fund / sweep) is OPS-driven — admin only
///         manages roles, matching the registry's own role split.
contract WarrantRegistryOps is Script {
    /// @notice Deploy behind a TransparentUpgradeableProxy. `proxyAdmin` owns upgrades; `admin`
    ///         gets DEFAULT_ADMIN_ROLE.
    function deploy(address proxyAdmin, address admin, address[] calldata ops) external returns (address registry) {
        require(proxyAdmin != address(0) && admin != address(0), "zero addr");
        vm.startBroadcast();
        WarrantRegistry impl = new WarrantRegistry();
        bytes memory initData = abi.encodeWithSelector(WarrantRegistry.initialize.selector, admin, ops);
        registry = address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, initData));
        vm.stopBroadcast();
        console.log("WarrantRegistry impl: ", address(impl));
        console.log("WarrantRegistry proxy:", registry);
        console.log("proxyAdmin:           ", proxyAdmin);
        console.log("admin:                ", admin);
        console.log("OPS_ROLE granted at init to", ops.length, "address(es)");
        for (uint256 i = 0; i < ops.length; ++i) {
            console.log("  ", ops[i]);
        }
    }

    /// @notice Register a program. `settlementToken` may be 0 (set later via configureProgram, or
    ///         leave 0 for a leverage record anchor). Broadcaster must hold OPS_ROLE.
    function createProgram(address registry, address token, address settlementToken)
        external
        returns (uint256 programId)
    {
        vm.startBroadcast();
        programId = WarrantRegistry(registry).createProgram(token, settlementToken);
        vm.stopBroadcast();
        console.log("createProgram id:", programId);
        console.log("  token:", token);
        console.log("  settlementToken:", settlementToken);
    }

    /// @notice Patch a program's fields (root / settlement / window / state). Any 0 value in the
    ///         patch keeps the currently-stored value. Broadcaster must hold OPS_ROLE.
    function configureProgram(uint256 programId, address registry, WarrantRegistry.Program calldata patch) external {
        vm.startBroadcast();
        WarrantRegistry(registry).configureProgram(programId, patch);
        vm.stopBroadcast();
        console.log("Configured program", programId);
        console.log("  settlementToken:", patch.settlementToken);
        console.log("  settleTotal:", patch.settleTotal);
        console.log("  window:", patch.startTime, patch.deadline);
        console.log("  state:", patch.state);
    }

    /// @notice Fund + reserve settlement asset for a program. Broadcaster must hold OPS_ROLE and
    ///         own `amount` of the program's settlement token; this approves + funds.
    function fund(address registry, uint256 programId, uint256 amount) external {
        (,, address settlementToken,,,,) = WarrantRegistry(registry).programs(programId);
        require(settlementToken != address(0), "settlement not set");
        vm.startBroadcast();
        IERC20(settlementToken).approve(registry, amount);
        WarrantRegistry(registry).fund(programId, amount);
        vm.stopBroadcast();
        console.log("Funded program", programId, amount);
        console.log("  settleReserve now:", WarrantRegistry(registry).settleReserve(programId));
    }

    /// @notice After the deadline, sweep unclaimed settlement asset to custody. Broadcaster must
    ///         hold OPS_ROLE.
    function sweep(address registry, uint256 programId, address to) external {
        vm.startBroadcast();
        WarrantRegistry(registry).sweepUnclaimed(programId, to);
        vm.stopBroadcast();
        console.log("Swept program", programId);
        console.log("  to:", to);
    }
}
