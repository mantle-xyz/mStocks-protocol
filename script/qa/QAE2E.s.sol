// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {PauseGuardUpgradeable} from "../../src/pauseRegistry/PauseGuardUpgradeable.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";

contract QAE2E is BaseQAScript {
    function run() external {
        _loadEnv();

        test_E2E01();
        test_E2E02();
        test_E2E03();
        test_E2E04();
        test_E2E05();
        test_E2E06();
        test_E2E07();
        test_E2E08();
        test_E2E09();
        test_E2E10();
        test_E2E11();
        test_E2E12();
        test_E2E13();
        test_E2E14();
        test_E2E15();
        test_E2E16();
        test_E2E17();
        test_E2E18();
        test_E2E19();
        test_E2E20();
        test_E2E21();
        test_E2E22();
        test_E2E23();
    }

    // ── helpers ──

    function _blockUser(address user) internal {
        address[] memory a = new address[](1);
        a[0] = user;
        vm.broadcast(complianceOpsPk);
        compliance.blockUsers(address(token), a);
    }

    function _unblockUser(address user) internal {
        address[] memory a = new address[](1);
        a[0] = user;
        vm.broadcast(complianceOpsPk);
        compliance.unblockUsers(address(token), a);
    }

    function _sanctionUser(address user) internal {
        address[] memory a = new address[](1);
        a[0] = user;
        vm.broadcast(complianceOpsPk);
        compliance.sanctionUsers(a);
    }

    function _unsanctionUser(address user) internal {
        address[] memory a = new address[](1);
        a[0] = user;
        vm.broadcast(complianceOpsPk);
        compliance.unsanctionUsers(a);
    }

    // ── QA-E2E-01: 代币发行->分发->二级流通完整链路 ──
    function test_E2E01() public {
        _logCase("QA-E2E-01", unicode"代币发行->分发->二级流通完整链路");

        _step("[Step 1] preconditions");
        _requireNotPaused();

        _step("[Step 2] walletOPS mints 10000e18 to hotWallet");
        uint256 supplyBefore = token.totalSupply();
        uint256 hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), hotWallet, 10000e18);
        _assertDiff(hotBefore, token.balanceOf(hotWallet), 10000e18, "hotWallet +10000");
        _step("  PASS: hotWallet +10000e18");

        _step("[Step 3] hotWallet distributes 3000e18 to userA");
        uint256 aBefore = token.balanceOf(userA);
        hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(hotWalletPk);
        token.transfer(userA, 3000e18);
        _assertDiff(hotBefore, token.balanceOf(hotWallet), -3000e18, "hotWallet -3000");
        _assertDiff(aBefore, token.balanceOf(userA), 3000e18, "userA +3000");
        _step("  PASS: hotWallet -3000e18, userA +3000e18");

        _step("[Step 4] userA transfers 1000e18 to userB (secondary market)");
        aBefore = token.balanceOf(userA);
        uint256 bBefore = token.balanceOf(userB);
        vm.broadcast(userAPk);
        token.transfer(userB, 1000e18);
        _assertDiff(aBefore, token.balanceOf(userA), -1000e18, "userA -1000");
        _assertDiff(bBefore, token.balanceOf(userB), 1000e18, "userB +1000");
        _step("  PASS: userA -1000e18, userB +1000e18");

        _step("[Step 5] verify totalSupply");
        _assertDiff(supplyBefore, token.totalSupply(), 10000e18, "totalSupply diff");
        _step("  PASS: totalSupply +10000e18");

        _logPass();
    }

    // ── QA-E2E-02: 拆股场景 ──
    function test_E2E02() public {
        _logCase("QA-E2E-02", unicode"拆股场景: 乘数变更后 UI 展示翻倍");

        _step("[Step 1] deploy tokenB for isolated multiplier test");
        string memory sym02 = _uniqueSymbol("SP");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.createToken("Split Corp", sym02, "SPT001", admin, new address[](0), new address[](0));
        _step(string.concat("  tokenB symbol: ", sym02));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_MULTIPLIER_ROLE, walletOps);

        _step("[Step 2] mint and distribute 500e18 to userA");
        vm.broadcast(walletOpsPk);
        vault.mint(tokenBAddr, hotWallet, 1000e18);
        vm.broadcast(hotWalletPk);
        tokenB.transfer(userA, 500e18);
        _assertEq(tokenB.balanceOf(userA), 500e18, "userA has 500e18");

        _step("[Step 3] operator schedules 2x multiplier (t+300s)");
        vm.broadcast(walletOpsPk);
        tokenB.setUIMultiplier(2e18, block.timestamp + 600);

        _step("[Step 4] verify pending state");
        _assertEq(tokenB.newUIMultiplier(), 2e18, "newUIMultiplier");
        _assertEq(tokenB.hasPendingMultiplier(), true, "hasPending");
        _step("  PASS: multiplier 2e18 scheduled");

        _step("[Step 5] verify balanceOf unchanged (underlying)");
        _assertEq(tokenB.balanceOf(userA), 500e18, "underlying unchanged");
        _step("  PASS: balanceOf(userA) still 500e18 underlying");

        _step("[Step 6] note: balanceOfUI will be 1000e18 after activation");
        _step("  run test_E2E02_verify after ~5min to confirm activation");

        _logPass();
    }

    function test_E2E02_verify() public {
        _logCase("QA-E2E-02-VERIFY", unicode"拆股激活验证");

        _step("[Step 1] find E2E-02 tokenB (2x multiplier, userB==0, walletOps has OPS)");
        uint256 count = factory.tokenCount();
        address tokenBAddr;
        for (uint256 i = count; i > 0; i--) {
            address[] memory slice = factory.getTokens(i - 1, 1);
            ScaledToken candidate = ScaledToken(slice[0]);
            bool has2x = candidate.uiMultiplier() == 2e18
                || (candidate.hasPendingMultiplier() && candidate.newUIMultiplier() == 2e18);
            if (has2x && candidate.balanceOf(userB) == 0 && candidate.hasRole(TOKEN_MULTIPLIER_ROLE, walletOps)) {
                tokenBAddr = slice[0];
                break;
            }
        }
        require(tokenBAddr != address(0), "E2E-02 tokenB not found");
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        _step(string.concat("  found tokenB: ", vm.toString(tokenBAddr)));

        _step("[Step 2] check if multiplier activated");
        uint256 mult = tokenB.uiMultiplier();
        _assertEq(mult, 2e18, "uiMultiplier activated");
        _step("  PASS: uiMultiplier == 2e18");

        _step("[Step 3] verify balanceOfUI doubled");
        uint256 raw = tokenB.balanceOf(userA);
        uint256 ui = tokenB.balanceOfUI(userA);
        _assertEq(ui, raw * 2, "balanceOfUI == 2x raw");
        _step(string.concat("  raw: ", vm.toString(raw), ", ui: ", vm.toString(ui)));
        _step("  PASS: balanceOfUI == 2x balanceOf");

        _step("[Step 4] cleanup: reset multiplier to 1e18");
        vm.broadcast(walletOpsPk);
        tokenB.setUIMultiplier(1e18, block.timestamp + 600);

        _logPass();
    }

    // ── QA-E2E-03: 乘数变更后转账行为 ──
    function test_E2E03() public {
        _logCase("QA-E2E-03", unicode"乘数变更后转账行为 (pending 阶段)");

        _step("[Step 1] deploy tokenB for isolated multiplier transfer test");
        string memory sym03 = _uniqueSymbol("XF");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.createToken("Xfer Corp", sym03, "XFR001", admin, new address[](0), new address[](0));
        _step(string.concat("  tokenB symbol: ", sym03));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_MULTIPLIER_ROLE, walletOps);

        _step("[Step 2] mint and distribute 500e18 to userA");
        vm.broadcast(walletOpsPk);
        vault.mint(tokenBAddr, hotWallet, 1000e18);
        vm.broadcast(hotWalletPk);
        tokenB.transfer(userA, 500e18);
        _assertEq(tokenB.balanceOf(userA), 500e18, "userA has 500e18");

        _step("[Step 3] schedule 2x multiplier (t+300s)");
        vm.broadcast(walletOpsPk);
        tokenB.setUIMultiplier(2e18, block.timestamp + 600);
        _assertEq(tokenB.hasPendingMultiplier(), true, "hasPending");

        _step("[Step 4] userA transfers 200e18 underlying to userB (pending phase)");
        uint256 aBefore = tokenB.balanceOf(userA);
        uint256 bBefore = tokenB.balanceOf(userB);
        vm.broadcast(userAPk);
        tokenB.transfer(userB, 200e18);
        _assertDiff(aBefore, tokenB.balanceOf(userA), -200e18, "userA diff");
        _assertDiff(bBefore, tokenB.balanceOf(userB), 200e18, "userB diff");
        _step("  PASS: transfer operates on underlying amounts during pending");

        _step("[Step 5] run test_E2E03_verify after ~5min to confirm transfer still uses underlying after activation");

        _logPass();
    }

    function test_E2E03_verify() public {
        _logCase("QA-E2E-03-VERIFY", unicode"乘数激活后转账仍用 underlying");

        _step("[Step 1] find E2E-03 tokenB (last deployed with pending/active 2x multiplier, has userB balance)");
        uint256 count = factory.tokenCount();
        address tokenBAddr;
        for (uint256 i = count; i > 0; i--) {
            address[] memory slice = factory.getTokens(i - 1, 1);
            ScaledToken candidate = ScaledToken(slice[0]);
            if (
                (candidate.uiMultiplier() == 2e18 || (candidate.hasPendingMultiplier() && candidate.newUIMultiplier() == 2e18))
                && candidate.balanceOf(userB) > 0
            ) {
                tokenBAddr = slice[0];
                break;
            }
        }
        require(tokenBAddr != address(0), "E2E-03 tokenB not found");
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        _step(string.concat("  found tokenB: ", vm.toString(tokenBAddr)));

        _step("[Step 2] verify multiplier activated");
        _assertEq(tokenB.uiMultiplier(), 2e18, "uiMultiplier == 2e18");
        _step("  PASS: multiplier activated");

        _step("[Step 3] userA transfers 100e18 underlying to userB (active phase)");
        uint256 aBefore = tokenB.balanceOf(userA);
        uint256 bBefore = tokenB.balanceOf(userB);
        vm.broadcast(userAPk);
        tokenB.transfer(userB, 100e18);
        _assertDiff(aBefore, tokenB.balanceOf(userA), -100e18, "userA diff");
        _assertDiff(bBefore, tokenB.balanceOf(userB), 100e18, "userB diff");
        _step("  PASS: transfer still operates on underlying after multiplier activation");

        _step("[Step 4] verify balanceOfUI reflects multiplier");
        uint256 rawA = tokenB.balanceOf(userA);
        uint256 uiA = tokenB.balanceOfUI(userA);
        _assertEq(uiA, rawA * 2, "balanceOfUI == 2x raw");
        _step(string.concat("  raw: ", vm.toString(rawA), ", ui: ", vm.toString(uiA)));

        _step("[Step 5] cleanup: reset multiplier to 1e18");
        vm.broadcast(walletOpsPk);
        tokenB.setUIMultiplier(1e18, block.timestamp + 600);

        _logPass();
    }

    // ── QA-E2E-04: 热替换 ComplianceRegistry 后黑名单清空 ──
    function test_E2E04() public {
        _logCase("QA-E2E-04", unicode"热替换 ComplianceRegistry 后黑名单清空");

        _step("[Step 1] block userA on current compliance");
        _requireNotPaused();
        _mintAndDistribute(userB, 200e18);
        _blockUser(userA);
        _assertEq(compliance.isBlocked(address(token), userA), true, "userA blocked");

        _step("[Step 2] verify transfer to userA reverts");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            ComplianceRegistry.UserBlocked.selector
        );
        _step("  PASS: reverted UserBlocked()");

        _step("[Step 3] deploy new ComplianceRegistry, grant OPS_ROLE, set on token");
        vm.broadcast(adminPk);
        ComplianceRegistry newCompliance = new ComplianceRegistry(admin);
        vm.broadcast(adminPk);
        newCompliance.grantRole(COMPLIANCE_OPS_ROLE, complianceOps);
        vm.broadcast(adminPk);
        token.updateCompliance(address(newCompliance));
        _step(string.concat("  new compliance: ", vm.toString(address(newCompliance))));

        _step("[Step 4] transfer to userA now succeeds");
        uint256 bBefore = token.balanceOf(userB);
        uint256 aBefore = token.balanceOf(userA);
        vm.broadcast(userBPk);
        token.transfer(userA, 10e18);
        _assertDiff(bBefore, token.balanceOf(userB), -10e18, "userB diff");
        _assertDiff(aBefore, token.balanceOf(userA), 10e18, "userA diff");
        _step("  PASS: transfer succeeded with new compliance");

        _step("[Step 5] cleanup: restore original compliance, unblock userA");
        vm.broadcast(adminPk);
        token.updateCompliance(address(compliance));
        _unblockUser(userA);
        _step("  PASS: original compliance restored, userA unblocked");

        _logPass();
    }

    // ── QA-E2E-05: 热替换 PauseRegistry 后暂停状态清空 ──
    function test_E2E05() public {
        _logCase("QA-E2E-05", unicode"热替换 PauseRegistry 后暂停状态清空");

        _step("[Step 1] mint BEFORE pause, then pause token");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        _requirePaused();

        _step("[Step 2] verify transfer reverts");
        _expectRevertFrom(
            hotWallet,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            PauseGuardUpgradeable.TokenPaused.selector
        );
        _step("  PASS: reverted TokenPaused()");

        _step("[Step 3] deploy new PauseRegistry, grant OPS_ROLE, set on token");
        vm.broadcast(adminPk);
        PauseRegistry newPM = new PauseRegistry(admin);
        vm.broadcast(adminPk);
        newPM.grantRole(PAUSE_MANAGER_PAUSE_ROLE, pauseOps);
        vm.broadcast(adminPk);
        newPM.grantRole(PAUSE_MANAGER_UNPAUSE_ROLE, pauseOps);
        vm.broadcast(adminPk);
        token.updatePauseManager(address(newPM));
        _step(string.concat("  new pauseManager: ", vm.toString(address(newPM))));

        _step("[Step 4] transfer now succeeds (new PM has no pause)");
        uint256 hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(hotWalletPk);
        token.transfer(userA, 10e18);
        _assertDiff(hotBefore, token.balanceOf(hotWallet), -10e18, "hotWallet diff");
        _step("  PASS: transfer succeeded with new PauseRegistry");

        _step("[Step 5] cleanup: restore original PauseRegistry, unpause");
        vm.broadcast(adminPk);
        token.updatePauseManager(address(pauseManager));
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();
        _step("  PASS: original PauseRegistry restored, unpaused");

        _logPass();
    }

    // ── QA-E2E-06: TokenIssuer 发行流程 ──
    function test_E2E06() public {
        _logCase("QA-E2E-06", unicode"TokenIssuer 发行流程: mint->transfer");

        _step("[Step 1] walletOPS mints 1000e18 to hotWallet");
        _requireNotPaused();
        uint256 hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), hotWallet, 1000e18);
        _assertDiff(hotBefore, token.balanceOf(hotWallet), 1000e18, "hotWallet +1000");

        _step("[Step 2] hotWallet transfers 1000e18 to userA");
        uint256 hotAfterMint = token.balanceOf(hotWallet);
        uint256 aBefore = token.balanceOf(userA);
        vm.broadcast(hotWalletPk);
        token.transfer(userA, 1000e18);
        _assertDiff(hotAfterMint, token.balanceOf(hotWallet), -1000e18, "hotWallet -1000");
        _assertDiff(aBefore, token.balanceOf(userA), 1000e18, "userA +1000");
        _step("  PASS: full issuance pipeline complete");

        _logPass();
    }

    // ── QA-E2E-07: 乘数变更期间 allowance 不受影响 ──
    function test_E2E07() public {
        _logCase("QA-E2E-07", unicode"乘数变更期间 allowance 不受影响");

        _step("[Step 1] distribute to userA, userA approves userB 500e18");
        _requireNotPaused();
        _mintAndDistribute(userA, 1000e18);
        vm.broadcast(userAPk);
        token.approve(userB, 500e18);
        _assertEq(token.allowance(userA, userB), 500e18, "allowance set");

        _step("[Step 2] operator schedules 2x multiplier (t+300s)");
        vm.broadcast(walletOpsPk);
        token.setUIMultiplier(2e18, block.timestamp + 600);
        _assertEq(token.newUIMultiplier(), 2e18, "pending 2e18");

        _step("[Step 3] verify allowance unchanged (underlying amount)");
        _assertEq(token.allowance(userA, userB), 500e18, "allowance still 500e18");
        _step("  PASS: allowance is underlying, unaffected by UI multiplier");

        _step("[Step 4] cleanup: reset multiplier");
        vm.broadcast(walletOpsPk);
        token.setUIMultiplier(1e18, block.timestamp + 600);

        _logPass();
    }

    // ── QA-E2E-08: 完整角色委派流程 ──
    function test_E2E08() public {
        _logCase("QA-E2E-08", unicode"完整角色委派流程");

        _step("[Step 1] deploy tokenB for isolated test");
        string memory sym08 = _uniqueSymbol("E8");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.createToken("E2E Corp", sym08, "E2E001", admin, new address[](0), new address[](0));
        _step(string.concat("  tokenB symbol: ", sym08));
        ScaledToken tokenB = ScaledToken(tokenBAddr);

        _step("[Step 2] admin grants roles");
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_MULTIPLIER_ROLE, walletOps);
        _step("  ISSUER_ROLE + OPS_ROLE granted");

        _step("[Step 3] walletOPS mints via wallet to hotWallet");
        vm.broadcast(walletOpsPk);
        vault.mint(tokenBAddr, hotWallet, 1000e18);
        _assertEq(tokenB.balanceOf(hotWallet), 1000e18, "hotWallet balance");
        _step("  PASS: mint via wallet succeeded");

        _step("[Step 4] operator schedules multiplier on tokenB");
        vm.broadcast(walletOpsPk);
        tokenB.setUIMultiplier(2e18, block.timestamp + 3600);
        _assertEq(tokenB.newUIMultiplier(), 2e18, "pending 2e18");
        _step("  PASS: multiplier scheduled");

        _step("[Step 5] complianceOPS manages blocklist");
        address[] memory a = new address[](1);
        a[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.blockUsers(tokenBAddr, a);
        _assertEq(compliance.isBlocked(tokenBAddr, userA), true, "userA blocked on tokenB");
        vm.broadcast(complianceOpsPk);
        compliance.unblockUsers(tokenBAddr, a);
        _step("  PASS: blocklist managed");

        _step("[Step 6] pauseOPS pause/unpause");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(tokenBAddr);
        _assertEq(pauseManager.isTokenPaused(tokenBAddr), true, "tokenB paused");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(tokenBAddr);
        _step("  PASS: pause/unpause succeeded");

        _logPass();
    }

    // ── QA-E2E-09: 制裁冻结资产 ──
    function test_E2E09() public {
        _logCase("QA-E2E-09", unicode"制裁冻结资产");

        _step("[Step 1] distribute to userA, userA approves userB");
        _requireNotPaused();
        _mintAndDistribute(userA, 500e18);
        vm.broadcast(userAPk);
        token.approve(userB, 200e18);

        _step("[Step 2] record balance, sanction userA");
        uint256 aBalBefore = token.balanceOf(userA);
        _sanctionUser(userA);

        _step("[Step 3] userA tries transfer");
        _expectRevertFrom(
            userA,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userB, 100e18),
            ComplianceRegistry.UserSanctioned.selector
        );
        _step("  PASS: transfer reverted UserSanctioned()");

        _step("[Step 4] userB tries transferFrom");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transferFrom.selector, userA, userB, 100e18),
            ComplianceRegistry.UserSanctioned.selector
        );
        _step("  PASS: transferFrom reverted UserSanctioned()");

        _step("[Step 5] balance unchanged");
        _assertEq(token.balanceOf(userA), aBalBefore, "userA balance unchanged");

        _step("[Step 6] cleanup: unsanction");
        _unsanctionUser(userA);

        _logPass();
    }

    // ── QA-E2E-10: 制裁解除后资产恢复可用 ──
    function test_E2E10() public {
        _logCase("QA-E2E-10", unicode"制裁解除后资产恢复可用");

        _step("[Step 1] distribute to userA, sanction then unsanction");
        _requireNotPaused();
        _mintAndDistribute(userA, 500e18);
        _sanctionUser(userA);
        _unsanctionUser(userA);

        _step("[Step 2] userA transfers to userB");
        uint256 aBefore = token.balanceOf(userA);
        vm.broadcast(userAPk);
        token.transfer(userB, 100e18);
        _assertDiff(aBefore, token.balanceOf(userA), -100e18, "userA diff");
        _step("  PASS: transfer succeeded after unsanction");

        _logPass();
    }

    // ── QA-E2E-11: 暂停+黑名单叠加 ──
    function test_E2E11() public {
        _logCase("QA-E2E-11", unicode"暂停+黑名单叠加: 解暂停仍被黑名单阻断");

        _step("[Step 1] distribute to userB, block userA, pause token");
        _requireNotPaused();
        _mintAndDistribute(userB, 200e18);
        _blockUser(userA);
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));

        _step("[Step 2] unpause only");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();

        _step("[Step 3] userB tries transfer to userA (still blocked)");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            ComplianceRegistry.UserBlocked.selector
        );
        _step("  PASS: reverted UserBlocked() (unpause alone not enough)");

        _step("[Step 4] cleanup: unblock userA");
        _unblockUser(userA);

        _logPass();
    }

    // ── QA-E2E-12: 暂停+黑名单叠加(反向解除) ──
    function test_E2E12() public {
        _logCase("QA-E2E-12", unicode"暂停+黑名单叠加(反向): 解黑名单仍被暂停阻断");

        _step("[Step 1] distribute to userB, block userA, pause token");
        _requireNotPaused();
        _mintAndDistribute(userB, 200e18);
        _blockUser(userA);
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));

        _step("[Step 2] unblock userA only (don't unpause)");
        _unblockUser(userA);

        _step("[Step 3] userB tries transfer (still paused)");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            PauseGuardUpgradeable.TokenPaused.selector
        );
        _step("  PASS: reverted TokenPaused() (unblock alone not enough)");

        _step("[Step 4] cleanup: unpause");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();

        _logPass();
    }

    // ── QA-E2E-13: ISSUER_ROLE 撤销后已铸代币不受影响 ──
    function test_E2E13() public {
        _logCase("QA-E2E-13", unicode"ISSUER_ROLE 撤销后已铸代币不受影响");

        _step("[Step 1] deploy tokenB, grant ISSUER, mint, distribute");
        string memory sym13 = _uniqueSymbol("RV");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.createToken("Rev2 Corp", sym13, "RV2001", admin, new address[](0), new address[](0));
        _step(string.concat("  tokenB symbol: ", sym13));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        vm.broadcast(walletOpsPk);
        vault.mint(tokenBAddr, hotWallet, 1000e18);
        _assertEq(tokenB.balanceOf(hotWallet), 1000e18, "hotWallet minted 1000e18");
        vm.broadcast(hotWalletPk);
        tokenB.transfer(userA, 500e18);
        _assertEq(tokenB.balanceOf(userA), 500e18, "userA received 500e18");
        _assertEq(tokenB.balanceOf(hotWallet), 500e18, "hotWallet remaining 500e18");

        _step("[Step 2] revoke ISSUER_ROLE from wallet");
        vm.broadcast(adminPk);
        tokenB.revokeRole(ISSUER_ROLE, address(vault));
        _assertEq(tokenB.hasRole(ISSUER_ROLE, address(vault)), false, "ISSUER revoked");

        _step("[Step 3] new mint fails (ISSUER_ROLE revoked -> UnauthorizedRole)");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(TokenIssuer.mint.selector, tokenBAddr, hotWallet, 100e18),
            ScaledToken.UnauthorizedRole.selector
        );
        _step("  PASS: mint reverted UnauthorizedRole()");

        _step("[Step 4] existing balances unaffected, transfer still works");
        _assertEq(tokenB.balanceOf(hotWallet), 500e18, "hotWallet balance intact");
        _assertEq(tokenB.balanceOf(userA), 500e18, "userA balance intact");
        uint256 hotBefore = tokenB.balanceOf(hotWallet);
        vm.broadcast(hotWalletPk);
        tokenB.transfer(userB, 100e18);
        _assertDiff(hotBefore, tokenB.balanceOf(hotWallet), -100e18, "transfer works");
        _step("  PASS: existing tokens unaffected, transfer succeeds");

        _logPass();
    }

    // ── QA-E2E-14: 调度乘数后撤销 operator ──
    function test_E2E14() public {
        _logCase("QA-E2E-14", unicode"调度乘数后撤销 operator - 已调度变更仍生效");

        _step("[Step 1] deploy tokenB, grant roles");
        string memory sym14 = _uniqueSymbol("SC");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.createToken("Sched Corp", sym14, "SCH001", admin, new address[](0), new address[](0));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        _step(string.concat("  tokenB symbol: ", sym14));
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_MULTIPLIER_ROLE, walletOps);

        _step("[Step 2] mint and distribute 500e18 to userA");
        vm.broadcast(walletOpsPk);
        vault.mint(tokenBAddr, hotWallet, 1000e18);
        _assertEq(tokenB.balanceOf(hotWallet), 1000e18, "hotWallet minted");
        vm.broadcast(hotWalletPk);
        tokenB.transfer(userA, 500e18);
        _assertEq(tokenB.balanceOf(userA), 500e18, "userA received 500e18");

        _step("[Step 3] walletOps schedules 2x multiplier (t+300s)");
        vm.broadcast(walletOpsPk);
        tokenB.setUIMultiplier(2e18, block.timestamp + 600);
        _assertEq(tokenB.newUIMultiplier(), 2e18, "pending 2e18");

        _step("[Step 4] admin revokes OPS_ROLE from walletOps");
        vm.broadcast(adminPk);
        tokenB.revokeRole(TOKEN_MULTIPLIER_ROLE, walletOps);
        _assertEq(tokenB.hasRole(TOKEN_MULTIPLIER_ROLE, walletOps), false, "OPS revoked");

        _step("[Step 5] scheduled change is still pending (cannot be cancelled)");
        _assertEq(tokenB.newUIMultiplier(), 2e18, "still pending 2e18");
        _assertEq(tokenB.hasPendingMultiplier(), true, "still has pending");
        _step("  PASS: scheduled multiplier persists after operator revocation");
        _step("  note: run test_E2E14_verify after ~5min to confirm activation");

        _logPass();
    }

    function test_E2E14_verify() public {
        _logCase("QA-E2E-14-VERIFY", unicode"调度乘数激活验证(需在 E2E14 后执行)");

        _step("[Step 1] find E2E-14 tokenB (2x multiplier, walletOps lacks OPS_ROLE)");
        uint256 count = factory.tokenCount();
        address tokenBAddr;
        for (uint256 i = count; i > 0; i--) {
            address[] memory slice = factory.getTokens(i - 1, 1);
            ScaledToken candidate = ScaledToken(slice[0]);
            bool has2x = candidate.uiMultiplier() == 2e18
                || (candidate.hasPendingMultiplier() && candidate.newUIMultiplier() == 2e18);
            if (has2x && !candidate.hasRole(TOKEN_MULTIPLIER_ROLE, walletOps)) {
                tokenBAddr = slice[0];
                break;
            }
        }
        require(tokenBAddr != address(0), "E2E-14 tokenB not found");
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        _step(string.concat("  found tokenB: ", vm.toString(tokenBAddr)));

        _step("[Step 2] verify multiplier activated despite operator revocation");
        uint256 mult = tokenB.uiMultiplier();
        _assertEq(mult, 2e18, "uiMultiplier == 2e18");
        _step("  PASS: multiplier activated to 2e18 even after operator was revoked");

        _step("[Step 3] verify balanceOfUI doubled");
        uint256 raw = tokenB.balanceOf(userA);
        uint256 ui = tokenB.balanceOfUI(userA);
        _assertEq(ui, raw * 2, "balanceOfUI == 2x raw");
        _step(string.concat("  raw: ", vm.toString(raw), ", ui: ", vm.toString(ui)));
        _step("  PASS: balanceOfUI == 2x balanceOf");

        _step("[Step 4] cleanup: re-grant OPS_ROLE, reset multiplier to 1e18");
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_MULTIPLIER_ROLE, walletOps);
        vm.broadcast(walletOpsPk);
        tokenB.setUIMultiplier(1e18, block.timestamp + 600);
        vm.broadcast(adminPk);
        tokenB.revokeRole(TOKEN_MULTIPLIER_ROLE, walletOps);

        _logPass();
    }

    // ── QA-E2E-15: 暂停期间 approve 仍可设置 ──
    function test_E2E15() public {
        _logCase("QA-E2E-15", unicode"暂停期间 approve 仍可设置");

        _step("[Step 1] distribute to userA BEFORE pause");
        _requireNotPaused();
        _mintAndDistribute(userA, 500e18);

        _step("[Step 2] pause token");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        _requirePaused();

        _step("[Step 3] userA approves userB during pause");
        vm.broadcast(userAPk);
        token.approve(userB, 500e18);
        _assertEq(token.allowance(userA, userB), 500e18, "allowance set during pause");
        _step("  PASS: approve succeeded during pause");

        _step("[Step 4] unpause, userB transferFrom succeeds");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();

        uint256 aBefore = token.balanceOf(userA);
        uint256 bBefore = token.balanceOf(userB);
        vm.broadcast(userBPk);
        token.transferFrom(userA, userB, 500e18);
        _assertDiff(aBefore, token.balanceOf(userA), -500e18, "userA diff");
        _assertDiff(bBefore, token.balanceOf(userB), 500e18, "userB diff");
        _step("  PASS: transferFrom succeeded after unpause");

        _logPass();
    }

    // ── QA-E2E-16: 黑名单+allowance 交叉 ──
    function test_E2E16() public {
        _logCase("QA-E2E-16", unicode"黑名单+allowance 交叉: 被拉黑代扣方无法执行");

        _step("[Step 1] distribute to userA, userA approves userB 300e18");
        _requireNotPaused();
        _mintAndDistribute(userA, 500e18);
        vm.broadcast(userAPk);
        token.approve(userB, 300e18);

        _step("[Step 2] block userB (the spender)");
        _blockUser(userB);

        _step("[Step 3] userB tries transferFrom(userA, hotWallet, 100e18)");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transferFrom.selector, userA, hotWallet, 100e18),
            ComplianceRegistry.UserBlocked.selector
        );
        _step("  PASS: reverted UserBlocked() on spender");

        _step("[Step 4] cleanup: unblock userB");
        _unblockUser(userB);

        _logPass();
    }

    // ── QA-E2E-17: TokenIssuer 多热钱包并发分发 ──
    function test_E2E17() public {
        _logCase("QA-E2E-17", unicode"TokenIssuer 多热钱包并发分发");

        _step("[Step 1] precondition: hotWallet is registered");
        _requireNotPaused();
        _assertEq(vault.isApprovedRecipient(hotWallet), true, "hotWallet registered");

        _step("[Step 2] add userA as second hotWallet");
        bool wasHot = vault.isApprovedRecipient(userA);
        if (!wasHot) {
            vm.broadcast(adminPk);
            vault.addApprovedRecipient(userA);
        }
        _assertEq(vault.isApprovedRecipient(userA), true, "userA is hot");

        _step("[Step 3] mint to both hot wallets");
        uint256 hotBefore = token.balanceOf(hotWallet);
        uint256 aBefore = token.balanceOf(userA);
        uint256 supplyBefore = token.totalSupply();
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), hotWallet, 1000e18);
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), userA, 2000e18);

        _step("[Step 4] verify");
        _assertDiff(hotBefore, token.balanceOf(hotWallet), 1000e18, "hotWallet diff");
        _assertDiff(aBefore, token.balanceOf(userA), 2000e18, "userA diff");
        _assertDiff(supplyBefore, token.totalSupply(), 3000e18, "supply diff");
        _step("  PASS: multi-hotWallet mint succeeded");

        _step("[Step 5] cleanup: remove userA from hotWallets");
        if (!wasHot) {
            vm.broadcast(adminPk);
            vault.removeApprovedRecipient(userA);
        }

        _logPass();
    }

    // ── QA-E2E-18: 制裁 epoch 重置不影响黑名单 ──
    function test_E2E18() public {
        _logCase("QA-E2E-18", unicode"制裁 epoch 重置不影响黑名单");

        _step("[Step 1] sanction + block userA");
        _sanctionUser(userA);
        _blockUser(userA);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");
        _assertEq(compliance.isBlocked(address(token), userA), true, "userA blocked");

        _step("[Step 2] reset sanctions");
        vm.broadcast(complianceOpsPk);
        compliance.clearSanctions();
        _assertEq(compliance.isSanctioned(userA), false, "sanction cleared");
        _assertEq(compliance.isBlocked(address(token), userA), true, "blocklist intact");
        _step("  PASS: sanction reset, blocklist unaffected");

        _step("[Step 3] cleanup: unblock userA");
        _unblockUser(userA);

        _logPass();
    }

    // ── QA-E2E-19: TokenIssuer 被拉黑 ──
    function test_E2E19() public {
        _logCase("QA-E2E-19", unicode"TokenIssuer 被拉黑 -> 所有操作失败");

        _step("[Step 1] block TokenIssuer address");
        _requireNotPaused();
        address[] memory a = new address[](1);
        a[0] = address(vault);
        vm.broadcast(complianceOpsPk);
        compliance.blockUsers(address(token), a);
        _assertEq(compliance.isBlocked(address(token), address(vault)), true, "wallet blocked");

        _step("[Step 2] walletOps tries mint - wallet is blocked so token.mint reverts UserBlocked");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(TokenIssuer.mint.selector, address(token), hotWallet, 100e18),
            ComplianceRegistry.UserBlocked.selector
        );
        _step("  PASS: mint reverted UserBlocked()");

        _step("[Step 3] cleanup: unblock TokenIssuer");
        vm.broadcast(complianceOpsPk);
        compliance.unblockUsers(address(token), a);
        _assertEq(compliance.isBlocked(address(token), address(vault)), false, "wallet unblocked");
        _step("  PASS: wallet unblocked");

        _logPass();
    }

    // ── QA-E2E-20: 热钱包被拉黑 ──
    function test_E2E20() public {
        _logCase("QA-E2E-20", unicode"热钱包被拉黑 -> 该热钱包不可用, 其他不受影响");

        _step("[Step 1] add userA as second hotWallet");
        _requireNotPaused();
        bool wasHot = vault.isApprovedRecipient(userA);
        if (!wasHot) {
            vm.broadcast(adminPk);
            vault.addApprovedRecipient(userA);
        }

        _step("[Step 2] block hotWallet (primary)");
        _blockUser(hotWallet);

        _step("[Step 3] mint to blocked hotWallet fails (safeTransfer -> UserBlocked)");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(TokenIssuer.mint.selector, address(token), hotWallet, 100e18),
            ComplianceRegistry.UserBlocked.selector
        );
        _step("  PASS: mint to blocked hotWallet reverted UserBlocked()");

        _step("[Step 4] mint to userA (unblocked hotWallet) succeeds");
        uint256 aBefore = token.balanceOf(userA);
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), userA, 100e18);
        _assertDiff(aBefore, token.balanceOf(userA), 100e18, "userA diff");
        _step("  PASS: mint to unblocked hotWallet succeeded");

        _step("[Step 5] cleanup: unblock hotWallet, remove userA from hotWallets");
        _unblockUser(hotWallet);
        if (!wasHot) {
            vm.broadcast(adminPk);
            vault.removeApprovedRecipient(userA);
        }

        _logPass();
    }

    // ── QA-E2E-21: 代币赎回完整链路 ──
    function test_E2E21() public {
        _logCase("QA-E2E-21", unicode"代币赎回完整链路");

        _step("[Step 1] mint and distribute to userA");
        _requireNotPaused();
        _mintAndDistribute(userA, 2000e18);

        _step("[Step 2] hotWallet approves wallet for burn");
        vm.broadcast(hotWalletPk);
        token.approve(address(vault), type(uint256).max);

        _step("[Step 3] userA returns 1000e18 to hotWallet");
        uint256 aBefore = token.balanceOf(userA);
        vm.broadcast(userAPk);
        token.transfer(hotWallet, 1000e18);
        _assertDiff(aBefore, token.balanceOf(userA), -1000e18, "userA -1000");

        _step("[Step 4] walletOPS burns 1000e18 from hotWallet");
        uint256 supplyBefore = token.totalSupply();
        vm.broadcast(walletOpsPk);
        vault.burn(address(token), hotWallet, 1000e18);
        _assertDiff(supplyBefore, token.totalSupply(), -1000e18, "supply -1000");
        _step("  PASS: redemption complete, totalSupply -1000e18");

        _logPass();
    }

    // ── QA-E2E-22: 热钱包轮换 ──
    function test_E2E22() public {
        _logCase("QA-E2E-22", unicode"热钱包轮换");

        _step("[Step 1] add userB as new hotWallet");
        _requireNotPaused();
        bool userBWasHot = vault.isApprovedRecipient(userB);
        if (!userBWasHot) {
            vm.broadcast(adminPk);
            vault.addApprovedRecipient(userB);
        }
        _assertEq(vault.isApprovedRecipient(userB), true, "userB is hot");

        _step("[Step 2] mint to new hotWallet (userB)");
        uint256 bBefore = token.balanceOf(userB);
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), userB, 500e18);
        _assertDiff(bBefore, token.balanceOf(userB), 500e18, "userB diff");
        _step("  PASS: mint to new hotWallet succeeded");

        _step("[Step 3] cleanup: remove userB from hotWallets");
        if (!userBWasHot) {
            vm.broadcast(adminPk);
            vault.removeApprovedRecipient(userB);
            _assertEq(vault.isApprovedRecipient(userB), false, "userB removed");
        }
        _step("  PASS: hot wallet rotation complete");

        _logPass();
    }

    // ── QA-E2E-23: 乘数调度->等待->激活验证 ──
    function test_E2E23() public {
        _logCase("QA-E2E-23", unicode"乘数调度->等待->激活验证");

        _step("[Step 1] deploy tokenB for isolated multiplier test");
        string memory sym23 = _uniqueSymbol("ML");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.createToken("Mul Corp", sym23, "MUL001", admin, new address[](0), new address[](0));
        _step(string.concat("  tokenB symbol: ", sym23));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_MULTIPLIER_ROLE, walletOps);

        _step("[Step 2] mint and distribute 500e18 to userA");
        vm.broadcast(walletOpsPk);
        vault.mint(tokenBAddr, hotWallet, 1000e18);
        vm.broadcast(hotWalletPk);
        tokenB.transfer(userA, 500e18);

        _step("[Step 3] verify pre-activation state");
        _assertEq(tokenB.uiMultiplier(), 1e18, "initial multiplier 1e18");
        _assertEq(tokenB.balanceOfUI(userA), 500e18, "balanceOfUI == 500e18");
        _step("  PASS: before activation, balanceOfUI == balanceOf");

        _step("[Step 4] operator schedules 2x multiplier (t+300s)");
        uint256 effectiveAt = block.timestamp + 600;
        vm.broadcast(walletOpsPk);
        tokenB.setUIMultiplier(2e18, effectiveAt);
        _assertEq(tokenB.hasPendingMultiplier(), true, "hasPending");
        _assertEq(tokenB.uiMultiplier(), 1e18, "not yet activated");
        _step(string.concat("  scheduled at: ", vm.toString(effectiveAt)));
        _step("  PASS: multiplier scheduled but not yet active");

        _step("[Step 5] to verify activation, run after ~5min:");
        _step(string.concat("  tokenB address: ", vm.toString(tokenBAddr)));
        _step("  run test_E2E23_verify after multiplier activates");

        _logPass();
    }

    function test_E2E23_verify() public {
        _logCase("QA-E2E-23-VERIFY", unicode"乘数激活验证");

        _step("[Step 1] find E2E-23 tokenB (last deployed with pending/active 2x multiplier)");
        uint256 count = factory.tokenCount();
        address tokenBAddr;
        for (uint256 i = count; i > 0; i--) {
            address[] memory slice = factory.getTokens(i - 1, 1);
            ScaledToken candidate = ScaledToken(slice[0]);
            if (candidate.uiMultiplier() == 2e18 || (candidate.hasPendingMultiplier() && candidate.newUIMultiplier() == 2e18)) {
                tokenBAddr = slice[0];
                break;
            }
        }
        require(tokenBAddr != address(0), "E2E-23 tokenB not found");
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        _step(string.concat("  found tokenB: ", vm.toString(tokenBAddr)));

        _step("[Step 2] verify multiplier activated");
        uint256 mult = tokenB.uiMultiplier();
        _assertEq(mult, 2e18, "uiMultiplier == 2e18");
        _step("  PASS: multiplier activated to 2e18");

        _step("[Step 3] verify balanceOfUI doubled");
        uint256 raw = tokenB.balanceOf(userA);
        uint256 ui = tokenB.balanceOfUI(userA);
        _assertEq(ui, raw * 2, "balanceOfUI == 2x raw");
        _step(string.concat("  raw: ", vm.toString(raw), ", ui: ", vm.toString(ui)));
        _step("  PASS: balanceOfUI == 2x balanceOf");

        _step("[Step 4] cleanup: reset multiplier to 1e18");
        vm.broadcast(walletOpsPk);
        tokenB.setUIMultiplier(1e18, block.timestamp + 600);

        _logPass();
    }
}
