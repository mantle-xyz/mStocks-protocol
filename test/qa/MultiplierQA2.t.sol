// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MultiplierQA2 is BaseQA {
    string constant MODULE = unicode"UI Multiplier 补充";

    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
    event UIMultiplierChangeOverwritten(
        uint256 overwrittenMultiplier,
        uint256 overwrittenEffectiveAt,
        uint256 newMultiplier,
        uint256 newEffectiveAt
    );

    // ═══════════════════════════════════════════════
    //      hasPendingMultiplier / pendingMultiplier
    // ═══════════════════════════════════════════════

    // ── UI-STATE-01 ──
    function test_UISTATE01_NoPendingInitially() public {
        _logCase("UI-STATE-01", unicode"初始无 pending");

        _step("[Step 1] query hasPendingMultiplier()");
        assertFalse(token.hasPendingMultiplier());
        _step("  PASS: hasPendingMultiplier == false");

        _step("[Step 2] query pendingMultiplier()");
        (uint256 mult, uint256 effAt) = token.pendingMultiplier();
        assertEq(mult, 0);
        assertEq(effAt, 0);
        _step("  PASS: pendingMultiplier() returns (0, 0)");

        _logPass();
    }

    // ── UI-STATE-02 ──
    function test_UISTATE02_PendingAfterSchedule() public {
        _logCase("UI-STATE-02", unicode"调度后有 pending");

        _step("[Step 1] schedule 2e18 at t+1h");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, effectiveAt);

        assertTrue(token.hasPendingMultiplier());
        _step("  PASS: hasPendingMultiplier == true");

        (uint256 mult, uint256 effAt) = token.pendingMultiplier();
        assertEq(mult, 2e18);
        assertEq(effAt, effectiveAt);
        _step("  PASS: pendingMultiplier() returns (2e18, effectiveAt)");

        _logPass();
    }

    // ── UI-STATE-03 ──
    function test_UISTATE03_NoPendingAfterActivation() public {
        _logCase("UI-STATE-03", unicode"激活后无 pending");

        _step("[Step 1] schedule and activate");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, effectiveAt);
        vm.warp(effectiveAt);

        assertFalse(token.hasPendingMultiplier());
        _step("  PASS: hasPendingMultiplier == false after activation");

        (uint256 mult, uint256 effAt) = token.pendingMultiplier();
        assertEq(mult, 0);
        assertEq(effAt, 0);
        _step("  PASS: pendingMultiplier() returns (0, 0)");

        _logPass();
    }

    // ── UI-STATE-04 ──
    function test_UISTATE04_EffectiveAtReturns() public {
        _logCase("UI-STATE-04", unicode"effectiveAt 正确返回");

        _step("[Step 1] no pending -> effectiveAt == 0");
        assertEq(token.effectiveAt(), 0);

        _step("[Step 2] schedule -> effectiveAt == scheduled time");
        uint256 ea = block.timestamp + 2 hours;
        vm.prank(operator);
        token.setUIMultiplier(3e18, ea);
        assertEq(token.effectiveAt(), ea);
        _step("  PASS: effectiveAt matches scheduled time");

        _step("[Step 3] after activation -> effectiveAt == 0");
        vm.warp(ea);
        assertEq(token.effectiveAt(), 0);
        _step("  PASS: effectiveAt == 0 after activation");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      连续调度与密封逻辑
    // ═══════════════════════════════════════════════

    // ── UI-SEQ-01 ──
    function test_UISEQ01_SequentialScheduleAfterActivation() public {
        _logCase("UI-SEQ-01", unicode"激活后再调度");

        _step("[Step 1] schedule 2e18, activate");
        uint256 ea1 = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, ea1);
        vm.warp(ea1 + 1);
        assertEq(token.uiMultiplier(), 2e18);
        _step("  first multiplier activated: 2e18");

        _step("[Step 2] schedule 3e18 from current time");
        uint256 ea2 = ea1 + 1 + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(3e18, ea2);
        assertEq(token.uiMultiplier(), 2e18);
        _step("  still 2e18 before activation");

        _step("[Step 3] activate second");
        vm.warp(ea2 + 1);
        assertEq(token.uiMultiplier(), 3e18);
        _step("  PASS: uiMultiplier == 3e18 after second activation");

        _logPass();
    }

    // ── UI-SEQ-02 ──
    function test_UISEQ02_OverwriteEmitsEvent() public {
        _logCase("UI-SEQ-02", unicode"覆盖触发 UIMultiplierChangeOverwritten 事件");

        _step("[Step 1] schedule 2e18 at t+1h");
        uint256 ea1 = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, ea1);

        _step("[Step 2] overwrite with 3e18 at t+2h, expect overwrite event");
        uint256 ea2 = block.timestamp + 2 hours;
        vm.prank(operator);
        vm.expectEmit(false, false, false, true);
        emit UIMultiplierChangeOverwritten(2e18, ea1, 3e18, ea2);
        token.setUIMultiplier(3e18, ea2);
        _step("  PASS: UIMultiplierChangeOverwritten emitted");

        _logPass();
    }

    // ── UI-SEQ-03 ──
    function test_UISEQ03_ThreeSequentialChanges() public {
        _logCase("UI-SEQ-03", unicode"三次连续变更");

        _step("[Step 1] 1x -> 2x -> activate -> 5e17 -> activate -> 3e18 -> activate");
        uint256 ea1 = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, ea1);
        vm.warp(ea1 + 1);
        assertEq(token.uiMultiplier(), 2e18);
        _step("  2e18 activated");

        uint256 ea2 = ea1 + 1 + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(5e17, ea2);
        vm.warp(ea2 + 1);
        assertEq(token.uiMultiplier(), 5e17);
        _step("  5e17 activated");

        uint256 ea3 = ea2 + 1 + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(3e18, ea3);
        vm.warp(ea3 + 1);
        assertEq(token.uiMultiplier(), 3e18);
        _step("  PASS: 3e18 activated - all three changes applied correctly");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      权限撤销后 multiplier 操作失败
    // ═══════════════════════════════════════════════

    // ── UI-PERM-01 ──
    function test_UIPERM01_RevokeOpsBlocksMultiplier() public {
        _logCase("UI-PERM-01", unicode"撤销 OPS 后 setUIMultiplier 失败");

        _step("[Step 1] admin revokes OPS_ROLE from operator");
        vm.prank(admin);
        token.revokeRole(OPS_ROLE, operator);

        _step("[Step 2] operator tries setUIMultiplier");
        vm.prank(operator);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── UI-PERM-02 ──
    function test_UIPERM02_RenounceOpsBlocksMultiplier() public {
        _logCase("UI-PERM-02", unicode"renounce OPS 后 setUIMultiplier 失败");

        _step("[Step 1] operator renounces OPS_ROLE");
        vm.prank(operator);
        token.renounceRole(OPS_ROLE, operator);
        assertFalse(token.hasRole(OPS_ROLE, operator));

        _step("[Step 2] operator tries setUIMultiplier");
        vm.prank(operator);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _step("  PASS: reverted after renounce");

        _logPass();
    }

    // ── UI-PERM-03 ──
    function test_UIPERM03_RenounceIssuerBlocksMint() public {
        _logCase("UI-PERM-03", unicode"renounce ISSUER 后 mint 失败");

        _step("[Step 1] issuer(wallet) renounces ISSUER_ROLE");
        vm.prank(issuer);
        token.renounceRole(ISSUER_ROLE, issuer);
        assertFalse(token.hasRole(ISSUER_ROLE, issuer));

        _step("[Step 2] issuer tries to mint");
        vm.prank(issuer);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.mint(1e18);
        _step("  PASS: reverted after renounce");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      newUIMultiplier 在各状态下的返回值
    // ═══════════════════════════════════════════════

    // ── UI-STATE-05 ──
    function test_UISTATE05_NewUIMultiplierNoPending() public {
        _logCase("UI-STATE-05", unicode"无 pending 时 newUIMultiplier 等于 uiMultiplier");

        _step("[Step 1] no pending change");
        assertEq(token.newUIMultiplier(), token.uiMultiplier());
        assertEq(token.newUIMultiplier(), 1e18);
        _step("  PASS: newUIMultiplier == uiMultiplier == 1e18");

        _logPass();
    }

    // ── UI-STATE-06 ──
    function test_UISTATE06_NewUIMultiplierWithPending() public {
        _logCase("UI-STATE-06", unicode"有 pending 时 newUIMultiplier 返回新值");

        _step("[Step 1] schedule 5e18");
        vm.prank(operator);
        token.setUIMultiplier(5e18, block.timestamp + 1 hours);

        assertEq(token.uiMultiplier(), 1e18);
        _step("  uiMultiplier still 1e18");
        assertEq(token.newUIMultiplier(), 5e18);
        _step("  PASS: newUIMultiplier == 5e18");

        _logPass();
    }
}
