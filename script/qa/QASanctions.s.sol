// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";

contract QASanctions is BaseQAScript {
    function run() external {
        _loadEnv();

        test_SAN01();
        test_SAN02();
        test_SAN03();
        test_SAN04();
        test_SAN05();
        test_SAN06();
        test_SAN07();
        test_SAN08();
        test_SAN09();
    }

    // ── helpers ──

    function _sanctionUser(address user) internal {
        address[] memory addrs = new address[](1);
        addrs[0] = user;
        vm.broadcast(complianceOpsPk);
        compliance.sanctionUsers(addrs);
    }

    function _unsanctionUser(address user) internal {
        address[] memory addrs = new address[](1);
        addrs[0] = user;
        vm.broadcast(complianceOpsPk);
        compliance.unsanctionUsers(addrs);
    }

    // ── QA-SAN-01: 制裁后发行方转入阻断 ──
    function test_SAN01() public {
        _logCase("QA-SAN-01", unicode"制裁后发行方转入阻断");

        _step("[Step 1] preconditions: mint to hotWallet, ensure userA not sanctioned");
        _requireNotPaused();
        _assertEq(compliance.isSanctioned(userA), false, "userA not sanctioned");
        _mintToHotWallet(100e18);
        _requireBalance(hotWallet, 100e18, "hotWallet");

        _step("[Step 2] complianceOps sanctions userA");
        _sanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");
        _step("  userA is sanctioned");

        _step("[Step 3] hotWallet tries transfer to userA");
        _expectRevertFrom(
            hotWallet,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            ComplianceRegistry.UserSanctioned.selector
        );
        _step("  PASS: reverted UserSanctioned()");

        _step("[Step 4] cleanup: unsanction userA");
        _unsanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), false, "userA unsanctioned");
        _step("  PASS: userA unsanctioned");

        _logPass();
    }

    // ── QA-SAN-02: 制裁后二级市场转入阻断 ──
    function test_SAN02() public {
        _logCase("QA-SAN-02", unicode"制裁后二级市场转入阻断");

        _step("[Step 1] preconditions: distribute to userB, sanction userA");
        _requireNotPaused();
        _mintAndDistribute(userB, 200e18);
        _sanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");

        _step("[Step 2] userB tries transfer to sanctioned userA");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 100e18),
            ComplianceRegistry.UserSanctioned.selector
        );
        _step("  PASS: reverted UserSanctioned()");

        _step("[Step 3] cleanup: unsanction userA");
        _unsanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), false, "userA unsanctioned");
        _step("  PASS: userA unsanctioned");

        _logPass();
    }

    // ── QA-SAN-03: 被制裁地址转出阻断 ──
    function test_SAN03() public {
        _logCase("QA-SAN-03", unicode"被制裁地址转出阻断");

        _step("[Step 1] preconditions: distribute to userA BEFORE sanction");
        _requireNotPaused();
        _mintAndDistribute(userA, 200e18);
        _requireBalance(userA, 10e18, "userA");

        _step("[Step 2] sanction userA");
        _sanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");

        _step("[Step 3] sanctioned userA tries transfer to userB");
        _expectRevertFrom(
            userA,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userB, 10e18),
            ComplianceRegistry.UserSanctioned.selector
        );
        _step("  PASS: reverted UserSanctioned()");

        _step("[Step 4] cleanup: unsanction userA");
        _unsanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), false, "userA unsanctioned");
        _step("  PASS: userA unsanctioned");

        _logPass();
    }

    // ── QA-SAN-04: 解除制裁后恢复 ──
    function test_SAN04() public {
        _logCase("QA-SAN-04", unicode"解除制裁后恢复");

        _step("[Step 1] preconditions: distribute to userB, sanction then unsanction userA");
        _requireNotPaused();
        _mintAndDistribute(userB, 200e18);
        _sanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");
        _unsanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), false, "userA unsanctioned");

        _step("[Step 2] userB transfers to userA (should succeed)");
        uint256 bBefore = token.balanceOf(userB);
        uint256 aBefore = token.balanceOf(userA);
        vm.broadcast(userBPk);
        token.transfer(userA, 50e18);
        _assertDiff(bBefore, token.balanceOf(userB), -50e18, "userB diff");
        _assertDiff(aBefore, token.balanceOf(userA), 50e18, "userA diff");
        _step("  PASS: transfer succeeded after unsanction");

        _logPass();
    }

    // ── QA-SAN-05: epoch 重置清除全部 ──
    function test_SAN05() public {
        _logCase("QA-SAN-05", unicode"epoch 重置清除全部");

        _step("[Step 1] preconditions: sanction both userA and userB");
        _requireNotPaused();
        _sanctionUser(userA);
        _sanctionUser(userB);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");
        _assertEq(compliance.isSanctioned(userB), true, "userB sanctioned");

        _step("[Step 2] complianceOps calls clearSanctions");
        vm.broadcast(complianceOpsPk);
        compliance.clearSanctions();
        _assertEq(compliance.isSanctioned(userA), false, "userA cleared");
        _assertEq(compliance.isSanctioned(userB), false, "userB cleared");
        _step("  PASS: both users cleared by epoch reset");

        _step("[Step 3] verify transfer works after reset");
        _mintAndDistribute(userB, 100e18);
        uint256 bBefore = token.balanceOf(userB);
        uint256 aBefore = token.balanceOf(userA);
        vm.broadcast(userBPk);
        token.transfer(userA, 10e18);
        _assertDiff(bBefore, token.balanceOf(userB), -10e18, "userB diff");
        _assertDiff(aBefore, token.balanceOf(userA), 10e18, "userA diff");
        _step("  PASS: transfer succeeded after reset");

        _logPass();
    }

    // ── QA-SAN-06: 整体替换制裁名单 ──
    function test_SAN06() public {
        _logCase("QA-SAN-06", unicode"整体替换制裁名单");

        _step("[Step 1] preconditions: sanction userA");
        _requireNotPaused();
        _sanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");

        _step("[Step 2] complianceOps calls replaceSanctions([userB]) - replaces list");
        address[] memory newList = new address[](1);
        newList[0] = userB;
        vm.broadcast(complianceOpsPk);
        compliance.replaceSanctions(newList);
        _assertEq(compliance.isSanctioned(userA), false, "userA no longer sanctioned");
        _assertEq(compliance.isSanctioned(userB), true, "userB now sanctioned");
        _step("  PASS: list replaced - userA cleared, userB sanctioned");

        _step("[Step 3] verify userA can receive, userB cannot send");
        _mintAndDistribute(userA, 100e18);
        _step("  PASS: userA transfer succeeded (no longer sanctioned)");

        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            ComplianceRegistry.UserSanctioned.selector
        );
        _step("  PASS: userB reverted UserSanctioned()");

        _step("[Step 4] cleanup: reset sanctions");
        vm.broadcast(complianceOpsPk);
        compliance.clearSanctions();
        _assertEq(compliance.isSanctioned(userB), false, "userB cleared");
        _step("  PASS: sanctions reset");

        _logPass();
    }

    // ── QA-SAN-07: 制裁是全局的(跨 token) ──
    function test_SAN07() public {
        _logCase("QA-SAN-07", unicode"制裁是全局的(跨 token)");

        _step("[Step 1] deploy tokenB via Factory");
        _requireNotPaused();
        vm.broadcast(adminPk);
        address tokenBAddr = factory.createToken("Sanction Corp", "SANB", "SAN001", admin, new address[](0), new address[](0));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        _step(string.concat("  tokenB: ", vm.toString(tokenBAddr)));

        _step("[Step 2] setup tokenB: grant ISSUER_ROLE + mint + distribute to hotWallet");
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        vm.broadcast(walletOpsPk);
        vault.mint(tokenBAddr, hotWallet, 200e18);

        _step("[Step 3] sanction userA (global)");
        _sanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");

        _step("[Step 4] tokenA transfer to userA reverts");
        _mintToHotWallet(100e18);
        _expectRevertFrom(
            hotWallet,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            ComplianceRegistry.UserSanctioned.selector
        );
        _step("  PASS: tokenA reverted UserSanctioned()");

        _step("[Step 5] tokenB transfer to userA also reverts");
        _expectRevertFrom(
            hotWallet,
            tokenBAddr,
            abi.encodeWithSelector(tokenB.transfer.selector, userA, 10e18),
            ComplianceRegistry.UserSanctioned.selector
        );
        _step("  PASS: tokenB reverted UserSanctioned()");

        _step("[Step 6] cleanup: unsanction userA");
        _unsanctionUser(userA);
        _assertEq(compliance.isSanctioned(userA), false, "userA unsanctioned");
        _step("  PASS: userA unsanctioned");

        _logPass();
    }

    // ── QA-SAN-08: admin 不能管理制裁名单 ──
    function test_SAN08() public {
        _logCase("QA-SAN-08", unicode"admin 不能管理制裁名单");

        _step("[Step 1] precondition: admin has DEFAULT_ADMIN_ROLE but NOT OPS_ROLE on compliance");
        _requireRole(address(compliance), DEFAULT_ADMIN_ROLE_HASH, admin, "admin");
        _assertEq(compliance.hasRole(COMPLIANCE_OPS_ROLE, admin), false, "admin no OPS_ROLE");

        _step("[Step 2] admin tries sanctionUsers");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        _expectRevertFrom(
            admin,
            address(compliance),
            abi.encodeWithSelector(compliance.sanctionUsers.selector, addrs),
            ComplianceRegistry.MissingOpsRole.selector
        );
        _step("  PASS: reverted MissingOpsRole()");

        _logPass();
    }

    // ── QA-SAN-09: 普通用户不能管理 ──
    function test_SAN09() public {
        _logCase("QA-SAN-09", unicode"普通用户不能管理");

        _step("[Step 1] precondition: userA has no OPS_ROLE on compliance");
        _assertEq(compliance.hasRole(COMPLIANCE_OPS_ROLE, userA), false, "userA no OPS_ROLE");

        _step("[Step 2] userA tries sanctionUsers");
        address[] memory addrs = new address[](1);
        addrs[0] = userB;
        _expectRevertFrom(
            userA,
            address(compliance),
            abi.encodeWithSelector(compliance.sanctionUsers.selector, addrs),
            ComplianceRegistry.MissingOpsRole.selector
        );
        _step("  PASS: reverted MissingOpsRole()");

        _logPass();
    }
}
