// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";

/// @notice Schedules a UI-multiplier change on a ScaledToken — the on-chain primitive
///         behind stock splits, reverse splits, and accrual events.
///
///         Broadcaster must hold MULTIPLIER_SCHEDULER_ROLE on the token. On-chain checks:
///           - 1e9 ≤ newMultiplier ≤ 1e27   (1e18 = 1.0x)
///           - effectiveAt > block.timestamp
///           - effectiveAt ≤ block.timestamp + 365 days
///
///         Multiplier examples (1e18 fixed-point):
///           - 2e18 → 2-for-1 split   (UI balance doubles)
///           - 5e17 → 1-for-2 reverse (UI balance halves)
///
///         Usage (relative delay):
///           forge script script/SetUIMultiplier.s.sol \
///             --sig "run(address,uint256,uint256)" \
///             <token> <newMultiplier> <delaySeconds> \
///             --rpc-url $RPC --broadcast
///
///         Usage (absolute unix timestamp):
///           forge script script/SetUIMultiplier.s.sol \
///             --sig "runAt(address,uint256,uint256)" \
///             <token> <newMultiplier> <effectiveAt> \
///             --rpc-url $RPC --broadcast
contract SetUIMultiplier is Script {
    uint256 internal constant ONE_YEAR = 365 days;

    function run(address token, uint256 newMultiplier, uint256 delaySeconds) external {
        require(delaySeconds > 0, "SetUIMultiplier: delaySeconds must be > 0");
        _schedule(token, newMultiplier, block.timestamp + delaySeconds);
    }

    function runAt(address token, uint256 newMultiplier, uint256 effectiveAt) external {
        _schedule(token, newMultiplier, effectiveAt);
    }

    function _schedule(address tokenAddr, uint256 newMultiplier, uint256 effectiveAt) internal {
        require(tokenAddr != address(0), "SetUIMultiplier: token is zero");
        require(effectiveAt > block.timestamp, "SetUIMultiplier: effectiveAt must be in the future");
        require(effectiveAt <= block.timestamp + ONE_YEAR, "SetUIMultiplier: effectiveAt > 365 days out");

        ScaledToken token = ScaledToken(tokenAddr);

        console.log("=== SetUIMultiplier ===");
        console.log("Token:             ", tokenAddr);
        console.log("Symbol:            ", token.symbol());
        console.log("Current multiplier:", token.uiMultiplier());
        console.log("New multiplier:    ", newMultiplier);
        console.log("Effective at (ts): ", effectiveAt);
        console.log("Seconds from now:  ", effectiveAt - block.timestamp);

        vm.startBroadcast();
        token.setUIMultiplier(newMultiplier, effectiveAt);
        vm.stopBroadcast();

        console.log("Scheduled.");
    }
}
