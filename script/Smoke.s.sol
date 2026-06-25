// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";
import {Compliance} from "../src/compliance/Compliance.sol";
import {PauseManager} from "../src/pauseManager/PauseManager.sol";

/**
 * @title  Smoke
 * @notice End-to-end smoke tests against a *deployed* SecuritiesToken on a real chain.
 *
 *         The signer (--private-key / --account) MUST be the token's DEFAULT_ADMIN_ROLE
 *         holder — every flow either signs as admin or as a freshly-derived test user
 *         (whose private key is generated inside the script via vm.createWallet).
 *
 *         Each test entry point is self-contained (does its own setup + cleanup) and can
 *         be invoked via --sig. Use `runAll(address)` to chain everything in one broadcast.
 *
 *         Examples:
 *           export RPC=https://...
 *           export ADMIN_PK=0x...
 *           export TOKEN=0xDeployedTokenProxy
 *
 *           forge script script/Smoke.s.sol:Smoke --sig "testInfo(address)" $TOKEN --rpc-url $RPC
 *           forge script script/Smoke.s.sol:Smoke --sig "testMint(address)" $TOKEN \
 *             --rpc-url $RPC --private-key $ADMIN_PK --broadcast
 *           forge script script/Smoke.s.sol:Smoke --sig "runAll(address)" $TOKEN \
 *             --rpc-url $RPC --private-key $ADMIN_PK --broadcast
 *
 *         Override the deterministic test-user label (defaults to "mstocks-smoke-user")
 *         to generate a fresh user — useful when prior runs left state behind:
 *           SMOKE_USER_LABEL="run-$(date +%s)" forge script ...
 */
contract Smoke is Script {
    // Amount used for mint / transfer flows (18 decimals raw).
    uint256 internal constant TEST_AMOUNT = 1_000 ether;
    // Below this balance, admin tops up the test user.
    // Default 0.01 native. L2s with L1 data fees (Mantle, Optimism, Base, Arbitrum)
    // can burn a lot per tx — bump via SMOKE_USER_GAS_THRESHOLD if needed.
    uint256 internal constant DEFAULT_GAS_THRESHOLD = 0.01 ether;
    // Top-up amount when funding the test user. Default 0.05 native. Each user-signed
    // tx on Mantle can cost up to ~0.02 native including L1 fee — 0.05 covers ~2 user
    // txs (transfer back + approve). Bump via SMOKE_USER_GAS_TARGET if needed.
    uint256 internal constant DEFAULT_GAS_TARGET = 0.05 ether;

    // ═══════════════════════════════════════════════
    //                Public entry points
    // ═══════════════════════════════════════════════

    /// Read-only dump of the token's state. No broadcast required.
    function testInfo(address tokenAddr) public view {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Compliance c = Compliance(address(token.compliance()));
        PauseManager p = PauseManager(address(token.pauseManager()));

        console.log("--- testInfo ---");
        console.log("Token:           ", tokenAddr);
        console.log("Name:            ", token.name());
        console.log("Symbol:          ", token.symbol());
        console.log("Identifier:      ", token.identifier());
        console.log("Decimals:        ", token.decimals());
        console.log("Total supply:    ", token.totalSupply());
        console.log("Total supply UI: ", token.totalSupplyUI());
        console.log("UI multiplier:   ", token.uiMultiplier());
        console.log("Pending mult.:   ", token.newUIMultiplier());
        console.log("EffectiveAt:     ", token.effectiveAt());
        console.log("Mint enabled:    ", token.mintEnabled());
        console.log("Burn enabled:    ", token.burnEnabled());
        console.log("Compliance:      ", address(c));
        console.log("PauseManager:    ", address(p));
        console.log("Token paused:    ", p.isTokenPaused(tokenAddr));
        console.log("All paused:      ", p.allTokensPaused());
        console.log("Admin balance:   ", token.balanceOf(_admin()));
    }

    /// Admin mints TEST_AMOUNT to itself, asserts balance + totalSupply increased.
    function testMint(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        address admin = _admin();
        console.log("--- testMint ---");

        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(admin);

        vm.startBroadcast();
        require(token.mint(TEST_AMOUNT), "mint returned false");
        vm.stopBroadcast();

        require(token.totalSupply() == supplyBefore + TEST_AMOUNT, "totalSupply not bumped");
        require(token.balanceOf(admin) == balanceBefore + TEST_AMOUNT, "balance not bumped");
        console.log("  minted          ", TEST_AMOUNT);
        console.log("  admin balance   ", token.balanceOf(admin));
        console.log("  [PASS] testMint");
    }

    /// Admin burns TEST_AMOUNT from itself, asserts balance + totalSupply decreased.
    /// Mints first if admin lacks balance.
    function testBurn(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        address admin = _admin();
        console.log("--- testBurn ---");

        vm.startBroadcast();
        if (token.balanceOf(admin) < TEST_AMOUNT) {
            require(token.mint(TEST_AMOUNT), "pre-burn mint failed");
        }
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(admin);
        require(token.burn(TEST_AMOUNT), "burn returned false");
        vm.stopBroadcast();

        require(token.totalSupply() == supplyBefore - TEST_AMOUNT, "totalSupply not reduced");
        require(token.balanceOf(admin) == balanceBefore - TEST_AMOUNT, "balance not reduced");
        console.log("  burned          ", TEST_AMOUNT);
        console.log("  [PASS] testBurn");
    }

    /// Full transfer flow: admin -> user -> admin (forces user-side signing),
    /// plus approve / transferFrom round trip.
    function testTransferFlow(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        address admin = _admin();
        Vm.Wallet memory user = _user();
        console.log("--- testTransferFlow ---");
        console.log("  test user:      ", user.addr);

        // Phase 1: admin mints (if needed) + funds user with gas + transfers half to user
        uint256 half = TEST_AMOUNT / 2;
        vm.startBroadcast();
        if (token.balanceOf(admin) < TEST_AMOUNT) {
            require(token.mint(TEST_AMOUNT), "pre-transfer mint failed");
        }
        _topUpUser(user.addr);
        require(token.transfer(user.addr, half), "admin -> user transfer failed");
        vm.stopBroadcast();
        require(token.balanceOf(user.addr) >= half, "user did not receive tokens");

        // Phase 2: user transfers a quarter back (user signs)
        uint256 quarter = TEST_AMOUNT / 4;
        uint256 userBefore = token.balanceOf(user.addr);
        uint256 adminBefore = token.balanceOf(admin);
        vm.broadcast(user.privateKey);
        require(token.transfer(admin, quarter), "user -> admin transfer failed");
        require(token.balanceOf(user.addr) == userBefore - quarter, "user balance mismatch");
        require(token.balanceOf(admin) == adminBefore + quarter, "admin balance mismatch");

        // Phase 3: approve / transferFrom — user approves admin, admin pulls remaining quarter
        vm.broadcast(user.privateKey);
        require(token.approve(admin, quarter), "approve failed");
        require(token.allowance(user.addr, admin) == quarter, "allowance not set");

        adminBefore = token.balanceOf(admin);
        userBefore = token.balanceOf(user.addr);
        vm.broadcast();
        require(token.transferFrom(user.addr, admin, quarter), "transferFrom failed");
        require(token.balanceOf(user.addr) == userBefore - quarter, "user post-pull mismatch");
        require(token.balanceOf(admin) == adminBefore + quarter, "admin post-pull mismatch");
        require(token.allowance(user.addr, admin) == 0, "allowance not consumed");

        console.log("  admin balance   ", token.balanceOf(admin));
        console.log("  user balance    ", token.balanceOf(user.addr));
        console.log("  [PASS] testTransferFlow");
    }

    /// Pause individual + global, verify transfers revert, then unpause.
    function testPause(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        address admin = _admin();
        Vm.Wallet memory user = _user();
        PauseManager pm = PauseManager(address(token.pauseManager()));
        console.log("--- testPause ---");

        // Ensure admin has something to attempt transferring
        vm.startBroadcast();
        if (token.balanceOf(admin) < 1 ether) {
            require(token.mint(TEST_AMOUNT), "pre-pause mint failed");
        }
        vm.stopBroadcast();

        // Individual pause
        vm.broadcast();
        pm.pauseToken(tokenAddr);
        require(pm.isTokenPaused(tokenAddr), "token not flagged paused");
        _expectTransferReverts(token, admin, user.addr, 1 ether, "expected pause revert");

        vm.broadcast();
        pm.unpauseToken(tokenAddr);
        require(!pm.isTokenPaused(tokenAddr), "token still flagged paused");

        // Global pause
        vm.broadcast();
        pm.pauseAllTokens();
        require(pm.isTokenPaused(tokenAddr), "global pause not in effect");
        _expectTransferReverts(token, admin, user.addr, 1 ether, "expected global-pause revert");

        vm.broadcast();
        pm.unpauseAllTokens();
        require(!pm.isTokenPaused(tokenAddr), "global unpause failed");

        // Sanity: post-unpause transfer succeeds (and cleans up by sending back)
        vm.startBroadcast();
        require(token.transfer(user.addr, 1 ether), "post-unpause transfer failed");
        vm.stopBroadcast();
        console.log("  [PASS] testPause");
    }

    /// Blocklist (token-scoped) + sanctions (global) flow.
    function testCompliance(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        address admin = _admin();
        Vm.Wallet memory user = _user();
        Compliance c = Compliance(address(token.compliance()));
        console.log("--- testCompliance ---");

        vm.startBroadcast();
        if (token.balanceOf(admin) < 1 ether) {
            require(token.mint(TEST_AMOUNT), "pre-compliance mint failed");
        }
        vm.stopBroadcast();

        // --- Blocklist ---
        address[] memory list = new address[](1);
        list[0] = user.addr;

        vm.broadcast();
        c.addToBlocklist(tokenAddr, list);
        require(c.blockedAddresses(tokenAddr, user.addr), "user not on blocklist");
        _expectTransferReverts(token, admin, user.addr, 1 ether, "expected blocklist revert");

        vm.broadcast();
        c.removeFromBlocklist(tokenAddr, list);
        require(!c.blockedAddresses(tokenAddr, user.addr), "user still on blocklist");

        // --- Sanctions (global) ---
        vm.broadcast();
        c.addToSanctionsList(list);
        require(c.sanctionedAddresses(user.addr), "user not on sanctions list");
        _expectTransferReverts(token, admin, user.addr, 1 ether, "expected sanctions revert");

        vm.broadcast();
        c.removeFromSanctionsList(list);
        require(!c.sanctionedAddresses(user.addr), "user still on sanctions list");

        // --- Sanctions O(1) reset ---
        vm.broadcast();
        c.addToSanctionsList(list);
        require(c.sanctionedAddresses(user.addr), "pre-reset sanction missing");
        vm.broadcast();
        c.resetSanctionedAddresses();
        require(!c.sanctionedAddresses(user.addr), "epoch reset did not clear sanction");

        // Post-cleanup sanity
        vm.startBroadcast();
        require(token.transfer(user.addr, 1 ether), "post-compliance transfer failed");
        vm.stopBroadcast();
        console.log("  [PASS] testCompliance");
    }

    /// Schedule a multiplier change and verify it is pending on-chain.
    /// (Does not wait for activation — the script can't sleep across blocks.)
    function testMultiplier(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        console.log("--- testMultiplier ---");

        uint256 current = token.uiMultiplier();
        // Toggle: if current is 1e18 use 2e18; otherwise restore to 1e18
        uint256 next = current == 1 ether ? 2 ether : 1 ether;
        // The contract requires effective > block.timestamp AT EXECUTION TIME (not
        // simulation time). When this runs inside runAll on a slow L2, dozens of txs
        // may land between simulation and the actual setUIMultiplier broadcast — the
        // chain's timestamp can advance several minutes. Use a generous 1-hour offset
        // so the require still passes even under heavy bundle delay. Override via env
        // for chains with different block times.
        uint256 offset = vm.envOr("SMOKE_MULTIPLIER_OFFSET", uint256(3600));
        uint256 effective = block.timestamp + offset;

        vm.broadcast();
        token.setUIMultiplier(next, effective);

        require(token.newUIMultiplier() == next, "pending multiplier not set");
        require(token.effectiveAt() == effective, "pending effectiveAt not set");

        console.log("  current:        ", current);
        console.log("  scheduled:      ", next);
        console.log("  effectiveAt:    ", effective);
        console.log("  [PASS] testMultiplier (scheduling verified)");
    }

    /// Grant ISSUER_ROLE to the test user, have them mint, then revoke.
    function testIssuerRole(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Vm.Wallet memory user = _user();
        bytes32 issuerRole = token.ISSUER_ROLE();
        console.log("--- testIssuerRole ---");

        // Grant + fund (admin)
        vm.startBroadcast();
        token.grantRole(issuerRole, user.addr);
        _topUpUser(user.addr);
        vm.stopBroadcast();
        require(token.hasRole(issuerRole, user.addr), "ISSUER_ROLE not granted");

        // User mints to themself
        uint256 supplyBefore = token.totalSupply();
        uint256 userBefore = token.balanceOf(user.addr);
        vm.broadcast(user.privateKey);
        require(token.mint(TEST_AMOUNT), "issuer mint failed");
        require(token.totalSupply() == supplyBefore + TEST_AMOUNT, "totalSupply mismatch");
        require(token.balanceOf(user.addr) == userBefore + TEST_AMOUNT, "user balance mismatch");

        // Revoke (admin)
        vm.broadcast();
        token.revokeRole(issuerRole, user.addr);
        require(!token.hasRole(issuerRole, user.addr), "ISSUER_ROLE not revoked");
        console.log("  [PASS] testIssuerRole");
    }

    /// Run every mutating test in sequence — one broadcast bundle, one report.
    function runAll(address tokenAddr) external {
        testInfo(tokenAddr);
        testMint(tokenAddr);
        testTransferFlow(tokenAddr);
        testBurn(tokenAddr);
        testPause(tokenAddr);
        testCompliance(tokenAddr);
        testMultiplier(tokenAddr);
        testIssuerRole(tokenAddr);
        console.log("=== ALL SMOKE TESTS PASSED ===");
    }

    // ═══════════════════════════════════════════════
    //                Internal helpers
    // ═══════════════════════════════════════════════

    /// Deterministic test user (same address across runs unless SMOKE_USER_LABEL is overridden).
    function _user() internal returns (Vm.Wallet memory) {
        string memory label = vm.envOr("SMOKE_USER_LABEL", string("mstocks-smoke-user"));
        return vm.createWallet(label);
    }

    /// Address derived from --private-key (or vm default).
    function _admin() internal view returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return vm.addr(pk);
        return msg.sender;
    }

    /// Sends gas to `user` if their native balance is below the threshold.
    /// Both threshold and target are overridable via env (in wei):
    ///   SMOKE_USER_GAS_THRESHOLD, SMOKE_USER_GAS_TARGET
    /// Must be called inside an active admin broadcast.
    function _topUpUser(address user) internal {
        uint256 threshold = vm.envOr("SMOKE_USER_GAS_THRESHOLD", DEFAULT_GAS_THRESHOLD);
        uint256 target = vm.envOr("SMOKE_USER_GAS_TARGET", DEFAULT_GAS_TARGET);
        if (user.balance >= threshold) {
            console.log("    user gas (skip top-up):", user.balance);
            return;
        }
        (bool ok,) = user.call{value: target}("");
        require(ok, "Smoke: gas fund transfer failed");
        console.log("    user gas (funded):     ", target);
    }

    /// Asserts that `from -> to` transfer reverts. Uses vm.prank + low-level call so the
    /// check stays in the simulator and is NOT recorded as a broadcast tx (forge's bundle
    /// re-simulation would otherwise reject the expected revert as a failed transaction).
    function _expectTransferReverts(
        SecuritiesToken token,
        address from,
        address to,
        uint256 amount,
        string memory reason
    ) internal {
        vm.prank(from);
        (bool ok,) =
            address(token).call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(!ok, reason);
    }
}
