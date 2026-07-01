// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";
import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../src/pauseRegistry/PauseRegistry.sol";
import {TokenIssuer} from "../src/tokenIssuer/TokenIssuer.sol";

/// @notice End-to-end smoke tests against a deployed ScaledToken on a real chain.
///
/// Role model (admin grant-only, operational work delegated):
///   - admin signs grantRole / revokeRole and one-off config (--private-key)
///   - a deterministic in-script "ops" wallet (vm.createWallet) holds OPS_ROLE on the
///     token / ComplianceRegistry / PauseRegistry AND OPS_ROLE on a TokenIssuer that
///     holds ISSUER_ROLE on the token
///   - a deterministic "user" wallet plays the customer role and is registered as an
///     approved recipient on the TokenIssuer so it can be a mint / transfer / burn target
///
/// Token ISSUER_ROLE cannot be granted to an EOA, so all mint / burn flows go through
/// the TokenIssuer. Reuse a pre-deployed issuer by setting `SMOKE_TOKEN_ISSUER`; otherwise
/// the script deploys a fresh one (admin pays for the deploy).
///
///   export RPC=https://...
///   export ADMIN_PK=0x...
///   export TOKEN=0xDeployedTokenProxy
///   # optional — reuse an existing issuer:
///   # export SMOKE_TOKEN_ISSUER=0xIssuerProxy
///
///   forge script script/Smoke.s.sol:Smoke --sig "testInfo(address)" $TOKEN --rpc-url $RPC
///   forge script script/Smoke.s.sol:Smoke --sig "runAll(address)" $TOKEN \
///     --rpc-url $RPC --private-key $ADMIN_PK --broadcast
contract Smoke is Script {
    uint256 internal constant TEST_AMOUNT = 1_000 ether;
    uint256 internal constant DEFAULT_GAS_THRESHOLD = 0.01 ether;
    uint256 internal constant DEFAULT_GAS_TARGET = 0.05 ether;

    /// @dev Cached TokenIssuer for the current forge script invocation. Within `runAll`,
    ///      resolved once on the first `_setupOps` call and reused.
    TokenIssuer internal _issuer;

    function testInfo(address tokenAddr) public {
        ScaledToken token = ScaledToken(tokenAddr);
        ComplianceRegistry c = ComplianceRegistry(address(token.compliance()));
        PauseRegistry p = PauseRegistry(address(token.pauseManager()));
        Vm.Wallet memory ops = _ops();
        Vm.Wallet memory user = _user();

        console.log("--- testInfo ---");
        console.log("Token:           ", tokenAddr);
        console.log("Name:            ", token.name());
        console.log("Symbol:          ", token.symbol());
        console.log("Asset code:      ", token.assetCode());
        console.log("Decimals:        ", token.decimals());
        console.log("Total supply:    ", token.totalSupply());
        console.log("Total supply UI: ", token.totalSupplyUI());
        console.log("UI multiplier:   ", token.uiMultiplier());
        console.log("Pending mult.:   ", token.newUIMultiplier());
        console.log("EffectiveAt:     ", token.effectiveAt());
        console.log("Mint allowed:    ", token.mintAllowed());
        console.log("Burn allowed:    ", token.burnAllowed());
        console.log("Compliance:      ", address(c));
        console.log("PauseRegistry:   ", address(p));
        console.log("Token paused:    ", p.isTokenPaused(tokenAddr));
        console.log("Global paused:   ", p.globalPaused());
        console.log("Admin:           ", _admin());
        console.log("Ops:             ", ops.addr);
        console.log("User:            ", user.addr);
        console.log("Ops native gas:  ", ops.addr.balance);
        address envIssuer = vm.envOr("SMOKE_TOKEN_ISSUER", address(0));
        if (envIssuer != address(0)) {
            console.log("TokenIssuer (env):", envIssuer);
        }
    }

    /// @notice Mints TEST_AMOUNT through the TokenIssuer to itself.
    function testMint(address tokenAddr) public {
        ScaledToken token = ScaledToken(tokenAddr);
        (Vm.Wallet memory ops, TokenIssuer issuer) = _setupOps(token);
        console.log("--- testMint ---");

        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(address(issuer));

        vm.broadcast(ops.privateKey);
        issuer.mint(address(token), address(issuer), TEST_AMOUNT);

        require(token.totalSupply() == supplyBefore + TEST_AMOUNT, "totalSupply not bumped");
        require(
            token.balanceOf(address(issuer)) == balanceBefore + TEST_AMOUNT,
            "issuer balance not bumped"
        );
        console.log("  minted             ", TEST_AMOUNT);
        console.log("  issuer balance     ", token.balanceOf(address(issuer)));
        console.log("  [PASS] testMint");
    }

    /// @notice Burns TEST_AMOUNT from the TokenIssuer's own balance.
    function testBurn(address tokenAddr) public {
        ScaledToken token = ScaledToken(tokenAddr);
        (Vm.Wallet memory ops, TokenIssuer issuer) = _setupOps(token);
        console.log("--- testBurn ---");

        if (token.balanceOf(address(issuer)) < TEST_AMOUNT) {
            vm.broadcast(ops.privateKey);
            issuer.mint(address(token), address(issuer), TEST_AMOUNT);
        }
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(address(issuer));

        vm.broadcast(ops.privateKey);
        issuer.burn(address(token), address(issuer), TEST_AMOUNT);

        require(token.totalSupply() == supplyBefore - TEST_AMOUNT, "totalSupply not reduced");
        require(
            token.balanceOf(address(issuer)) == balanceBefore - TEST_AMOUNT,
            "issuer balance not reduced"
        );
        console.log("  burned             ", TEST_AMOUNT);
        console.log("  [PASS] testBurn");
    }

    /// @notice issuer mints → transfers to user (approved recipient) → user transfers back →
    ///         user approves and ops calls issuer.burn.
    function testTransferFlow(address tokenAddr) public {
        ScaledToken token = ScaledToken(tokenAddr);
        (Vm.Wallet memory ops, TokenIssuer issuer) = _setupOps(token);
        Vm.Wallet memory user = _user();
        console.log("--- testTransferFlow ---");
        console.log("  ops:               ", ops.addr);
        console.log("  issuer:            ", address(issuer));
        console.log("  user:              ", user.addr);

        if (token.balanceOf(address(issuer)) < TEST_AMOUNT) {
            vm.broadcast(ops.privateKey);
            issuer.mint(address(token), address(issuer), TEST_AMOUNT);
        }
        _adminFundIfNeeded(user.addr);

        _transferFlowPhase1(token, issuer, ops, user, TEST_AMOUNT / 2);
        _transferFlowPhase2(token, issuer, user, TEST_AMOUNT / 4);
        _transferFlowPhase3(token, issuer, ops, user, TEST_AMOUNT / 4);

        console.log("  issuer balance     ", token.balanceOf(address(issuer)));
        console.log("  user balance       ", token.balanceOf(user.addr));
        console.log("  [PASS] testTransferFlow");
    }

    function _transferFlowPhase1(
        ScaledToken token,
        TokenIssuer issuer,
        Vm.Wallet memory ops,
        Vm.Wallet memory user,
        uint256 amount
    ) internal {
        uint256 userBefore = token.balanceOf(user.addr);
        vm.broadcast(ops.privateKey);
        issuer.transfer(address(token), user.addr, amount);
        require(
            token.balanceOf(user.addr) == userBefore + amount,
            "user did not receive expected tokens"
        );
    }

    function _transferFlowPhase2(
        ScaledToken token,
        TokenIssuer issuer,
        Vm.Wallet memory user,
        uint256 amount
    ) internal {
        uint256 userBefore = token.balanceOf(user.addr);
        uint256 issuerBefore = token.balanceOf(address(issuer));
        vm.broadcast(user.privateKey);
        require(token.transfer(address(issuer), amount), "user -> issuer transfer failed");
        require(token.balanceOf(user.addr) == userBefore - amount, "user balance mismatch");
        require(
            token.balanceOf(address(issuer)) == issuerBefore + amount,
            "issuer balance mismatch"
        );
    }

    /// @dev Phase 3: user approves issuer, ops calls issuer.burn(token, user, amount); issuer
    ///      transferFroms `amount` from user to itself then burns it. Exercises the
    ///      approve / burn path through the operational layer.
    function _transferFlowPhase3(
        ScaledToken token,
        TokenIssuer issuer,
        Vm.Wallet memory ops,
        Vm.Wallet memory user,
        uint256 amount
    ) internal {
        vm.broadcast(user.privateKey);
        require(token.approve(address(issuer), amount), "approve failed");
        require(
            token.allowance(user.addr, address(issuer)) == amount,
            "allowance not set"
        );

        uint256 supplyBefore = token.totalSupply();
        uint256 userBefore = token.balanceOf(user.addr);
        vm.broadcast(ops.privateKey);
        issuer.burn(address(token), user.addr, amount);
        require(token.balanceOf(user.addr) == userBefore - amount, "user post-burn mismatch");
        require(token.totalSupply() == supplyBefore - amount, "totalSupply not reduced by burn");
        require(token.allowance(user.addr, address(issuer)) == 0, "allowance not consumed");
    }

    /// @notice Pause individual + global, verify issuer.transfer reverts, then unpause.
    function testPause(address tokenAddr) public {
        ScaledToken token = ScaledToken(tokenAddr);
        (Vm.Wallet memory ops, TokenIssuer issuer) = _setupOps(token);
        Vm.Wallet memory user = _user();
        PauseRegistry pm = PauseRegistry(address(token.pauseManager()));
        console.log("--- testPause ---");

        if (token.balanceOf(address(issuer)) < 1 ether) {
            vm.broadcast(ops.privateKey);
            issuer.mint(address(token), address(issuer), TEST_AMOUNT);
        }

        vm.broadcast(ops.privateKey);
        pm.pauseToken(tokenAddr);
        require(pm.isTokenPaused(tokenAddr), "token not flagged paused");
        _expectIssuerTransferReverts(issuer, address(token), ops.addr, user.addr, 1 ether, "expected pause revert");

        vm.broadcast(ops.privateKey);
        pm.unpauseToken(tokenAddr);
        require(!pm.isTokenPaused(tokenAddr), "token still flagged paused");

        vm.broadcast(ops.privateKey);
        pm.pauseGlobally();
        require(pm.isTokenPaused(tokenAddr), "global pause not in effect");
        _expectIssuerTransferReverts(issuer, address(token), ops.addr, user.addr, 1 ether, "expected global-pause revert");

        vm.broadcast(ops.privateKey);
        pm.unpauseGlobally();
        require(!pm.isTokenPaused(tokenAddr), "global unpause failed");

        vm.broadcast(ops.privateKey);
        issuer.transfer(address(token), user.addr, 1 ether);
        console.log("  [PASS] testPause");
    }

    /// @notice Blocklist (token-scoped) + sanctions (global) flow.
    function testCompliance(address tokenAddr) public {
        ScaledToken token = ScaledToken(tokenAddr);
        (Vm.Wallet memory ops, TokenIssuer issuer) = _setupOps(token);
        Vm.Wallet memory user = _user();
        ComplianceRegistry c = ComplianceRegistry(address(token.compliance()));
        console.log("--- testCompliance ---");

        if (token.balanceOf(address(issuer)) < 1 ether) {
            vm.broadcast(ops.privateKey);
            issuer.mint(address(token), address(issuer), TEST_AMOUNT);
        }

        address[] memory list = new address[](1);
        list[0] = user.addr;

        vm.broadcast(ops.privateKey);
        c.blockUsers(tokenAddr, list);
        require(c.isBlocked(tokenAddr, user.addr), "user not on blocklist");
        _expectIssuerTransferReverts(issuer, address(token), ops.addr, user.addr, 1 ether, "expected blocklist revert");

        vm.broadcast(ops.privateKey);
        c.unblockUsers(tokenAddr, list);
        require(!c.isBlocked(tokenAddr, user.addr), "user still on blocklist");

        vm.broadcast(ops.privateKey);
        c.sanctionUsers(list);
        require(c.isSanctioned(user.addr), "user not on sanctions list");
        _expectIssuerTransferReverts(issuer, address(token), ops.addr, user.addr, 1 ether, "expected sanctions revert");

        vm.broadcast(ops.privateKey);
        c.unsanctionUsers(list);
        require(!c.isSanctioned(user.addr), "user still on sanctions list");

        vm.broadcast(ops.privateKey);
        c.sanctionUsers(list);
        require(c.isSanctioned(user.addr), "pre-reset sanction missing");
        vm.broadcast(ops.privateKey);
        c.clearSanctions();
        require(!c.isSanctioned(user.addr), "epoch reset did not clear sanction");

        vm.broadcast(ops.privateKey);
        issuer.transfer(address(token), user.addr, 1 ether);
        console.log("  [PASS] testCompliance");
    }

    /// @notice Schedules a multiplier change and verifies it is pending on-chain.
    function testMultiplier(address tokenAddr) public {
        ScaledToken token = ScaledToken(tokenAddr);
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

    /// @notice Regression check for the EOA-issuer guard: granting ISSUER_ROLE to an EOA
    ///         must revert. Stays in-simulator via vm.prank so it's not recorded as a
    ///         broadcast tx.
    function testIssuerRole(address tokenAddr) public {
        ScaledToken token = ScaledToken(tokenAddr);
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

    /// @dev Resolves the TokenIssuer to use for this run. Resolution order:
    ///      1. `_issuer` cached by a previous call in this script run
    ///      2. SMOKE_TOKEN_ISSUER env var (a pre-deployed issuer — must have the
    ///         broadcaster as DEFAULT_ADMIN_ROLE)
    ///      3. deploy a fresh issuer (broadcaster becomes admin)
    function _getOrDeployIssuer() internal returns (TokenIssuer v) {
        if (address(_issuer) != address(0)) return _issuer;

        address envAddr = vm.envOr("SMOKE_TOKEN_ISSUER", address(0));
        if (envAddr != address(0)) {
            _issuer = TokenIssuer(payable(envAddr));
            require(
                _issuer.hasRole(bytes32(0), _admin()),
                "Smoke: broadcaster lacks DEFAULT_ADMIN_ROLE on the configured TokenIssuer"
            );
            return _issuer;
        }

        console.log("    SMOKE_TOKEN_ISSUER not set - deploying a fresh issuer");
        vm.startBroadcast();
        TokenIssuer impl = new TokenIssuer();
        bytes memory initData = abi.encodeWithSelector(TokenIssuer.initialize.selector, _admin());
        _issuer = TokenIssuer(payable(address(new ERC1967Proxy(address(impl), initData))));
        vm.stopBroadcast();
        console.log("    deployed TokenIssuer at", address(_issuer));
        return _issuer;
    }

    /// @dev Idempotently provisions the operational setup:
    ///      1. resolves / deploys the TokenIssuer
    ///      2. grants the issuer ISSUER_ROLE on the token (so it can mint / burn)
    ///      3. grants ops the OPS_ROLE on the issuer (so ops can drive mint / burn / transfer)
    ///      4. adds user as an approved recipient on the issuer
    ///      5. grants ops the OPS_ROLE on token, ComplianceRegistry, and PauseRegistry
    ///      6. tops up ops's native gas
    function _setupOps(ScaledToken token) internal returns (Vm.Wallet memory ops, TokenIssuer issuer) {
        ops = _ops();
        Vm.Wallet memory user = _user();
        issuer = _getOrDeployIssuer();

        ComplianceRegistry c = ComplianceRegistry(address(token.compliance()));
        PauseRegistry p = PauseRegistry(address(token.pauseManager()));

        bytes32 tIssuer = token.ISSUER_ROLE();
        bytes32 tScheduler = token.MULTIPLIER_SCHEDULER_ROLE();
        bytes32 issuerOps = issuer.OPS_ROLE();
        bytes32 cOps = c.OPS_ROLE();
        bytes32 pOps = p.OPS_ROLE();

        bool needIssuerOnIssuer = !token.hasRole(tIssuer, address(issuer));
        bool needOpsOnIssuer = !issuer.hasRole(issuerOps, ops.addr);
        bool needApprovedRecipient = !issuer.isApprovedRecipient(user.addr);
        bool needScheduler = !token.hasRole(tScheduler, ops.addr);
        bool needCOps = !c.hasRole(cOps, ops.addr);
        bool needPOps = !p.hasRole(pOps, ops.addr);
        bool needGas = ops.addr.balance
            < vm.envOr("SMOKE_USER_GAS_THRESHOLD", DEFAULT_GAS_THRESHOLD);

        if (
            !needIssuerOnIssuer && !needOpsOnIssuer && !needApprovedRecipient && !needScheduler
                && !needCOps && !needPOps && !needGas
        ) {
            return (ops, issuer);
        }

        console.log("    setup ops:           ", ops.addr);
        vm.startBroadcast();
        if (needGas) _topUpAddr(ops.addr);
        if (needIssuerOnIssuer) {
            token.grantRole(tIssuer, address(issuer));
            console.log("      granted token.ISSUER_ROLE to TokenIssuer");
        }
        if (needOpsOnIssuer) {
            issuer.grantRole(issuerOps, ops.addr);
            console.log("      granted issuer.OPS_ROLE to ops");
        }
        if (needApprovedRecipient) {
            issuer.addApprovedRecipient(user.addr);
            console.log("      added user as approved recipient on the TokenIssuer");
        }
        if (needScheduler) {
            token.grantRole(tScheduler, ops.addr);
            console.log("      granted token.MULTIPLIER_SCHEDULER_ROLE to ops");
        }
        if (needCOps) {
            c.grantRole(cOps, ops.addr);
            console.log("      granted compliance.OPS_ROLE to ops");
        }
        if (needPOps) {
            p.grantRole(pOps, ops.addr);
            console.log("      granted pauseRegistry.OPS_ROLE to ops");
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

    /// @dev Asserts that `issuer.transfer(token, to, amount)` reverts when called by `caller`.
    ///      Uses vm.prank + low-level call so the check stays in-simulator (forge's broadcast
    ///      bundle would otherwise reject the expected revert as a failed transaction).
    function _expectIssuerTransferReverts(
        TokenIssuer issuer,
        address token,
        address caller,
        address to,
        uint256 amount,
        string memory reason
    ) internal {
        vm.prank(caller);
        (bool ok,) = address(issuer).call(
            abi.encodeWithSignature("transfer(address,address,uint256)", token, to, amount)
        );
        require(!ok, reason);
    }
}
