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
 *         Role model (admin = grant-only, operational work delegated):
 *           - admin signs grantRole / revokeRole and one-off config (--private-key)
 *           - a deterministic in-script "ops" wallet (vm.createWallet) holds the
 *             operational roles needed for the flows. The first time the script runs,
 *             admin grants ISSUER_ROLE + OPS_ROLE on the token, OPS_ROLE on Compliance,
 *             and OPS_ROLE on PauseManager to this ops wallet (idempotent — subsequent
 *             runs detect existing roles and skip).
 *           - a separate deterministic "user" wallet plays the role of a customer
 *             (receives transfers, gets blocklisted, etc).
 *
 *         Both ops and user are funded with a small amount of native gas from admin
 *         the first time they run a signed tx.
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
 *         Override deterministic labels to get fresh addresses (useful when prior runs
 *         left state behind):
 *           SMOKE_OPS_LABEL="run-$(date +%s)" forge script ...
 *           SMOKE_USER_LABEL="run-$(date +%s)" forge script ...
 */
contract Smoke is Script {
    // Amount used for mint / transfer flows (18 decimals raw).
    uint256 internal constant TEST_AMOUNT = 1_000 ether;
    // Below this balance, admin tops up the recipient.
    uint256 internal constant DEFAULT_GAS_THRESHOLD = 0.01 ether;
    // Top-up size when funding ops / user. Each user-signed tx on L2s with L1 data fee
    // (Mantle, Optimism, Base, Arbitrum) can cost up to ~0.02 native — 0.05 covers ~2 txs.
    uint256 internal constant DEFAULT_GAS_TARGET = 0.05 ether;

    // ═══════════════════════════════════════════════
    //                Public entry points
    // ═══════════════════════════════════════════════

    /// Read-only dump of the token's state. No broadcast required.
    function testInfo(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Compliance c = Compliance(address(token.compliance()));
        PauseManager p = PauseManager(address(token.pauseManager()));
        Vm.Wallet memory ops = _ops();

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
        console.log("Admin:           ", _admin());
        console.log("Ops:             ", ops.addr);
        console.log("Ops token bal:   ", token.balanceOf(ops.addr));
        console.log("Ops native gas:  ", ops.addr.balance);
        console.log("Ops has ISSUER:  ", token.hasRole(token.ISSUER_ROLE(), ops.addr));
        console.log("Ops has OPS:     ", token.hasRole(token.OPS_ROLE(), ops.addr));
    }

    /// Ops mints TEST_AMOUNT to itself, asserts balance + totalSupply increased.
    function testMint(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Vm.Wallet memory ops = _setupOps(token);
        console.log("--- testMint ---");

        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(ops.addr);

        vm.broadcast(ops.privateKey);
        require(token.mint(TEST_AMOUNT), "mint returned false");

        require(token.totalSupply() == supplyBefore + TEST_AMOUNT, "totalSupply not bumped");
        require(token.balanceOf(ops.addr) == balanceBefore + TEST_AMOUNT, "balance not bumped");
        console.log("  minted          ", TEST_AMOUNT);
        console.log("  ops balance     ", token.balanceOf(ops.addr));
        console.log("  [PASS] testMint");
    }

    /// Ops burns TEST_AMOUNT from itself, asserts balance + totalSupply decreased.
    /// Mints first if ops lacks balance.
    function testBurn(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Vm.Wallet memory ops = _setupOps(token);
        console.log("--- testBurn ---");

        if (token.balanceOf(ops.addr) < TEST_AMOUNT) {
            vm.broadcast(ops.privateKey);
            require(token.mint(TEST_AMOUNT), "pre-burn mint failed");
        }
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(ops.addr);

        vm.broadcast(ops.privateKey);
        require(token.burn(TEST_AMOUNT), "burn returned false");

        require(token.totalSupply() == supplyBefore - TEST_AMOUNT, "totalSupply not reduced");
        require(token.balanceOf(ops.addr) == balanceBefore - TEST_AMOUNT, "balance not reduced");
        console.log("  burned          ", TEST_AMOUNT);
        console.log("  [PASS] testBurn");
    }

    /// Full transfer flow: ops -> user -> ops (forces user-side signing),
    /// plus approve / transferFrom round trip.
    function testTransferFlow(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Vm.Wallet memory ops = _setupOps(token);
        Vm.Wallet memory user = _user();
        console.log("--- testTransferFlow ---");
        console.log("  ops:            ", ops.addr);
        console.log("  user:           ", user.addr);

        // Phase 1: ops mints (if needed), funds user with gas, transfers half to user
        uint256 half = TEST_AMOUNT / 2;
        if (token.balanceOf(ops.addr) < TEST_AMOUNT) {
            vm.broadcast(ops.privateKey);
            require(token.mint(TEST_AMOUNT), "pre-transfer mint failed");
        }
        _adminFundIfNeeded(user.addr);
        vm.broadcast(ops.privateKey);
        require(token.transfer(user.addr, half), "ops -> user transfer failed");
        require(token.balanceOf(user.addr) >= half, "user did not receive tokens");

        // Phase 2: user transfers a quarter back (user signs)
        uint256 quarter = TEST_AMOUNT / 4;
        uint256 userBefore = token.balanceOf(user.addr);
        uint256 opsBefore = token.balanceOf(ops.addr);
        vm.broadcast(user.privateKey);
        require(token.transfer(ops.addr, quarter), "user -> ops transfer failed");
        require(token.balanceOf(user.addr) == userBefore - quarter, "user balance mismatch");
        require(token.balanceOf(ops.addr) == opsBefore + quarter, "ops balance mismatch");

        // Phase 3: approve / transferFrom — user approves ops, ops pulls remaining quarter
        vm.broadcast(user.privateKey);
        require(token.approve(ops.addr, quarter), "approve failed");
        require(token.allowance(user.addr, ops.addr) == quarter, "allowance not set");

        opsBefore = token.balanceOf(ops.addr);
        userBefore = token.balanceOf(user.addr);
        vm.broadcast(ops.privateKey);
        require(token.transferFrom(user.addr, ops.addr, quarter), "transferFrom failed");
        require(token.balanceOf(user.addr) == userBefore - quarter, "user post-pull mismatch");
        require(token.balanceOf(ops.addr) == opsBefore + quarter, "ops post-pull mismatch");
        require(token.allowance(user.addr, ops.addr) == 0, "allowance not consumed");

        console.log("  ops balance     ", token.balanceOf(ops.addr));
        console.log("  user balance    ", token.balanceOf(user.addr));
        console.log("  [PASS] testTransferFlow");
    }

    /// Pause individual + global, verify transfers revert, then unpause.
    function testPause(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Vm.Wallet memory ops = _setupOps(token);
        Vm.Wallet memory user = _user();
        PauseManager pm = PauseManager(address(token.pauseManager()));
        console.log("--- testPause ---");

        // Ensure ops has something to attempt transferring
        if (token.balanceOf(ops.addr) < 1 ether) {
            vm.broadcast(ops.privateKey);
            require(token.mint(TEST_AMOUNT), "pre-pause mint failed");
        }

        // Individual pause
        vm.broadcast(ops.privateKey);
        pm.pauseToken(tokenAddr);
        require(pm.isTokenPaused(tokenAddr), "token not flagged paused");
        _expectTransferReverts(token, ops.addr, user.addr, 1 ether, "expected pause revert");

        vm.broadcast(ops.privateKey);
        pm.unpauseToken(tokenAddr);
        require(!pm.isTokenPaused(tokenAddr), "token still flagged paused");

        // Global pause
        vm.broadcast(ops.privateKey);
        pm.pauseAllTokens();
        require(pm.isTokenPaused(tokenAddr), "global pause not in effect");
        _expectTransferReverts(token, ops.addr, user.addr, 1 ether, "expected global-pause revert");

        vm.broadcast(ops.privateKey);
        pm.unpauseAllTokens();
        require(!pm.isTokenPaused(tokenAddr), "global unpause failed");

        // Sanity: post-unpause transfer succeeds (and cleans up by sending back)
        vm.broadcast(ops.privateKey);
        require(token.transfer(user.addr, 1 ether), "post-unpause transfer failed");
        console.log("  [PASS] testPause");
    }

    /// Blocklist (token-scoped) + sanctions (global) flow.
    function testCompliance(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Vm.Wallet memory ops = _setupOps(token);
        Vm.Wallet memory user = _user();
        Compliance c = Compliance(address(token.compliance()));
        console.log("--- testCompliance ---");

        if (token.balanceOf(ops.addr) < 1 ether) {
            vm.broadcast(ops.privateKey);
            require(token.mint(TEST_AMOUNT), "pre-compliance mint failed");
        }

        // --- Blocklist ---
        address[] memory list = new address[](1);
        list[0] = user.addr;

        vm.broadcast(ops.privateKey);
        c.addToBlocklist(tokenAddr, list);
        require(c.blockedAddresses(tokenAddr, user.addr), "user not on blocklist");
        _expectTransferReverts(token, ops.addr, user.addr, 1 ether, "expected blocklist revert");

        vm.broadcast(ops.privateKey);
        c.removeFromBlocklist(tokenAddr, list);
        require(!c.blockedAddresses(tokenAddr, user.addr), "user still on blocklist");

        // --- Sanctions (global) ---
        vm.broadcast(ops.privateKey);
        c.addToSanctionsList(list);
        require(c.sanctionedAddresses(user.addr), "user not on sanctions list");
        _expectTransferReverts(token, ops.addr, user.addr, 1 ether, "expected sanctions revert");

        vm.broadcast(ops.privateKey);
        c.removeFromSanctionsList(list);
        require(!c.sanctionedAddresses(user.addr), "user still on sanctions list");

        // --- Sanctions O(1) reset ---
        vm.broadcast(ops.privateKey);
        c.addToSanctionsList(list);
        require(c.sanctionedAddresses(user.addr), "pre-reset sanction missing");
        vm.broadcast(ops.privateKey);
        c.resetSanctionedAddresses();
        require(!c.sanctionedAddresses(user.addr), "epoch reset did not clear sanction");

        // Post-cleanup sanity
        vm.broadcast(ops.privateKey);
        require(token.transfer(user.addr, 1 ether), "post-compliance transfer failed");
        console.log("  [PASS] testCompliance");
    }

    /// Schedule a multiplier change and verify it is pending on-chain.
    function testMultiplier(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Vm.Wallet memory ops = _setupOps(token);
        console.log("--- testMultiplier ---");

        uint256 current = token.uiMultiplier();
        uint256 next = current == 1 ether ? 2 ether : 1 ether;
        // Generous 1-hour offset so the require still passes even under heavy bundle delay
        // on slow L2s. Override via env for chains with different block times.
        uint256 offset = vm.envOr("SMOKE_MULTIPLIER_OFFSET", uint256(3600));
        uint256 effective = block.timestamp + offset;

        vm.broadcast(ops.privateKey);
        token.setUIMultiplier(next, effective);

        require(token.newUIMultiplier() == next, "pending multiplier not set");
        require(token.effectiveAt() == effective, "pending effectiveAt not set");

        console.log("  current:        ", current);
        console.log("  scheduled:      ", next);
        console.log("  effectiveAt:    ", effective);
        console.log("  [PASS] testMultiplier (scheduling verified)");
    }

    /// Admin grants ISSUER_ROLE to a fresh user, that user mints, admin revokes.
    /// Demonstrates the role-delegation flow (admin's only operational power).
    function testIssuerRole(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Vm.Wallet memory user = _user();
        bytes32 issuerRole = token.ISSUER_ROLE();
        console.log("--- testIssuerRole ---");

        // Grant + fund (admin signs)
        vm.startBroadcast();
        if (!token.hasRole(issuerRole, user.addr)) {
            token.grantRole(issuerRole, user.addr);
        }
        _topUpAddr(user.addr);
        vm.stopBroadcast();
        require(token.hasRole(issuerRole, user.addr), "ISSUER_ROLE not granted");

        // User mints to themself
        uint256 supplyBefore = token.totalSupply();
        uint256 userBefore = token.balanceOf(user.addr);
        vm.broadcast(user.privateKey);
        require(token.mint(TEST_AMOUNT), "issuer mint failed");
        require(token.totalSupply() == supplyBefore + TEST_AMOUNT, "totalSupply mismatch");
        require(token.balanceOf(user.addr) == userBefore + TEST_AMOUNT, "user balance mismatch");

        // Revoke (admin signs)
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

    /// Deterministic ops wallet (same address across runs unless SMOKE_OPS_LABEL overridden).
    function _ops() internal returns (Vm.Wallet memory) {
        string memory label = vm.envOr("SMOKE_OPS_LABEL", string("mstocks-smoke-ops"));
        return vm.createWallet(label);
    }

    /// Deterministic test user (same address across runs unless SMOKE_USER_LABEL overridden).
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

    /// Idempotently grants ops the four operational roles it needs to run flows:
    ///   - ISSUER_ROLE on the token (mint / burn)
    ///   - OPS_ROLE on the token (setUIMultiplier)
    ///   - OPS_ROLE on Compliance (blocklist + sanctions)
    ///   - OPS_ROLE on PauseManager (pause/unpause)
    /// Also tops up ops's native balance to cover gas. All grant calls are batched into
    /// a single admin broadcast bundle; missing roles are detected via hasRole, so reruns
    /// don't re-grant.
    function _setupOps(SecuritiesToken token) internal returns (Vm.Wallet memory ops) {
        ops = _ops();
        Compliance c = Compliance(address(token.compliance()));
        PauseManager p = PauseManager(address(token.pauseManager()));

        bytes32 tIssuer = token.ISSUER_ROLE();
        bytes32 tOps = token.OPS_ROLE();
        bytes32 cOps = c.OPS_ROLE();
        bytes32 pOps = p.OPS_ROLE();

        bool needTIssuer = !token.hasRole(tIssuer, ops.addr);
        bool needTOps = !token.hasRole(tOps, ops.addr);
        bool needCOps = !c.hasRole(cOps, ops.addr);
        bool needPOps = !p.hasRole(pOps, ops.addr);
        bool needGas = ops.addr.balance
            < vm.envOr("SMOKE_USER_GAS_THRESHOLD", DEFAULT_GAS_THRESHOLD);

        if (!needTIssuer && !needTOps && !needCOps && !needPOps && !needGas) {
            return ops;
        }

        console.log("    setup ops:        ", ops.addr);
        vm.startBroadcast();
        if (needGas) _topUpAddr(ops.addr);
        if (needTIssuer) {
            token.grantRole(tIssuer, ops.addr);
            console.log("      granted token.ISSUER_ROLE");
        }
        if (needTOps) {
            token.grantRole(tOps, ops.addr);
            console.log("      granted token.OPS_ROLE");
        }
        if (needCOps) {
            c.grantRole(cOps, ops.addr);
            console.log("      granted compliance.OPS_ROLE");
        }
        if (needPOps) {
            p.grantRole(pOps, ops.addr);
            console.log("      granted pauseManager.OPS_ROLE");
        }
        vm.stopBroadcast();
    }

    /// Sends gas to `addr` if their native balance is below the threshold. Must be called
    /// inside an active admin broadcast. Threshold/target overridable via env (wei):
    ///   SMOKE_USER_GAS_THRESHOLD, SMOKE_USER_GAS_TARGET
    function _topUpAddr(address addr) internal {
        uint256 threshold = vm.envOr("SMOKE_USER_GAS_THRESHOLD", DEFAULT_GAS_THRESHOLD);
        uint256 target = vm.envOr("SMOKE_USER_GAS_TARGET", DEFAULT_GAS_TARGET);
        if (addr.balance >= threshold) {
            console.log("      gas (skip top-up): ", addr.balance);
            return;
        }
        (bool ok,) = addr.call{value: target}("");
        require(ok, "Smoke: gas fund transfer failed");
        console.log("      gas (funded):      ", target);
    }

    /// Variant of _topUpAddr that wraps its own startBroadcast/stopBroadcast — used when
    /// the caller is NOT already inside an admin broadcast.
    function _adminFundIfNeeded(address addr) internal {
        uint256 threshold = vm.envOr("SMOKE_USER_GAS_THRESHOLD", DEFAULT_GAS_THRESHOLD);
        if (addr.balance >= threshold) return;
        vm.startBroadcast();
        _topUpAddr(addr);
        vm.stopBroadcast();
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
