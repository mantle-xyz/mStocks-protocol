// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {PauseGuardUpgradeable} from "../../src/pauseRegistry/PauseGuardUpgradeable.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract QAPause is BaseQAScript {
    function run() external {
        _loadEnv();

        test_PSE01();
        test_PSE02();
        test_PSE03();
        test_PSE04();
        test_PSE05();
        test_PSE06();
        test_PSE07();
        test_PSE08();
        test_PSE09();
        test_PSE10();
        test_PSE11();
        test_PSE12();
    }

    // ── QA-PSE-01: 单 token 暂停阻止转账 ──
    function test_PSE01() public {
        _logCase("QA-PSE-01", unicode"单 token 暂停阻止转账");

        _step("[Step 1] preconditions + mint before pause");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        _requireBalance(hotWallet, 100e18, "hotWallet");

        _step("[Step 2] pauseOps pauses token");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        _requirePaused();
        _step("  token is paused");

        _step("[Step 3] hotWallet tries transfer");
        _expectRevertFrom(
            hotWallet,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            PauseGuardUpgradeable.TokenPaused.selector
        );
        _step("  PASS: reverted TokenPaused()");

        _step("[Step 4] cleanup: unpause");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();
        _step("  PASS: unpauseToken done");

        _logPass();
    }

    // ── QA-PSE-02: 暂停阻止 mint ──
    function test_PSE02() public {
        _logCase("QA-PSE-02", unicode"暂停阻止 mint");

        _step("[Step 1] precondition + pause token");
        _requireNotPaused();
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        _requirePaused();

        _step("[Step 2] walletOps tries to mint (token paused -> TokenPaused)");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(TokenIssuer.mint.selector, address(token), hotWallet, 1e18),
            PauseGuardUpgradeable.TokenPaused.selector
        );
        _step("  PASS: reverted TokenPaused()");

        _step("[Step 3] cleanup: unpause");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();
        _step("  PASS: unpauseToken done");

        _logPass();
    }

    // ── QA-PSE-03: 暂停阻止 burn ──
    function test_PSE03() public {
        _logCase("QA-PSE-03", unicode"暂停阻止 burn");

        _step("[Step 1] preconditions: mint + approve BEFORE pause");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        vm.broadcast(hotWalletPk);
        token.approve(address(vault), type(uint256).max);

        _step("[Step 2] pause token");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        _requirePaused();

        _step("[Step 3] walletOps tries to burn (token paused -> TokenPaused)");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(TokenIssuer.burn.selector, address(token), hotWallet, 10e18),
            PauseGuardUpgradeable.TokenPaused.selector
        );
        _step("  PASS: reverted TokenPaused()");

        _step("[Step 4] cleanup: unpause");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();
        _step("  PASS: unpauseToken done");

        _logPass();
    }

    // ── QA-PSE-04: 解除暂停后恢复 ──
    function test_PSE04() public {
        _logCase("QA-PSE-04", unicode"解除暂停后恢复");

        _step("[Step 1] mint BEFORE pause");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        _requireBalance(hotWallet, 10e18, "hotWallet");

        _step("[Step 2] pause then unpause");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();

        _step("[Step 3] hotWallet transfers");
        uint256 hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(hotWalletPk);
        token.transfer(userA, 10e18);
        _assertDiff(hotBefore, token.balanceOf(hotWallet), -10e18, "hotWallet diff");
        _step("  PASS: transfer succeeded after unpause");

        _logPass();
    }

    // ── QA-PSE-05: 全局暂停 ──
    function test_PSE05() public {
        _logCase("QA-PSE-05", unicode"全局暂停");

        _step("[Step 1] mint BEFORE pauseAll");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        _requireBalance(hotWallet, 10e18, "hotWallet");

        _step("[Step 2] pauseOps calls pauseGlobally");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseGlobally();
        _requirePaused();

        _step("[Step 3] hotWallet tries transfer");
        _expectRevertFrom(
            hotWallet,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            PauseGuardUpgradeable.TokenPaused.selector
        );
        _step("  PASS: reverted TokenPaused()");

        _step("[Step 4] cleanup: unpauseAll");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseGlobally();
        _requireNotPaused();
        _step("  PASS: unpauseGlobally done");

        _logPass();
    }

    // ── QA-PSE-06: 全局解除暂停 ──
    function test_PSE06() public {
        _logCase("QA-PSE-06", unicode"全局解除暂停");

        _step("[Step 1] pauseAll then unpauseAll");
        _requireNotPaused();
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseGlobally();
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseGlobally();
        _requireNotPaused();

        _step("[Step 2] mint + transfer succeeds");
        _mintToHotWallet(100e18);
        uint256 hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(hotWalletPk);
        token.transfer(userA, 10e18);
        _assertDiff(hotBefore, token.balanceOf(hotWallet), -10e18, "hotWallet diff");
        _step("  PASS: transfer succeeded after unpauseAll");

        _logPass();
    }

    // ── QA-PSE-07: 全局暂停覆盖单 token 解除 ──
    function test_PSE07() public {
        _logCase("QA-PSE-07", unicode"全局暂停覆盖单 token 解除 (OR)");

        _step("[Step 1] mint BEFORE pause (token must be unpaused to mint)");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        _requireBalance(hotWallet, 10e18, "hotWallet");

        _step("[Step 2] pauseToken + pauseAll, then unpause single token");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseGlobally();
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));

        _step("[Step 3] isTokenPaused should still be true (OR logic)");
        _assertEq(pauseManager.isTokenPaused(address(token)), true, "still paused");
        _step("  PASS: isTokenPaused == true");

        _step("[Step 4] transfer still reverts");
        _expectRevertFrom(
            hotWallet,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            PauseGuardUpgradeable.TokenPaused.selector
        );
        _step("  PASS: reverted TokenPaused()");

        _step("[Step 5] cleanup: unpauseAll");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseGlobally();
        _requireNotPaused();
        _step("  PASS: unpauseGlobally done");

        _logPass();
    }

    // ── QA-PSE-08: 暂停一个 token 不影响其他 ──
    function test_PSE08() public {
        _logCase("QA-PSE-08", unicode"暂停一个 token 不影响其他");

        _step("[Step 1] deploy tokenB via Factory");
        _requireNotPaused();
        vm.broadcast(adminPk);
        address tokenBAddr = factory.createToken("Test Corp", "TSTB", "TEST001", admin, new address[](0), new address[](0), new address[](0));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        _step(string.concat("  tokenB: ", vm.toString(tokenBAddr)));

        _step("[Step 2] grant ISSUER_ROLE to wallet on tokenB + mint");
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        vm.broadcast(walletOpsPk);
        vault.mint(tokenBAddr, hotWallet, 100e18);

        _step("[Step 3] pause only tokenA");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        _assertEq(pauseManager.isTokenPaused(address(token)), true, "tokenA paused");
        _assertEq(pauseManager.isTokenPaused(tokenBAddr), false, "tokenB not paused");

        _step("[Step 4] tokenB transfer should succeed");
        uint256 hotBefore = tokenB.balanceOf(hotWallet);
        vm.broadcast(hotWalletPk);
        tokenB.transfer(userA, 10e18);
        _assertDiff(hotBefore, tokenB.balanceOf(hotWallet), -10e18, "tokenB hotWallet diff");
        _step("  PASS: tokenB transfer succeeded while tokenA paused");

        _step("[Step 5] cleanup: unpause tokenA");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();
        _step("  PASS: unpauseToken done");

        _logPass();
    }

    // ── QA-PSE-09: 普通用户不能暂停 ──
    function test_PSE09() public {
        _logCase("QA-PSE-09", unicode"普通用户不能暂停");

        _step("[Step 1] precondition: userA has no pause role");
        _assertEq(pauseManager.hasRole(PAUSE_MANAGER_PAUSE_ROLE, userA), false, "userA no PAUSE_ROLE");
        _assertEq(pauseManager.hasRole(DEFAULT_ADMIN_ROLE_HASH, userA), false, "userA no ADMIN");

        _step("[Step 2] userA tries pauseToken");
        _expectRevertFrom(
            userA,
            address(pauseManager),
            abi.encodeWithSelector(pauseManager.pauseToken.selector, address(token)),
            PauseRegistry.MissingPauseRole.selector
        );
        _step("  PASS: reverted MissingPauseRole()");

        _logPass();
    }

    // ── QA-PSE-10: admin 不能暂停 ──
    function test_PSE10() public {
        _logCase("QA-PSE-10", unicode"admin 不能暂停");

        _step("[Step 1] precondition: admin has DEFAULT_ADMIN_ROLE but NOT PAUSE_ROLE on PauseRegistry");
        _requireRole(address(pauseManager), DEFAULT_ADMIN_ROLE_HASH, admin, "admin");
        _assertEq(pauseManager.hasRole(PAUSE_MANAGER_PAUSE_ROLE, admin), false, "admin no PAUSE_ROLE");

        _step("[Step 2] admin tries pauseToken");
        _expectRevertFrom(
            admin,
            address(pauseManager),
            abi.encodeWithSelector(pauseManager.pauseToken.selector, address(token)),
            PauseRegistry.MissingPauseRole.selector
        );
        _step("  PASS: reverted MissingPauseRole()");

        _logPass();
    }

    // ── QA-PSE-11: OPS 可暂停/解除 ──
    function test_PSE11() public {
        _logCase("QA-PSE-11", unicode"OPS 可暂停/解除");

        _step("[Step 1] precondition");
        _requireNotPaused();
        _requireRole(address(pauseManager), PAUSE_MANAGER_PAUSE_ROLE, pauseOps, "pauseOps");

        _step("[Step 2] pauseOps pauses token");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        _assertEq(pauseManager.isTokenPaused(address(token)), true, "paused");
        _step("  PASS: paused");

        _step("[Step 3] pauseOps unpauses token");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _assertEq(pauseManager.isTokenPaused(address(token)), false, "unpaused");
        _step("  PASS: unpaused");

        _logPass();
    }

    // ── QA-PSE-12: 全局暂停后新部署 token 继承暂停 ──
    function test_PSE12() public {
        _logCase("QA-PSE-12", unicode"全局暂停后新部署 token 继承暂停");

        _step("[Step 1] precondition + pauseAll");
        _requireNotPaused();
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseGlobally();

        _step("[Step 2] deploy tokenB (during global pause)");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.createToken("New Corp", "NEWB", "NEW001", admin, new address[](0), new address[](0), new address[](0));

        _step("[Step 3] tokenB should be paused (inherits global)");
        _assertEq(pauseManager.isTokenPaused(tokenBAddr), true, "tokenB paused");
        _step("  PASS: isTokenPaused(tokenB) == true");

        _step("[Step 4] unpauseAll, then tokenB transfer succeeds");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseGlobally();
        _assertEq(pauseManager.isTokenPaused(tokenBAddr), false, "tokenB unpaused");

        ScaledToken tokenB = ScaledToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        vm.broadcast(walletOpsPk);
        vault.mint(tokenBAddr, hotWallet, 50e18);
        vm.broadcast(hotWalletPk);
        tokenB.transfer(userA, 10e18);
        _step("  PASS: transfer succeeded after unpauseAll");

        _logPass();
    }
}
