// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";

contract PauseManagerQA is BaseQA {
    string constant MODULE = unicode"PauseRegistry 独立";

    ScaledToken internal tokenB;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        address[] memory empty = new address[](0);
        tokenB = ScaledToken(factory.createToken("Google", "GOOG", "US02079K3059", admin, empty, empty));
        vm.stopPrank();
    }

    // ── PM-INIT-01 ──
    function test_PMINIT01_ConstructorSetsAdmin() public {
        _logCase("PM-INIT-01", unicode"构造设置 admin");

        _step("[Step 1] deploy new PauseRegistry(admin)");
        PauseRegistry pm = new PauseRegistry(admin);
        assertTrue(pm.hasRole(pm.DEFAULT_ADMIN_ROLE(), admin));
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── PM-INIT-02 ──
    function test_PMINIT02_ZeroAddressReverts() public {
        _logCase("PM-INIT-02", unicode"零地址回滚");

        _step("[Step 1] deploy PauseRegistry(address(0))");
        vm.expectRevert(PauseRegistry.ZeroAddress.selector);
        new PauseRegistry(address(0));
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── PM-PAUSE-01 ──
    function test_PMPAUSE01_OpsCanPause() public {
        _logCase("PM-PAUSE-01", unicode"OPS 可暂停");

        _step("[Step 1] pauseOps pauses token");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));
        assertTrue(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: isTokenPaused == true");

        _logPass();
    }

    // ── PM-PAUSE-02 ──
    function test_PMPAUSE02_OpsCanUnpause() public {
        _logCase("PM-PAUSE-02", unicode"OPS 可解除");

        _step("[Step 1] pause then unpause");
        vm.startPrank(pauseOps);
        pauseManager.pauseToken(address(token));
        pauseManager.unpauseToken(address(token));
        vm.stopPrank();
        assertFalse(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: isTokenPaused == false");

        _logPass();
    }

    // ── PM-PAUSE-03 ──
    function test_PMPAUSE03_AdminCannotPause() public {
        _logCase("PM-PAUSE-03", unicode"admin 不能暂停");

        _step("[Step 1] admin tries pauseToken");
        vm.prank(admin);
        vm.expectRevert(PauseRegistry.MissingPauseRole.selector);
        pauseManager.pauseToken(address(token));
        _step("  PASS: reverted MissingPauseRole()");

        _logPass();
    }

    // ── PM-PAUSE-04 ──
    function test_PMPAUSE04_StrangerCannotPause() public {
        _logCase("PM-PAUSE-04", unicode"普通用户不能暂停");

        _step("[Step 1] stranger tries pauseToken");
        vm.prank(stranger);
        vm.expectRevert(PauseRegistry.MissingPauseRole.selector);
        pauseManager.pauseToken(address(token));
        _step("  PASS: reverted MissingPauseRole()");

        _logPass();
    }

    // ── PM-PAUSE-05 ──
    function test_PMPAUSE05_StrangerCannotUnpause() public {
        _logCase("PM-PAUSE-05", unicode"普通用户不能解除");

        _step("[Step 1] pause token, stranger tries unpause");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        vm.prank(stranger);
        vm.expectRevert(PauseRegistry.MissingUnpauseRole.selector);
        pauseManager.unpauseToken(address(token));
        _step("  PASS: reverted MissingUnpauseRole()");

        _logPass();
    }

    // ── PM-PAUSE-06 ──
    function test_PMPAUSE06_StrangerCannotPauseAll() public {
        _logCase("PM-PAUSE-06", unicode"普通用户不能全局暂停");

        _step("[Step 1] stranger tries pauseGlobally");
        vm.prank(stranger);
        vm.expectRevert(PauseRegistry.MissingPauseRole.selector);
        pauseManager.pauseGlobally();
        _step("  PASS: reverted MissingPauseRole()");

        _logPass();
    }

    // ── PM-PAUSE-07 ──
    function test_PMPAUSE07_StrangerCannotUnpauseAll() public {
        _logCase("PM-PAUSE-07", unicode"普通用户不能解除全局");

        _step("[Step 1] pauseAll, stranger tries unpauseAll");
        vm.prank(pauseOps);
        pauseManager.pauseGlobally();

        vm.prank(stranger);
        vm.expectRevert(PauseRegistry.MissingUnpauseRole.selector);
        pauseManager.unpauseGlobally();
        _step("  PASS: reverted MissingUnpauseRole()");

        _logPass();
    }

    // ── PM-PAUSE-08 ──
    function test_PMPAUSE08_IsTokenPausedAccurate() public {
        _logCase("PM-PAUSE-08", unicode"isTokenPaused 准确");

        _step("[Step 1] pause tokenA only");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        assertTrue(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: tokenA paused == true");
        assertFalse(pauseManager.isTokenPaused(address(tokenB)));
        _step("  PASS: tokenB paused == false");

        _logPass();
    }
}
