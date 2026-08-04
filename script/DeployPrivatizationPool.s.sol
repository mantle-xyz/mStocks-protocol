// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrivatizationPool} from "../src/privatization/PrivatizationPool.sol";
import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";

/// @notice Operational entrypoints for the 方案一 privatization / delisting flow (standalone
///         PrivatizationPool). See docs/privatization-runbook.md §2. Each entrypoint is
///         broadcast by the appropriate role — run them in order.
///
///         Rates are per RATE_SCALE (1e18) of OLD-token raw. With both tokens at multiplier
///         1.0: newRate = k*1e18 (k new per old), usdcRate = p (USDC raw per old share).
///
///         1) deploy      — anyone (records the pool address)
///         2) wire        — OLD token admin (grant ISSUER_ROLE + freeze supply)
///         3) fundUsdc    — financier; new stock funded via its TokenIssuer separately
///         4) sweep       — pool admin, after the deadline
contract DeployPrivatizationPool is Script {
    /// @notice Step 1 — deploy the pool. `newToken`/`usdc` may be zero for cash-only / stock-only
    ///         events (with a non-zero rate on the configured leg). `admin` may sweep after the
    ///         deadline.
    function deploy(
        address oldToken,
        address newToken,
        address usdc,
        uint256 newRate,
        uint256 usdcRate,
        uint256 deadline,
        address admin
    ) external returns (address pool) {
        require(oldToken != address(0), "oldToken zero");
        require(deadline > block.timestamp, "deadline in past");

        vm.startBroadcast();
        pool = address(
            new PrivatizationPool(oldToken, newToken, usdc, newRate, usdcRate, uint64(deadline), admin)
        );
        vm.stopBroadcast();

        console.log("=== PrivatizationPool deployed ===");
        console.log("pool:    ", pool);
        console.log("oldToken:", oldToken);
        console.log("newToken:", newToken);
        console.log("usdc:    ", usdc);
        console.log("newRate: ", newRate);
        console.log("usdcRate:", usdcRate);
        console.log("deadline:", deadline);
        console.log("Next: OLD admin runs wire(pool, oldToken); then fund the pool.");
    }

    /// @notice Step 2 — grant the pool ISSUER_ROLE on the old token (so it can burn surrendered
    ///         balances) and freeze the old token's supply. Broadcaster must be the OLD token admin.
    function wire(address pool, address oldToken) external {
        bytes32 issuerRole = ScaledToken(oldToken).ISSUER_ROLE();
        vm.startBroadcast();
        ScaledToken(oldToken).grantRole(issuerRole, pool);
        ScaledToken(oldToken).setMintAllowed(false);
        vm.stopBroadcast();
        console.log("Granted ISSUER_ROLE to pool + froze old supply:", pool);
    }

    /// @notice Step 3 — fund the pool's USDC leg (simple transfer; the pool holds its own
    ///         inventory). New stock is funded by minting into the pool via that token's
    ///         TokenIssuer, out of this script's scope. Broadcaster owns `amount` of USDC.
    function fundUsdc(address pool, address usdc, uint256 amount) external {
        vm.startBroadcast();
        IERC20(usdc).transfer(pool, amount);
        vm.stopBroadcast();
        console.log("Funded pool USDC:", amount);
        console.log("pool USDC balance:", IERC20(usdc).balanceOf(pool));
    }

    /// @notice Step 4 — after the deadline, sweep unclaimed consideration (new stock + USDC) to
    ///         custody. Broadcaster must be the pool `admin`.
    function sweep(address pool, address to) external {
        vm.startBroadcast();
        PrivatizationPool(pool).sweepUnclaimed(to);
        vm.stopBroadcast();
        console.log("Swept unclaimed consideration to:", to);
    }
}
