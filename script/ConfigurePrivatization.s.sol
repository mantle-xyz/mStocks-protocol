// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TokenIssuer} from "../src/tokenIssuer/TokenIssuer.sol";
import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";

/// @notice Operational entrypoints for the 方案二 privatization / delisting flow (extending an
///         existing TokenIssuer). See docs/privatization-runbook.md §3. Each entrypoint is
///         broadcast by the appropriate role — run them in order.
///
///         Rates are per RATE_SCALE (1e18) of OLD-token raw. With both tokens at multiplier
///         1.0: newRate = k*1e18 (k new per old), usdcRate = p (USDC raw per old share).
///
///         1) freezeSupply   — OLD token admin
///         2) configure      — issuer admin (DEFAULT_ADMIN_ROLE)
///         3) fund           — OPS (holds USDC)
///         4) sweep / close  — issuer admin, after the deadline
contract ConfigurePrivatization is Script {
    /// @notice Step 1 — freeze the old security's supply so the conversion base is fixed.
    function freezeSupply(address oldToken) external {
        vm.startBroadcast();
        ScaledToken(oldToken).setMintAllowed(false);
        vm.stopBroadcast();
        console.log("Froze mint on old token:", oldToken);
    }

    /// @notice Step 2 — configure the privatization on `issuer`. `newToken`/`usdc` may be zero
    ///         for cash-only / stock-only events (with a non-zero rate on the configured leg).
    function configure(
        address issuer,
        address oldToken,
        address newToken,
        address usdc,
        uint256 newRate,
        uint256 usdcRate,
        uint256 deadline
    ) external {
        require(oldToken != address(0), "oldToken zero");
        require(deadline > block.timestamp, "deadline in past");

        console.log("=== configurePrivatization ===");
        console.log("issuer:  ", issuer);
        console.log("oldToken:", oldToken);
        console.log("newToken:", newToken);
        console.log("usdc:    ", usdc);
        console.log("newRate: ", newRate);
        console.log("usdcRate:", usdcRate);
        console.log("deadline:", deadline);

        vm.startBroadcast();
        TokenIssuer(issuer).configurePrivatization(oldToken, newToken, usdc, newRate, usdcRate, uint64(deadline));
        vm.stopBroadcast();
        console.log("Configured.");
    }

    /// @notice Step 3 — fund + reserve USDC for the event. Broadcaster must hold OPS_ROLE on the
    ///         issuer and own `amount` of USDC; this approves the issuer and deposits in one tx.
    function fund(address issuer, address oldToken, address usdc, uint256 amount) external {
        vm.startBroadcast();
        IERC20(usdc).approve(issuer, amount);
        TokenIssuer(issuer).depositPrivatizationCash(oldToken, amount);
        vm.stopBroadcast();
        console.log("Funded + reserved USDC:", amount);
        console.log("usdcReserved now:", TokenIssuer(issuer).usdcReserved(oldToken));
    }

    /// @notice Step 4a — after the deadline, sweep the unclaimed reserved USDC to custody and
    ///         close the event. Broadcaster must hold DEFAULT_ADMIN_ROLE on the issuer.
    function sweep(address issuer, address oldToken, address to) external {
        vm.startBroadcast();
        TokenIssuer(issuer).sweepUnclaimed(oldToken, to);
        vm.stopBroadcast();
        console.log("Swept unclaimed USDC to:", to);
    }

    /// @notice Step 4b (optional) — stop further claims early without sweeping.
    function close(address issuer, address oldToken) external {
        vm.startBroadcast();
        TokenIssuer(issuer).closePrivatization(oldToken);
        vm.stopBroadcast();
        console.log("Closed privatization for:", oldToken);
    }
}
