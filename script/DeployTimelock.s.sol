// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Deploys an OpenZeppelin TimelockController. All parameters are passed as CLI args
///         (not read from config.toml) so the same script can deploy multiple, differently
///         configured timelocks.
///
/// Usage:
///   forge script script/DeployTimelock.s.sol:DeployTimelock \
///     --sig "run(uint256,address,address[],address[])" \
///     <minDelay> <admin> "[<proposer1>,<proposer2>]" "[<executor1>]" \
///     --rpc-url $RPC --ledger --sender <ledgerAddr> --broadcast -vvv
contract DeployTimelock is Script {
    /// @param minDelay   lock time in seconds — REQUIRED, must be > 0
    /// @param admin      REQUIRED, must be non-zero; receives DEFAULT_ADMIN_ROLE (OZ TimelockController
    ///                   also self-grants DEFAULT_ADMIN_ROLE to the timelock itself, regardless of this)
    /// @param proposers  PROPOSER_ROLE + CANCELLER_ROLE; may be empty
    /// @param executors  EXECUTOR_ROLE; may be empty (pass "[0x0000000000000000000000000000000000000000]"
    ///                   to allow anyone to execute)
    function run(uint256 minDelay, address admin, address[] calldata proposers, address[] calldata executors)
        external
        returns (TimelockController timelock)
    {
        require(minDelay > 0, "DeployTimelock: minDelay must be > 0");
        require(admin != address(0), "DeployTimelock: admin is zero");

        console.log("=== Deploy TimelockController ===");
        console.log("Broadcaster: ", _broadcaster());
        console.log("minDelay:    ", minDelay);
        console.log("admin:       ", admin);
        console.log("proposers:   ", proposers.length);
        for (uint256 i = 0; i < proposers.length; ++i) {
            console.log("  -", proposers[i]);
        }
        console.log("executors:   ", executors.length);
        for (uint256 i = 0; i < executors.length; ++i) {
            console.log("  -", executors[i]);
        }

        vm.startBroadcast();
        timelock = new TimelockController(minDelay, proposers, executors, admin);
        vm.stopBroadcast();

        console.log("TimelockController: ", address(timelock));
    }

    /// @dev Mirrors forge-script's signer resolution: PRIVATE_KEY env, else tx.origin.
    function _broadcaster() internal view returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return vm.addr(pk);
        return msg.sender;
    }
}
