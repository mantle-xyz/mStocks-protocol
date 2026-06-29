// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";
import {Compliance} from "../src/compliance/Compliance.sol";
import {PauseManager} from "../src/pauseManager/PauseManager.sol";
import {CexTokenIssuer} from "../src/tokenIssuer/CexTokenIssuer.sol";

/**
 * @title  Smoke
 * @notice End-to-end smoke tests against a *deployed* SecuritiesToken on a real chain.
 *
 *         Role model (admin = grant-only, operational work delegated):
 *           - admin signs grantRole / revokeRole and one-off config (--private-key)
 *           - a deterministic in-script "ops" wallet (vm.createWallet) holds the
 *             OPS_ROLE on the token / Compliance / PauseManager AND OPS_ROLE on an
 *             CexTokenIssuer contract that holds ISSUER_ROLE on the token
 *           - a separate deterministic "user" wallet plays the role of a customer
 *             and is registered as a hot wallet on the CexTokenIssuer so it can be
 *             a mint / transfer / burn target
 *
 *         Token ISSUER_ROLE can no longer be granted to an EOA, so all mint / burn /
 *         transfer operations are routed through the CexTokenIssuer. Use a pre-deployed
 *         CexTokenIssuer by setting `SMOKE_CEX_TOKEN_ISSUER`; otherwise the script will
 *         deploy a fresh one (admin pays for the deploy).
 *
 *         Examples:
 *           export RPC=https://...
 *           export ADMIN_PK=0x...
 *           export TOKEN=0xDeployedTokenProxy
 *           # optional — reuse an existing wallet across runs:
 *           # export SMOKE_CEX_TOKEN_ISSUER=0xWalletProxy
 *
 *           forge script script/Smoke.s.sol:Smoke --sig "testInfo(address)" $TOKEN --rpc-url $RPC
 *           forge script script/Smoke.s.sol:Smoke --sig "runAll(address)" $TOKEN \
 *             --rpc-url $RPC --private-key $ADMIN_PK --broadcast
 */
contract Smoke is Script {
    uint256 internal constant TEST_AMOUNT = 1_000 ether;
    uint256 internal constant DEFAULT_GAS_THRESHOLD = 0.01 ether;
    uint256 internal constant DEFAULT_GAS_TARGET = 0.05 ether;

    /// Cached CexTokenIssuer for the current forge script invocation. Within `runAll`,
    /// this is resolved once on the first `_setupOps` call and reused.
    CexTokenIssuer internal _wallet;

    // ═══════════════════════════════════════════════
    //                Public entry points
    // ═══════════════════════════════════════════════

    function testInfo(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Compliance c = Compliance(address(token.compliance()));
        PauseManager p = PauseManager(address(token.pauseManager()));
        Vm.Wallet memory ops = _ops();
        Vm.Wallet memory user = _user();

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
        console.log("User:            ", user.addr);
        console.log("Ops native gas:  ", ops.addr.balance);
        address envWallet = vm.envOr("SMOKE_CEX_TOKEN_ISSUER", address(0));
        if (envWallet != address(0)) {
            console.log("CexTokenIssuer (env):", envWallet);
        }
    }

    /// Mint TEST_AMOUNT through CexTokenIssuer to itself.
    function testMint(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        (Vm.Wallet memory ops, CexTokenIssuer wallet) = _setupOps(token);
        console.log("--- testMint ---");

        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(address(wallet));

        vm.broadcast(ops.privateKey);
        wallet.mint(address(token), address(wallet), TEST_AMOUNT);

        require(token.totalSupply() == supplyBefore + TEST_AMOUNT, "totalSupply not bumped");
        require(
            token.balanceOf(address(wallet)) == balanceBefore + TEST_AMOUNT,
            "wallet balance not bumped"
        );
        console.log("  minted             ", TEST_AMOUNT);
        console.log("  wallet balance     ", token.balanceOf(address(wallet)));
        console.log("  [PASS] testMint");
    }

    /// Burn TEST_AMOUNT from the CexTokenIssuer's own balance.
    function testBurn(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        (Vm.Wallet memory ops, CexTokenIssuer wallet) = _setupOps(token);
        console.log("--- testBurn ---");

        if (token.balanceOf(address(wallet)) < TEST_AMOUNT) {
            vm.broadcast(ops.privateKey);
            wallet.mint(address(token), address(wallet), TEST_AMOUNT);
        }
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(address(wallet));

        vm.broadcast(ops.privateKey);
        wallet.burn(address(token), address(wallet), TEST_AMOUNT);

        require(token.totalSupply() == supplyBefore - TEST_AMOUNT, "totalSupply not reduced");
        require(
            token.balanceOf(address(wallet)) == balanceBefore - TEST_AMOUNT,
            "wallet balance not reduced"
        );
        console.log("  burned             ", TEST_AMOUNT);
        console.log("  [PASS] testBurn");
    }

    /// wallet mints -> transfers to user (hot wallet) -> user signs return -> approve + wallet.burn.
    function testTransferFlow(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        (Vm.Wallet memory ops, CexTokenIssuer wallet) = _setupOps(token);
        Vm.Wallet memory user = _user();
        console.log("--- testTransferFlow ---");
        console.log("  ops:               ", ops.addr);
        console.log("  wallet:            ", address(wallet));
        console.log("  user:              ", user.addr);

        if (token.balanceOf(address(wallet)) < TEST_AMOUNT) {
            vm.broadcast(ops.privateKey);
            wallet.mint(address(token), address(wallet), TEST_AMOUNT);
        }
        _adminFundIfNeeded(user.addr);

        _transferFlowPhase1(token, wallet, ops, user, TEST_AMOUNT / 2);
        _transferFlowPhase2(token, wallet, user, TEST_AMOUNT / 4);
        _transferFlowPhase3(token, wallet, ops, user, TEST_AMOUNT / 4);

        console.log("  wallet balance     ", token.balanceOf(address(wallet)));
        console.log("  user balance       ", token.balanceOf(user.addr));
        console.log("  [PASS] testTransferFlow");
    }

    /// Phase 1: ops calls wallet.transfer to send `amount` from wallet to user (hot wallet).
    function _transferFlowPhase1(
        SecuritiesToken token,
        CexTokenIssuer wallet,
        Vm.Wallet memory ops,
        Vm.Wallet memory user,
        uint256 amount
    ) internal {
        uint256 userBefore = token.balanceOf(user.addr);
        vm.broadcast(ops.privateKey);
        wallet.transfer(address(token), user.addr, amount);
        require(
            token.balanceOf(user.addr) == userBefore + amount,
            "user did not receive expected tokens"
        );
    }

    /// Phase 2: user signs a direct token.transfer back to the wallet.
    function _transferFlowPhase2(
        SecuritiesToken token,
        CexTokenIssuer wallet,
        Vm.Wallet memory user,
        uint256 amount
    ) internal {
        uint256 userBefore = token.balanceOf(user.addr);
        uint256 walletBefore = token.balanceOf(address(wallet));
        vm.broadcast(user.privateKey);
        require(token.transfer(address(wallet), amount), "user -> wallet transfer failed");
        require(token.balanceOf(user.addr) == userBefore - amount, "user balance mismatch");
        require(
            token.balanceOf(address(wallet)) == walletBefore + amount,
            "wallet balance mismatch"
        );
    }

    /// Phase 3: user approves wallet, ops calls wallet.burn(token, user, amount) -- wallet
    /// transferFroms `amount` from user to itself then burns it. Exercises approve / burn
    /// through the operational layer.
    function _transferFlowPhase3(
        SecuritiesToken token,
        CexTokenIssuer wallet,
        Vm.Wallet memory ops,
        Vm.Wallet memory user,
        uint256 amount
    ) internal {
        vm.broadcast(user.privateKey);
        require(token.approve(address(wallet), amount), "approve failed");
        require(
            token.allowance(user.addr, address(wallet)) == amount,
            "allowance not set"
        );

        uint256 supplyBefore = token.totalSupply();
        uint256 userBefore = token.balanceOf(user.addr);
        vm.broadcast(ops.privateKey);
        wallet.burn(address(token), user.addr, amount);
        require(token.balanceOf(user.addr) == userBefore - amount, "user post-burn mismatch");
        require(token.totalSupply() == supplyBefore - amount, "totalSupply not reduced by burn");
        require(token.allowance(user.addr, address(wallet)) == 0, "allowance not consumed");
    }

    /// Pause individual + global, verify wallet.transfer reverts, then unpause.
    function testPause(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        (Vm.Wallet memory ops, CexTokenIssuer wallet) = _setupOps(token);
        Vm.Wallet memory user = _user();
        PauseManager pm = PauseManager(address(token.pauseManager()));
        console.log("--- testPause ---");

        if (token.balanceOf(address(wallet)) < 1 ether) {
            vm.broadcast(ops.privateKey);
            wallet.mint(address(token), address(wallet), TEST_AMOUNT);
        }

        // Individual pause
        vm.broadcast(ops.privateKey);
        pm.pauseToken(tokenAddr);
        require(pm.isTokenPaused(tokenAddr), "token not flagged paused");
        _expectWalletTransferReverts(wallet, address(token), ops.addr, user.addr, 1 ether, "expected pause revert");

        vm.broadcast(ops.privateKey);
        pm.unpauseToken(tokenAddr);
        require(!pm.isTokenPaused(tokenAddr), "token still flagged paused");

        // Global pause
        vm.broadcast(ops.privateKey);
        pm.pauseAllTokens();
        require(pm.isTokenPaused(tokenAddr), "global pause not in effect");
        _expectWalletTransferReverts(wallet, address(token), ops.addr, user.addr, 1 ether, "expected global-pause revert");

        vm.broadcast(ops.privateKey);
        pm.unpauseAllTokens();
        require(!pm.isTokenPaused(tokenAddr), "global unpause failed");

        // Sanity: post-unpause transfer succeeds
        vm.broadcast(ops.privateKey);
        wallet.transfer(address(token), user.addr, 1 ether);
        console.log("  [PASS] testPause");
    }

    /// Blocklist (token-scoped) + sanctions (global) flow.
    function testCompliance(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        (Vm.Wallet memory ops, CexTokenIssuer wallet) = _setupOps(token);
        Vm.Wallet memory user = _user();
        Compliance c = Compliance(address(token.compliance()));
        console.log("--- testCompliance ---");

        if (token.balanceOf(address(wallet)) < 1 ether) {
            vm.broadcast(ops.privateKey);
            wallet.mint(address(token), address(wallet), TEST_AMOUNT);
        }

        address[] memory list = new address[](1);
        list[0] = user.addr;

        // --- Blocklist ---
        vm.broadcast(ops.privateKey);
        c.addToBlocklist(tokenAddr, list);
        require(c.blockedAddresses(tokenAddr, user.addr), "user not on blocklist");
        _expectWalletTransferReverts(wallet, address(token), ops.addr, user.addr, 1 ether, "expected blocklist revert");

        vm.broadcast(ops.privateKey);
        c.removeFromBlocklist(tokenAddr, list);
        require(!c.blockedAddresses(tokenAddr, user.addr), "user still on blocklist");

        // --- Sanctions (global) ---
        vm.broadcast(ops.privateKey);
        c.addToSanctionsList(list);
        require(c.sanctionedAddresses(user.addr), "user not on sanctions list");
        _expectWalletTransferReverts(wallet, address(token), ops.addr, user.addr, 1 ether, "expected sanctions revert");

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
        wallet.transfer(address(token), user.addr, 1 ether);
        console.log("  [PASS] testCompliance");
    }

    /// Schedule a multiplier change and verify it is pending on-chain.
    function testMultiplier(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        (Vm.Wallet memory ops,) = _setupOps(token);
        console.log("--- testMultiplier ---");

        uint256 current = token.uiMultiplier();
        uint256 next = current == 1 ether ? 2 ether : 1 ether;
        uint256 offset = vm.envOr("SMOKE_MULTIPLIER_OFFSET", uint256(3600));
        uint256 effective = block.timestamp + offset;

        vm.broadcast(ops.privateKey);
        token.setUIMultiplier(next, effective);

        require(token.newUIMultiplier() == next, "pending multiplier not set");
        require(token.effectiveAt() == effective, "pending effectiveAt not set");

        console.log("  current:           ", current);
        console.log("  scheduled:         ", next);
        console.log("  effectiveAt:       ", effective);
        console.log("  [PASS] testMultiplier (scheduling verified)");
    }

    /// Regression test for the EOA-issuer guard: admin's attempt to grant ISSUER_ROLE
    /// to an EOA must revert. Stays in-simulator via vm.prank so it's not recorded
    /// as a broadcast tx.
    function testIssuerRole(address tokenAddr) public {
        SecuritiesToken token = SecuritiesToken(tokenAddr);
        Vm.Wallet memory user = _user();
        bytes32 issuerRole = token.ISSUER_ROLE();
        console.log("--- testIssuerRole ---");

        vm.prank(_admin());
        (bool ok,) = address(token).call(
            abi.encodeWithSignature("grantRole(bytes32,address)", issuerRole, user.addr)
        );
        require(!ok, "expected grantRole(ISSUER, EOA) to revert");
        require(!token.hasRole(issuerRole, user.addr), "EOA somehow gained ISSUER_ROLE");
        console.log("  [PASS] EOA correctly rejected as ISSUER_ROLE holder");
    }

    /// Run every mutating test in sequence.
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

    function _ops() internal returns (Vm.Wallet memory) {
        string memory label = vm.envOr("SMOKE_OPS_LABEL", string("mstocks-smoke-ops"));
        return vm.createWallet(label);
    }

    function _user() internal returns (Vm.Wallet memory) {
        string memory label = vm.envOr("SMOKE_USER_LABEL", string("mstocks-smoke-user"));
        return vm.createWallet(label);
    }

    function _admin() internal view returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return vm.addr(pk);
        return msg.sender;
    }

    /**
     * @dev Resolves the CexTokenIssuer to use for this run. Resolution order:
     *      1. cached in `_wallet` (set by a previous call in this same script run)
     *      2. SMOKE_CEX_TOKEN_ISSUER env var (a pre-deployed wallet — must have
     *         broadcaster as DEFAULT_ADMIN_ROLE)
     *      3. deploy a fresh wallet (broadcaster becomes admin)
     */
    function _getOrDeployWallet() internal returns (CexTokenIssuer w) {
        if (address(_wallet) != address(0)) return _wallet;

        address envAddr = vm.envOr("SMOKE_CEX_TOKEN_ISSUER", address(0));
        if (envAddr != address(0)) {
            _wallet = CexTokenIssuer(payable(envAddr));
            require(
                _wallet.hasRole(bytes32(0), _admin()),
                "Smoke: broadcaster lacks DEFAULT_ADMIN_ROLE on the configured CexTokenIssuer"
            );
            return _wallet;
        }

        console.log("    SMOKE_CEX_TOKEN_ISSUER not set - deploying a fresh wallet");
        vm.startBroadcast();
        CexTokenIssuer impl = new CexTokenIssuer();
        bytes memory initData = abi.encodeWithSelector(CexTokenIssuer.initialize.selector, _admin());
        _wallet = CexTokenIssuer(payable(address(new ERC1967Proxy(address(impl), initData))));
        vm.stopBroadcast();
        console.log("    deployed CexTokenIssuer at", address(_wallet));
        return _wallet;
    }

    /**
     * @dev Idempotently provisions the operational setup:
     *      1. resolves / deploys the CexTokenIssuer
     *      2. grants the wallet ISSUER_ROLE on the token (so it can mint / burn)
     *      3. grants ops the OPS_ROLE on the wallet (so ops can drive mint / burn / transfer)
     *      4. adds user as a hot wallet on the wallet (so wallet.transfer / wallet.burn
     *         can use user.addr as recipient / from)
     *      5. grants ops the OPS_ROLE on token (multiplier), Compliance, and PauseManager
     *      6. tops up ops's native gas
     */
    function _setupOps(SecuritiesToken token) internal returns (Vm.Wallet memory ops, CexTokenIssuer wallet) {
        ops = _ops();
        Vm.Wallet memory user = _user();
        wallet = _getOrDeployWallet();

        Compliance c = Compliance(address(token.compliance()));
        PauseManager p = PauseManager(address(token.pauseManager()));

        bytes32 tIssuer = token.ISSUER_ROLE();
        bytes32 tOps = token.OPS_ROLE();
        bytes32 walletOps = wallet.OPS_ROLE();
        bytes32 cOps = c.OPS_ROLE();
        bytes32 pOps = p.OPS_ROLE();

        bool needIssuerOnWallet = !token.hasRole(tIssuer, address(wallet));
        bool needOpsOnWallet = !wallet.hasRole(walletOps, ops.addr);
        bool needHotWallet = !wallet.isHotWallet(user.addr);
        bool needTOps = !token.hasRole(tOps, ops.addr);
        bool needCOps = !c.hasRole(cOps, ops.addr);
        bool needPOps = !p.hasRole(pOps, ops.addr);
        bool needGas = ops.addr.balance
            < vm.envOr("SMOKE_USER_GAS_THRESHOLD", DEFAULT_GAS_THRESHOLD);

        if (
            !needIssuerOnWallet && !needOpsOnWallet && !needHotWallet && !needTOps
                && !needCOps && !needPOps && !needGas
        ) {
            return (ops, wallet);
        }

        console.log("    setup ops:           ", ops.addr);
        vm.startBroadcast();
        if (needGas) _topUpAddr(ops.addr);
        if (needIssuerOnWallet) {
            token.grantRole(tIssuer, address(wallet));
            console.log("      granted token.ISSUER_ROLE to CexTokenIssuer");
        }
        if (needOpsOnWallet) {
            wallet.grantRole(walletOps, ops.addr);
            console.log("      granted wallet.OPS_ROLE to ops");
        }
        if (needHotWallet) {
            wallet.addHotWallet(user.addr);
            console.log("      added user as a hot wallet on the CexTokenIssuer");
        }
        if (needTOps) {
            token.grantRole(tOps, ops.addr);
            console.log("      granted token.OPS_ROLE to ops");
        }
        if (needCOps) {
            c.grantRole(cOps, ops.addr);
            console.log("      granted compliance.OPS_ROLE to ops");
        }
        if (needPOps) {
            p.grantRole(pOps, ops.addr);
            console.log("      granted pauseManager.OPS_ROLE to ops");
        }
        vm.stopBroadcast();
    }

    function _topUpAddr(address addr) internal {
        uint256 threshold = vm.envOr("SMOKE_USER_GAS_THRESHOLD", DEFAULT_GAS_THRESHOLD);
        uint256 target = vm.envOr("SMOKE_USER_GAS_TARGET", DEFAULT_GAS_TARGET);
        if (addr.balance >= threshold) {
            console.log("      gas (skip top-up):   ", addr.balance);
            return;
        }
        (bool ok,) = addr.call{value: target}("");
        require(ok, "Smoke: gas fund transfer failed");
        console.log("      gas (funded):        ", target);
    }

    function _adminFundIfNeeded(address addr) internal {
        uint256 threshold = vm.envOr("SMOKE_USER_GAS_THRESHOLD", DEFAULT_GAS_THRESHOLD);
        if (addr.balance >= threshold) return;
        vm.startBroadcast();
        _topUpAddr(addr);
        vm.stopBroadcast();
    }

    /// Asserts that `wallet.transfer(token, to, amount)` reverts when called by `caller`.
    /// Uses vm.prank + low-level call so the check stays in-simulator (forge's broadcast
    /// bundle would otherwise reject the expected revert as a failed transaction).
    function _expectWalletTransferReverts(
        CexTokenIssuer wallet,
        address token,
        address caller,
        address to,
        uint256 amount,
        string memory reason
    ) internal {
        vm.prank(caller);
        (bool ok,) = address(wallet).call(
            abi.encodeWithSignature("transfer(address,address,uint256)", token, to, amount)
        );
        require(!ok, reason);
    }
}
