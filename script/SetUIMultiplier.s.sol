// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";

/**
 * @title  SetUIMultiplier
 * @notice Schedules a UI-multiplier change on a SecuritiesToken — the on-chain primitive
 *         behind stock splits, reverse splits, and accrual events.
 *
 *         The broadcaster must hold DEFAULT_ADMIN_ROLE or ISSUER_ROLE on the token.
 *         On-chain checks:
 *           - 1e9 ≤ newMultiplier ≤ 1e27   (1e18 = 1.0x)
 *           - effectiveAt > block.timestamp
 *           - effectiveAt ≤ block.timestamp + 365 days
 *
 *         Multiplier examples (1e18 fixed-point):
 *           - 2e18 = "2000000000000000000"  → 2-for-1 split   (UI balance doubles)
 *           - 5e17 = "500000000000000000"   → 1-for-2 reverse (UI balance halves)
 *
 *         Usage (relative delay, default):
 *           forge script script/SetUIMultiplier.s.sol \
 *             --sig "run(address,uint256,uint256)" \
 *             <token> <newMultiplier> <delaySeconds> \
 *             --rpc-url $RPC --broadcast
 *
 *         Usage (absolute unix timestamp):
 *           forge script script/SetUIMultiplier.s.sol \
 *             --sig "runAt(address,uint256,uint256)" \
 *             <token> <newMultiplier> <effectiveAt> \
 *             --rpc-url $RPC --broadcast
 */
contract SetUIMultiplier is Script {
    uint256 internal constant ONE_YEAR = 365 days;

    /// Schedule the multiplier change to take effect `delaySeconds` after the broadcast block.
    function run(address token, uint256 newMultiplier, uint256 delaySeconds) external {
        require(delaySeconds > 0, "SetUIMultiplier: delaySeconds must be > 0");
        _schedule(token, newMultiplier, block.timestamp + delaySeconds);
    }

    /// Schedule the multiplier change to take effect at an absolute unix timestamp.
    function runAt(address token, uint256 newMultiplier, uint256 effectiveAt) external {
        _schedule(token, newMultiplier, effectiveAt);
    }

    function _schedule(address tokenAddr, uint256 newMultiplier, uint256 effectiveAt) internal {
        require(tokenAddr != address(0), "SetUIMultiplier: token is zero");
        require(effectiveAt > block.timestamp, "SetUIMultiplier: effectiveAt must be in the future");
        require(effectiveAt <= block.timestamp + ONE_YEAR, "SetUIMultiplier: effectiveAt > 365 days out");

        SecuritiesToken token = SecuritiesToken(tokenAddr);

        console.log("=== SetUIMultiplier ===");
        console.log("Token:            ", tokenAddr);
        console.log("Symbol:           ", token.symbol());
        console.log("Current multiplier:", token.uiMultiplier());
        console.log("New multiplier:   ", newMultiplier);
        console.log("Effective at (ts):", effectiveAt);
        console.log("Seconds from now: ", effectiveAt - block.timestamp);

        vm.startBroadcast();
        token.setUIMultiplier(newMultiplier, effectiveAt);
        vm.stopBroadcast();

        console.log("Scheduled.");
    }
}
