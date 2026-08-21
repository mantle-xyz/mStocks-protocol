// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract DummyContract2 {}

contract PauseManagerQA2 is BaseQA {
    string constant MODULE = unicode"PauseRegistry + Factory 补充";

    // ═══════════════════════════════════════════════
    //      PauseRegistry 幂等性
    // ═══════════════════════════════════════════════

    // ── PM-IDEM-01 ──
    function test_PMIDEM01_DoublePauseReverts() public {
        _logCase("PM-IDEM-01", unicode"重复暂停回滚");

        _step("[Step 1] pauseOps pauses token, second pause reverts");
        vm.startPrank(pauseOps);
        pauseManager.pauseToken(address(token));
        vm.expectRevert(PauseRegistry.TokenAlreadyPaused.selector);
        pauseManager.pauseToken(address(token));
        vm.stopPrank();

        assertTrue(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: second pause reverted TokenAlreadyPaused()");

        _logPass();
    }

    // ── PM-IDEM-02 ──
    function test_PMIDEM02_DoubleUnpauseReverts() public {
        _logCase("PM-IDEM-02", unicode"重复解除回滚");

        _step("[Step 1] pause then unpause, second unpause reverts");
        vm.startPrank(pauseOps);
        pauseManager.pauseToken(address(token));
        pauseManager.unpauseToken(address(token));
        vm.expectRevert(PauseRegistry.TokenNotPaused.selector);
        pauseManager.unpauseToken(address(token));
        vm.stopPrank();

        assertFalse(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: second unpause reverted TokenNotPaused()");

        _logPass();
    }

    // ── PM-IDEM-03 ──
    function test_PMIDEM03_UnpauseNeverPausedReverts() public {
        _logCase("PM-IDEM-03", unicode"从未暂停时解除回滚");

        _step("[Step 1] unpause token that was never paused");
        vm.prank(pauseOps);
        vm.expectRevert(PauseRegistry.TokenNotPaused.selector);
        pauseManager.unpauseToken(address(token));
        _step("  PASS: reverted TokenNotPaused()");

        _logPass();
    }

    // ── PM-IDEM-04 ──
    function test_PMIDEM04_DoublePauseAllReverts() public {
        _logCase("PM-IDEM-04", unicode"全局重复暂停回滚");

        _step("[Step 1] pauseGlobally, second call reverts");
        vm.startPrank(pauseOps);
        pauseManager.pauseGlobally();
        vm.expectRevert(PauseRegistry.AlreadyGloballyPaused.selector);
        pauseManager.pauseGlobally();
        vm.stopPrank();

        assertTrue(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: second pauseGlobally reverted AlreadyGloballyPaused()");

        _logPass();
    }

    // ── PM-IDEM-05 ──
    function test_PMIDEM05_DoubleUnpauseAllReverts() public {
        _logCase("PM-IDEM-05", unicode"全局重复解除回滚");

        _step("[Step 1] pauseGlobally, unpauseGlobally, second unpause reverts");
        vm.startPrank(pauseOps);
        pauseManager.pauseGlobally();
        pauseManager.unpauseGlobally();
        vm.expectRevert(PauseRegistry.NotGloballyPaused.selector);
        pauseManager.unpauseGlobally();
        vm.stopPrank();

        assertFalse(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: second unpauseGlobally reverted NotGloballyPaused()");

        _logPass();
    }

    // ── PM-STATE-01 ──
    function test_PMSTATE01_PausedTokensPublicMapping() public {
        _logCase("PM-STATE-01", unicode"pausedTokens 公共映射");

        _step("[Step 1] before pause -> false");
        assertFalse(pauseManager.pausedTokens(address(token)));

        _step("[Step 2] after pause -> true");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));
        assertTrue(pauseManager.pausedTokens(address(token)));
        _step("  PASS: mapping accurately reflects state");

        _logPass();
    }

    // ── PM-STATE-02 ──
    function test_PMSTATE02_GlobalPausedPublicVar() public {
        _logCase("PM-STATE-02", unicode"globalPaused 公共变量");

        _step("[Step 1] before -> false");
        assertFalse(pauseManager.globalPaused());

        _step("[Step 2] after pauseAll -> true");
        vm.prank(pauseOps);
        pauseManager.pauseGlobally();
        assertTrue(pauseManager.globalPaused());
        _step("  PASS: variable accurately reflects state");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Factory setDefaultPauseManager 边界
    // ═══════════════════════════════════════════════

    // ── FT-CFG-06 ──
    function test_FTCFG06_ZeroPauseManagerReverts() public {
        _logCase("FT-CFG-06", unicode"Factory setDefaultPauseManager 零地址回滚");

        _step("[Step 1] factory.setDefaultPauseManager(address(0))");
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.ZeroAddress.selector);
        factory.setDefaultPauseManager(address(0));
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── FT-CFG-07 ──
    function test_FTCFG07_InvalidPauseManagerReverts() public {
        _logCase("FT-CFG-07", unicode"Factory setDefaultPauseManager 无效合约回滚");

        _step("[Step 1] factory.setDefaultPauseManager(dummyContract)");
        address dummy = address(new DummyContract2());
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.InvalidPauseManagerContract.selector);
        factory.setDefaultPauseManager(dummy);
        _step("  PASS: reverted InvalidPauseManagerContract()");

        _logPass();
    }

    // ── FT-CFG-08 ──
    function test_FTCFG08_NonAdminCannotSetPauseManager() public {
        _logCase("FT-CFG-08", unicode"非 admin 不能设 Factory pauseManager");

        _step("[Step 1] stranger tries setDefaultPauseManager");
        PauseRegistry newPM = new PauseRegistry(admin);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE_HASH));
        factory.setDefaultPauseManager(address(newPM));
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }
}
