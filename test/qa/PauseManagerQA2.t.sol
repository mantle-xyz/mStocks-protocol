// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {PauseManager} from "../../src/pauseManager/PauseManager.sol";
import {SecuritiesTokenFactory} from "../../src/securitiesToken/SecuritiesTokenFactory.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract DummyContract2 {}

contract PauseManagerQA2 is BaseQA {
    string constant MODULE = unicode"PauseManager + Factory 补充";

    // ═══════════════════════════════════════════════
    //      PauseManager 幂等性
    // ═══════════════════════════════════════════════

    // ── PM-IDEM-01 ──
    function test_PMIDEM01_DoublePauseIdempotent() public {
        _logCase("PM-IDEM-01", unicode"重复暂停幂等");

        _step("[Step 1] pauseOps pauses token twice");
        vm.startPrank(pauseOps);
        pauseManager.pauseToken(address(token));
        pauseManager.pauseToken(address(token));
        vm.stopPrank();

        assertTrue(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: no revert, still paused");

        _logPass();
    }

    // ── PM-IDEM-02 ──
    function test_PMIDEM02_DoubleUnpauseIdempotent() public {
        _logCase("PM-IDEM-02", unicode"重复解除幂等");

        _step("[Step 1] pause then unpause twice");
        vm.startPrank(pauseOps);
        pauseManager.pauseToken(address(token));
        pauseManager.unpauseToken(address(token));
        pauseManager.unpauseToken(address(token));
        vm.stopPrank();

        assertFalse(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: no revert, still unpaused");

        _logPass();
    }

    // ── PM-IDEM-03 ──
    function test_PMIDEM03_UnpauseNeverPausedIdempotent() public {
        _logCase("PM-IDEM-03", unicode"从未暂停时解除幂等");

        _step("[Step 1] unpause token that was never paused");
        vm.prank(pauseOps);
        pauseManager.unpauseToken(address(token));
        assertFalse(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: no revert");

        _logPass();
    }

    // ── PM-IDEM-04 ──
    function test_PMIDEM04_DoublePauseAllIdempotent() public {
        _logCase("PM-IDEM-04", unicode"全局重复暂停幂等");

        _step("[Step 1] pauseAllTokens twice");
        vm.startPrank(pauseOps);
        pauseManager.pauseAllTokens();
        pauseManager.pauseAllTokens();
        vm.stopPrank();

        assertTrue(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: no revert");

        _logPass();
    }

    // ── PM-IDEM-05 ──
    function test_PMIDEM05_DoubleUnpauseAllIdempotent() public {
        _logCase("PM-IDEM-05", unicode"全局重复解除幂等");

        _step("[Step 1] pauseAll, unpauseAll twice");
        vm.startPrank(pauseOps);
        pauseManager.pauseAllTokens();
        pauseManager.unpauseAllTokens();
        pauseManager.unpauseAllTokens();
        vm.stopPrank();

        assertFalse(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: no revert");

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
    function test_PMSTATE02_AllTokensPausedPublicVar() public {
        _logCase("PM-STATE-02", unicode"allTokensPaused 公共变量");

        _step("[Step 1] before -> false");
        assertFalse(pauseManager.allTokensPaused());

        _step("[Step 2] after pauseAll -> true");
        vm.prank(pauseOps);
        pauseManager.pauseAllTokens();
        assertTrue(pauseManager.allTokensPaused());
        _step("  PASS: variable accurately reflects state");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Factory setPauseManager 边界
    // ═══════════════════════════════════════════════

    // ── FT-CFG-06 ──
    function test_FTCFG06_ZeroPauseManagerReverts() public {
        _logCase("FT-CFG-06", unicode"Factory setPauseManager 零地址回滚");

        _step("[Step 1] factory.setPauseManager(address(0))");
        vm.prank(admin);
        vm.expectRevert(SecuritiesTokenFactory.ZeroAddress.selector);
        factory.setPauseManager(address(0));
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── FT-CFG-07 ──
    function test_FTCFG07_InvalidPauseManagerReverts() public {
        _logCase("FT-CFG-07", unicode"Factory setPauseManager 无效合约回滚");

        _step("[Step 1] factory.setPauseManager(dummyContract)");
        address dummy = address(new DummyContract2());
        vm.prank(admin);
        vm.expectRevert(SecuritiesTokenFactory.InvalidPauseManagerContract.selector);
        factory.setPauseManager(dummy);
        _step("  PASS: reverted InvalidPauseManagerContract()");

        _logPass();
    }

    // ── FT-CFG-08 ──
    function test_FTCFG08_NonAdminCannotSetPauseManager() public {
        _logCase("FT-CFG-08", unicode"非 admin 不能设 Factory pauseManager");

        _step("[Step 1] stranger tries setPauseManager");
        PauseManager newPM = new PauseManager(admin);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE_HASH));
        factory.setPauseManager(address(newPM));
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }
}
