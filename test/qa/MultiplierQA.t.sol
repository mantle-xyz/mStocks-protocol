// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";

contract MultiplierQA is BaseQA {
    string constant MODULE = "UI Multiplier";

    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
    event TransferWithUIAmount(address indexed from, address indexed to, uint256 amount, uint256 uiAmount);

    // ═══════════════════════════════════════════════
    //      A.7 权限 [P0]
    // ═══════════════════════════════════════════════

    // ── UI-SCH-01 ──
    function test_UISCH01_AdminCannotSchedule() public {
        _logCase("UI-SCH-01", unicode"admin 不能调度");

        _step("[Step 1] admin tries setUIMultiplier");
        vm.prank(admin);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── UI-SCH-02 ──
    function test_UISCH02_OperatorCanSchedule() public {
        _logCase("UI-SCH-02", unicode"operator 可调度");

        _step("[Step 1] operator schedules multiplier 2e18 at t+1h");
        vm.prank(operator);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        assertEq(token.newUIMultiplier(), 2e18);
        _step("  PASS: newUIMultiplier == 2e18");

        _logPass();
    }

    // ── UI-SCH-03 ──
    function test_UISCH03_IssuerCannotSchedule() public {
        _logCase("UI-SCH-03", unicode"issuer 不能调度");

        _step("[Step 1] issuer tries setUIMultiplier");
        vm.prank(issuer);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── UI-SCH-04 ──
    function test_UISCH04_UserCannotSchedule() public {
        _logCase("UI-SCH-04", unicode"普通用户不能调度");

        _step("[Step 1] userA tries setUIMultiplier");
        vm.prank(userA);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.8 调度激活 [P0]
    // ═══════════════════════════════════════════════

    // ── UI-SCH-05 ──
    function test_UISCH05_NotActiveBeforeTime() public {
        _logCase("UI-SCH-05", unicode"激活前不变");

        _step("[Step 1] schedule 2e18 at t+1h, warp t+30min");
        vm.prank(operator);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 30 minutes);

        assertEq(token.uiMultiplier(), 1e18);
        _step("  PASS: uiMultiplier still 1e18");

        _logPass();
    }

    // ── UI-SCH-06 ──
    function test_UISCH06_ActiveAtTime() public {
        _logCase("UI-SCH-06", unicode"到时自动激活");

        _step("[Step 1] schedule 2e18 at t+1h, warp t+1h");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, effectiveAt);
        vm.warp(effectiveAt);

        assertEq(token.uiMultiplier(), 2e18);
        _step("  PASS: uiMultiplier == 2e18");

        _logPass();
    }

    // ── UI-SCH-07 ──
    function test_UISCH07_OverwritePending() public {
        _logCase("UI-SCH-07", unicode"覆盖待执行");

        _step("[Step 1] schedule 2e18, then overwrite with 3e18");
        vm.startPrank(operator);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        token.setUIMultiplier(3e18, block.timestamp + 2 hours);
        vm.stopPrank();

        assertEq(token.newUIMultiplier(), 3e18);
        _step("  PASS: newUIMultiplier == 3e18");

        _logPass();
    }

    // ── UI-SCH-08 ──
    function test_UISCH08_ScheduleEmitsEvent() public {
        _logCase("UI-SCH-08", unicode"调度触发事件");

        _step("[Step 1] operator setUIMultiplier, expect UIMultiplierUpdated");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        vm.expectEmit(false, false, false, true);
        emit UIMultiplierUpdated(1e18, 2e18, effectiveAt);
        token.setUIMultiplier(2e18, effectiveAt);
        _step("  PASS: UIMultiplierUpdated emitted");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.9 边界 [P0]
    // ═══════════════════════════════════════════════

    // ── UI-VAL-01 ──
    function test_UIVAL01_BelowMinimum() public {
        _logCase("UI-VAL-01", unicode"低于最小值");

        _step("[Step 1] setUIMultiplier(1e9 - 1)");
        vm.prank(operator);
        vm.expectRevert("ScaledToken: multiplier below minimum (1e-9x)");
        token.setUIMultiplier(1e9 - 1, block.timestamp + 1 hours);
        _step("  PASS: reverted below minimum");

        _logPass();
    }

    // ── UI-VAL-02 ──
    function test_UIVAL02_ExactMinimum() public {
        _logCase("UI-VAL-02", unicode"恰好最小值");

        _step("[Step 1] setUIMultiplier(1e9)");
        vm.prank(operator);
        token.setUIMultiplier(1e9, block.timestamp + 1 hours);
        assertEq(token.newUIMultiplier(), 1e9);
        _step("  PASS: accepted 1e9");

        _logPass();
    }

    // ── UI-VAL-03 ──
    function test_UIVAL03_ExactMaximum() public {
        _logCase("UI-VAL-03", unicode"恰好最大值");

        _step("[Step 1] setUIMultiplier(1e27)");
        vm.prank(operator);
        token.setUIMultiplier(1e27, block.timestamp + 1 hours);
        assertEq(token.newUIMultiplier(), 1e27);
        _step("  PASS: accepted 1e27");

        _logPass();
    }

    // ── UI-VAL-04 ──
    function test_UIVAL04_AboveMaximum() public {
        _logCase("UI-VAL-04", unicode"超过最大值");

        _step("[Step 1] setUIMultiplier(1e27 + 1)");
        vm.prank(operator);
        vm.expectRevert("ScaledToken: multiplier above maximum (1e9x)");
        token.setUIMultiplier(1e27 + 1, block.timestamp + 1 hours);
        _step("  PASS: reverted above maximum");

        _logPass();
    }

    // ── UI-VAL-05 ──
    function test_UIVAL05_EffectiveAtNotFuture() public {
        _logCase("UI-VAL-05", unicode"effectiveAt 未满足最低通知期");

        _step("[Step 1] warp to 1_000_000, set effectiveAt = block.timestamp");
        vm.warp(1_000_000);
        vm.prank(operator);
        vm.expectRevert("ScaledToken: minimum notice period not met");
        token.setUIMultiplier(2e18, block.timestamp);
        _step("  PASS: reverted (minimum notice period not met)");

        _logPass();
    }

    // ── UI-VAL-06 ──
    function test_UIVAL06_EffectiveAtTooFar() public {
        _logCase("UI-VAL-06", unicode"effectiveAt 超 365 天");

        _step("[Step 1] setUIMultiplier with effectiveAt = t + 366 days");
        vm.prank(operator);
        vm.expectRevert("ScaledToken: effective time too far in future");
        token.setUIMultiplier(2e18, block.timestamp + 366 days);
        _step("  PASS: reverted too far in future");

        _logPass();
    }

    // ── UI-VAL-07 ──
    function test_UIVAL07_EffectiveAtExact365Days() public {
        _logCase("UI-VAL-07", unicode"effectiveAt 恰好 365 天");

        _step("[Step 1] setUIMultiplier with effectiveAt = t + 365 days");
        vm.prank(operator);
        token.setUIMultiplier(2e18, block.timestamp + 365 days);
        assertEq(token.newUIMultiplier(), 2e18);
        _step("  PASS: accepted 365 days");

        _logPass();
    }

    // ── UI-VAL-08 ──
    function test_UIVAL08_EffectiveAtMaxUint() public {
        _logCase("UI-VAL-08", unicode"effectiveAt uint256 最大值");

        _step("[Step 1] setUIMultiplier with effectiveAt = type(uint256).max");
        vm.prank(operator);
        vm.expectRevert("ScaledToken: effective time too far in future");
        token.setUIMultiplier(2e18, type(uint256).max);
        _step("  PASS: reverted (overflow)");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.10 转换 [P0]
    // ═══════════════════════════════════════════════

    // ── UI-CVT-01 ──
    function test_UICVT01_1xToUIAmount() public {
        _logCase("UI-CVT-01", unicode"1x toUIAmount");

        _step("[Step 1] toUIAmount(100e18) with default 1x multiplier");
        assertEq(token.toUIAmount(100e18), 100e18);
        _step("  PASS: toUIAmount == 100e18");

        _logPass();
    }

    // ── UI-CVT-02 ──
    function test_UICVT02_2xToUIAmount() public {
        _logCase("UI-CVT-02", unicode"2x toUIAmount");

        _step("[Step 1] activate 2x multiplier, toUIAmount(100e18)");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, effectiveAt);
        vm.warp(effectiveAt);

        assertEq(token.toUIAmount(100e18), 200e18);
        _step("  PASS: toUIAmount == 200e18");

        _logPass();
    }

    // ── UI-CVT-03 ──
    function test_UICVT03_FromUIAmountInverse() public {
        _logCase("UI-CVT-03", unicode"fromUIAmount 逆运算");

        _step("[Step 1] activate 2x, fromUIAmount(200e18)");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, effectiveAt);
        vm.warp(effectiveAt);

        assertEq(token.fromUIAmount(200e18), 100e18);
        _step("  PASS: fromUIAmount == 100e18");

        _logPass();
    }

    // ── UI-CVT-04 ──
    function test_UICVT04_HalfMultiplier() public {
        _logCase("UI-CVT-04", unicode"0.5x 乘数");

        _step("[Step 1] activate 0.5x (5e17), toUIAmount(100e18)");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(5e17, effectiveAt);
        vm.warp(effectiveAt);

        assertEq(token.toUIAmount(100e18), 50e18);
        _step("  PASS: toUIAmount == 50e18");

        _logPass();
    }

    // ── UI-CVT-05 ──
    function test_UICVT05_BalanceOfUI() public {
        _logCase("UI-CVT-05", unicode"balanceOfUI");

        _step("[Step 1] mint 100e18 to issuer, activate 2x");
        _issuerMint(100e18);
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, effectiveAt);
        vm.warp(effectiveAt);

        assertEq(token.balanceOfUI(issuer), 200e18);
        _step("  PASS: balanceOfUI == 200e18");

        _logPass();
    }

    // ── UI-CVT-06 ──
    function test_UICVT06_TotalSupplyUI() public {
        _logCase("UI-CVT-06", unicode"totalSupplyUI");

        _step("[Step 1] mint 100e18, activate 2x");
        _issuerMint(100e18);
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, effectiveAt);
        vm.warp(effectiveAt);

        assertEq(token.totalSupplyUI(), 200e18);
        _step("  PASS: totalSupplyUI == 200e18");

        _logPass();
    }

    // ── UI-CVT-07 ──
    function test_UICVT07_ZeroAmount() public {
        _logCase("UI-CVT-07", unicode"零金额");

        _step("[Step 1] toUIAmount(0) with any multiplier");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(3e18, effectiveAt);
        vm.warp(effectiveAt);

        assertEq(token.toUIAmount(0), 0);
        _step("  PASS: toUIAmount(0) == 0");

        _logPass();
    }

    // ── UI-CVT-08 ──
    function test_UICVT08_RoundTripPrecision() public {
        _logCase("UI-CVT-08", unicode"往返精度");

        _step("[Step 1] with 7e17 (0.7x) multiplier, toUIAmount truncates then fromUIAmount loses precision");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(7e17, effectiveAt);
        vm.warp(effectiveAt);

        uint256 input = 1;
        uint256 ui = token.toUIAmount(input);
        assertEq(ui, 0);
        _step("  toUIAmount(1) == 0 (truncated)");

        uint256 raw = token.fromUIAmount(ui);
        assertEq(raw, 0);
        assertTrue(raw < input);
        _step("  PASS: round-trip lost precision (1 -> 0 -> 0), raw < input");

        _logPass();
    }

    // ── UI-CVT-09 ──
    function test_UICVT09_TransferEventUIAmount() public {
        _logCase("UI-CVT-09", unicode"转账事件 UI 数量");

        _step("[Step 1] activate 2x, mint and transfer 100e18");
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2e18, effectiveAt);
        vm.warp(effectiveAt);

        _mintAndTransfer(userA, 100e18);

        _step("[Step 2] userA transfers 100e18, expect uiAmount==200e18");
        vm.prank(userA);
        vm.expectEmit(true, true, false, true);
        emit TransferWithUIAmount(userA, userB, 100e18, 200e18);
        token.transfer(userB, 100e18);
        _step("  PASS: TransferWithUIAmount uiAmount == 200e18");

        _logPass();
    }
}
