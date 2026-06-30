// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";

contract QAMultiplier is BaseQAScript {
    function run() external {
        _loadEnv();

        test_MUL01();
        test_MUL02();
        test_MUL03();
        test_MUL04();
        test_MUL05();
        test_MUL06();
        test_MUL07();
        test_MUL08();
        test_MUL09();
        // MUL-10 需要分阶段执行，不在 run() 中:
        //   forge script ... --sig "test_MUL10_schedule()" --broadcast
        //   sleep 70
        //   forge script ... --sig "test_MUL10_verify()" --broadcast
    }

    function _operatorAddr() internal view returns (address) {
        return token.getRoleMember(TOKEN_OPS_ROLE, 0);
    }

    function _resetPendingMultiplier() internal {
        vm.broadcast(walletOpsPk);
        token.setUIMultiplier(1e18, block.timestamp + 300);
    }

    // ── QA-MUL-01: admin 不能调度乘数 ──
    function test_MUL01() public {
        _logCase("QA-MUL-01", unicode"admin 不能调度乘数");

        _step("[Step 1] precondition: admin has DEFAULT_ADMIN_ROLE but NOT OPS_ROLE");
        _requireRole(address(token), DEFAULT_ADMIN_ROLE_HASH, admin, "admin");
        _assertEq(token.hasRole(TOKEN_OPS_ROLE, admin), false, "admin no OPS_ROLE");

        _step("[Step 2] admin tries setUIMultiplier");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(token.setUIMultiplier.selector, 2e18, block.timestamp + 1 hours),
            SecuritiesToken.UnauthorizedRole.selector
        );
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── QA-MUL-02: operator 可调度 ──
    function test_MUL02() public {
        _logCase("QA-MUL-02", unicode"operator 可调度");

        _step("[Step 1] precondition: operator has OPS_ROLE");
        address operator = _operatorAddr();
        _requireRole(address(token), TOKEN_OPS_ROLE, operator, "operator");

        _step("[Step 2] operator schedules 2e18 at t+1h");
        uint256 effectiveTime = block.timestamp + 1 hours;
        vm.broadcast(walletOpsPk);
        token.setUIMultiplier(2e18, effectiveTime);

        _step("[Step 3] verify pending state");
        _assertEq(token.newUIMultiplier(), 2e18, "newUIMultiplier");
        _step("  PASS: newUIMultiplier == 2e18");

        _assertEq(token.hasPendingMultiplier(), true, "hasPendingMultiplier");
        _step("  PASS: hasPendingMultiplier == true");

        _assertEq(token.uiMultiplier(), 1e18, "uiMultiplier still 1e18");
        _step("  PASS: uiMultiplier still 1e18");

        _step("[Step 4] cleanup: overwrite pending with 1e18");
        _resetPendingMultiplier();
        _step("  PASS: pending reset to 1e18");

        _logPass();
    }

    // ── QA-MUL-03: issuer 不能调度 ──
    function test_MUL03() public {
        _logCase("QA-MUL-03", unicode"issuer 不能调度");

        _step("[Step 1] precondition: wallet has ISSUER_ROLE but NOT OPS_ROLE");
        _requireRole(address(token), ISSUER_ROLE, address(wallet), "wallet ISSUER");
        _assertEq(token.hasRole(TOKEN_OPS_ROLE, address(wallet)), false, "wallet no OPS_ROLE");

        _step("[Step 2] wallet (issuer) tries setUIMultiplier via low-level call");
        _expectRevert(
            address(token),
            abi.encodeWithSelector(token.setUIMultiplier.selector, 2e18, block.timestamp + 1 hours),
            SecuritiesToken.UnauthorizedRole.selector
        );
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── QA-MUL-04: 普通用户不能调度 ──
    function test_MUL04() public {
        _logCase("QA-MUL-04", unicode"普通用户不能调度");

        _step("[Step 1] precondition: userA has no OPS_ROLE");
        _assertEq(token.hasRole(TOKEN_OPS_ROLE, userA), false, "userA no OPS_ROLE");

        _step("[Step 2] userA tries setUIMultiplier");
        _expectRevertFrom(
            userA,
            address(token),
            abi.encodeWithSelector(token.setUIMultiplier.selector, 2e18, block.timestamp + 1 hours),
            SecuritiesToken.UnauthorizedRole.selector
        );
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── QA-MUL-05: 乘数低于下限 ──
    function test_MUL05() public {
        _logCase("QA-MUL-05", unicode"乘数低于下限");

        _step("[Step 1] precondition: operator has OPS_ROLE");
        address operator = _operatorAddr();
        _requireRole(address(token), TOKEN_OPS_ROLE, operator, "operator");

        _step("[Step 2] operator tries setUIMultiplier(1e9 - 1)");
        _expectRevertFromWithMessage(
            operator,
            address(token),
            abi.encodeWithSelector(token.setUIMultiplier.selector, 1e9 - 1, block.timestamp + 1 hours),
            "SecuritiesToken: multiplier below minimum (1e-9x)"
        );
        _step("  PASS: reverted 'multiplier below minimum'");

        _logPass();
    }

    // ── QA-MUL-06: 乘数高于上限 ──
    function test_MUL06() public {
        _logCase("QA-MUL-06", unicode"乘数高于上限");

        _step("[Step 1] precondition: operator has OPS_ROLE");
        address operator = _operatorAddr();
        _requireRole(address(token), TOKEN_OPS_ROLE, operator, "operator");

        _step("[Step 2] operator tries setUIMultiplier(1e27 + 1)");
        _expectRevertFromWithMessage(
            operator,
            address(token),
            abi.encodeWithSelector(token.setUIMultiplier.selector, 1e27 + 1, block.timestamp + 1 hours),
            "SecuritiesToken: multiplier above maximum (1e9x)"
        );
        _step("  PASS: reverted 'multiplier above maximum'");

        _logPass();
    }

    // ── QA-MUL-07: effectiveAt 超过 365 天 ──
    function test_MUL07() public {
        _logCase("QA-MUL-07", unicode"effectiveAt 超过 365 天");

        _step("[Step 1] precondition: operator has OPS_ROLE");
        address operator = _operatorAddr();
        _requireRole(address(token), TOKEN_OPS_ROLE, operator, "operator");

        _step("[Step 2] operator tries setUIMultiplier with t + 366 days");
        _expectRevertFromWithMessage(
            operator,
            address(token),
            abi.encodeWithSelector(token.setUIMultiplier.selector, 2e18, block.timestamp + 366 days),
            "SecuritiesToken: effective time too far in future"
        );
        _step("  PASS: reverted 'effective time too far in future'");

        _logPass();
    }

    // ── QA-MUL-08: 待执行期间查询 ──
    function test_MUL08() public {
        _logCase("QA-MUL-08", unicode"待执行期间查询");

        _step("[Step 1] operator schedules 2e18 at t+1h");
        uint256 effectiveTime = block.timestamp + 1 hours;
        vm.broadcast(walletOpsPk);
        token.setUIMultiplier(2e18, effectiveTime);

        _step("[Step 2] query current multiplier");
        _assertEq(token.uiMultiplier(), 1e18, "uiMultiplier");
        _step("  PASS: uiMultiplier == 1e18 (unchanged)");

        _step("[Step 3] query pending multiplier");
        _assertEq(token.newUIMultiplier(), 2e18, "newUIMultiplier");
        _step("  PASS: newUIMultiplier == 2e18");

        _step("[Step 4] query effectiveAt");
        _assertEq(token.effectiveAt(), effectiveTime, "effectiveAt");
        _step(string.concat("  PASS: effectiveAt == ", vm.toString(effectiveTime)));

        _step("[Step 5] cleanup: overwrite pending with 1e18");
        _resetPendingMultiplier();
        _step("  PASS: pending reset to 1e18");

        _logPass();
    }

    // ── QA-MUL-09: toUIAmount / balanceOfUI / totalSupplyUI (1x 基线) ──
    function test_MUL09() public {
        _logCase("QA-MUL-09", unicode"toUIAmount / balanceOfUI / totalSupplyUI (1x 基线)");

        _step("[Step 1] precondition: multiplier == 1e18, mint to hotWallet");
        _requireNotPaused();
        _assertEq(token.uiMultiplier(), 1e18, "uiMultiplier == 1e18");
        _mintToHotWallet(100e18);

        _step("[Step 2] toUIAmount(100e18) == 100e18 at 1x");
        _assertEq(token.toUIAmount(100e18), 100e18, "toUIAmount");
        _step("  PASS: toUIAmount(100e18) == 100e18");

        _step("[Step 3] balanceOfUI(hotWallet) == balanceOf(hotWallet) at 1x");
        uint256 raw = token.balanceOf(hotWallet);
        uint256 ui = token.balanceOfUI(hotWallet);
        _assertEq(ui, raw, "balanceOfUI == balanceOf");
        _step("  PASS: balanceOfUI == balanceOf");

        _step("[Step 4] totalSupplyUI == totalSupply at 1x");
        _assertEq(token.totalSupplyUI(), token.totalSupply(), "totalSupplyUI == totalSupply");
        _step("  PASS: totalSupplyUI == totalSupply");

        _logPass();
    }

    // ── QA-MUL-10: 乘数生效后 UI 查询验证 (2x) ──
    // 分两阶段执行:
    //   阶段 1 (schedule): forge script ... --sig "test_MUL10_schedule()" ... --broadcast
    //   等待:              sleep 70
    //   阶段 2 (verify):   forge script ... --sig "test_MUL10_verify()" ... (只读，不需要 broadcast)
    function test_MUL10_schedule() public {
        _logCase("QA-MUL-10", unicode"乘数生效后 UI 查询验证 — 阶段1: 调度");

        _step("[Step 1] precondition: multiplier == 1e18");
        _assertEq(token.uiMultiplier(), 1e18, "uiMultiplier == 1e18");

        _step("[Step 2] operator schedules 2e18 at t+300s");
        uint256 effectiveTime = block.timestamp + 300;
        vm.broadcast(walletOpsPk);
        token.setUIMultiplier(2e18, effectiveTime);

        _assertEq(token.newUIMultiplier(), 2e18, "newUIMultiplier");
        _assertEq(token.hasPendingMultiplier(), true, "hasPendingMultiplier");
        _step(string.concat("  PASS: scheduled 2e18 at ", vm.toString(effectiveTime)));
        _step("  >>> shell: sleep 70 then run test_MUL10_verify()");

        _logPass();
    }

    function test_MUL10_verify() public {
        _logCase("QA-MUL-10", unicode"乘数生效后 UI 查询验证 — 阶段2: 验证");

        _step("[Step 1] confirm multiplier activated to 2e18");
        _assertEq(token.uiMultiplier(), 2e18, "uiMultiplier == 2e18");
        _assertEq(token.hasPendingMultiplier(), false, "no pending");
        _step("  PASS: uiMultiplier == 2e18, no pending");

        _step("[Step 2] mint 100e18 to hotWallet, verify UI amounts at 2x");
        _requireNotPaused();
        _mintToHotWallet(100e18);

        uint256 raw = token.balanceOf(hotWallet);
        uint256 uiBal = token.balanceOfUI(hotWallet);
        _step(string.concat("  raw balance: ", vm.toString(raw)));
        _step(string.concat("  UI balance:  ", vm.toString(uiBal)));
        _assertEq(uiBal, raw * 2, "balanceOfUI == 2 * balanceOf");
        _step("  PASS: balanceOfUI == 2 * balanceOf");

        _step("[Step 3] toUIAmount(100e18) == 200e18");
        _assertEq(token.toUIAmount(100e18), 200e18, "toUIAmount");
        _step("  PASS: toUIAmount(100e18) == 200e18");

        _step("[Step 4] totalSupplyUI == 2 * totalSupply");
        _assertEq(token.totalSupplyUI(), token.totalSupply() * 2, "totalSupplyUI");
        _step("  PASS: totalSupplyUI == 2 * totalSupply");

        _step("[Step 5] cleanup: schedule 1e18 to restore");
        vm.broadcast(walletOpsPk);
        token.setUIMultiplier(1e18, block.timestamp + 300);
        _step("  PASS: scheduled 1e18 restore");

        _logPass();
    }
}
