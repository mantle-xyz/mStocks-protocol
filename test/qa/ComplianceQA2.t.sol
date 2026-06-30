// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";

contract ComplianceQA2 is BaseQA {
    string constant MODULE = unicode"Compliance 补充";

    // ═══════════════════════════════════════════════
    //      removeFromSanctionsList 边界
    // ═══════════════════════════════════════════════

    // ── CL-SAN-11 ──
    function test_CLSAN11_RemoveSanctionsEmptyArrayReverts() public {
        _logCase("CL-SAN-11", unicode"移除制裁空数组回滚");

        _step("[Step 1] removeFromSanctionsList([])");
        address[] memory empty = new address[](0);
        vm.prank(complianceOps);
        vm.expectRevert(Compliance.EmptyAddressesArray.selector);
        compliance.removeFromSanctionsList(empty);
        _step("  PASS: reverted EmptyAddressesArray()");

        _logPass();
    }

    // ── CL-SAN-12 ──
    function test_CLSAN12_RemoveSanctionsZeroAddressReverts() public {
        _logCase("CL-SAN-12", unicode"移除制裁零地址回滚");

        _step("[Step 1] removeFromSanctionsList([address(0)])");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        vm.prank(complianceOps);
        vm.expectRevert(Compliance.ZeroAddress.selector);
        compliance.removeFromSanctionsList(addrs);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      admin 不能操作制裁和黑名单管理
    // ═══════════════════════════════════════════════

    // ── CL-BLK-11 ──
    function test_CLBLK11_AdminCannotRemoveBlocklist() public {
        _logCase("CL-BLK-11", unicode"admin 不能移除黑名单");

        _step("[Step 1] block userA, then admin tries removeFromBlocklist");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);

        vm.prank(admin);
        vm.expectRevert(Compliance.MissingBlocklistRole.selector);
        compliance.removeFromBlocklist(address(token), addrs);
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ── CL-SAN-13 ──
    function test_CLSAN13_AdminCannotRemoveSanctions() public {
        _logCase("CL-SAN-13", unicode"admin 不能移除制裁");

        _step("[Step 1] sanction userA, then admin tries removeFromSanctionsList");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.addToSanctionsList(addrs);

        vm.prank(admin);
        vm.expectRevert(Compliance.MissingBlocklistRole.selector);
        compliance.removeFromSanctionsList(addrs);
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ── CL-SAN-14 ──
    function test_CLSAN14_AdminCannotReset() public {
        _logCase("CL-SAN-14", unicode"admin 不能重置制裁");

        _step("[Step 1] admin tries resetSanctionedAddresses");
        vm.prank(admin);
        vm.expectRevert(Compliance.MissingBlocklistRole.selector);
        compliance.resetSanctionedAddresses();
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ── CL-SAN-15 ──
    function test_CLSAN15_AdminCannotSetSanctions() public {
        _logCase("CL-SAN-15", unicode"admin 不能整体替换制裁");

        _step("[Step 1] admin tries setSanctionedAddresses");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(admin);
        vm.expectRevert(Compliance.MissingBlocklistRole.selector);
        compliance.setSanctionedAddresses(addrs);
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      checkIsCompliant 正向路径
    // ═══════════════════════════════════════════════

    // ── CL-CHK-01 ──
    function test_CLCHK01_CompliantUserDoesNotRevert() public {
        _logCase("CL-CHK-01", unicode"合规用户不回滚");

        _step("[Step 1] checkIsCompliant(token, userA) for non-blocked non-sanctioned user");
        compliance.checkIsCompliant(address(token), userA);
        _step("  PASS: no revert");

        _logPass();
    }

    // ── CL-CHK-02 ──
    function test_CLCHK02_UnblockedAfterRemoval() public {
        _logCase("CL-CHK-02", unicode"移除后 checkIsCompliant 通过");

        _step("[Step 1] block userA, then remove");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.startPrank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);
        compliance.removeFromBlocklist(address(token), addrs);
        vm.stopPrank();

        _step("[Step 2] checkIsCompliant should pass");
        compliance.checkIsCompliant(address(token), userA);
        _step("  PASS: no revert after removal");

        _logPass();
    }

    // ── CL-CHK-03 ──
    function test_CLCHK03_UnsanctionedAfterRemoval() public {
        _logCase("CL-CHK-03", unicode"移除制裁后 checkIsCompliant 通过");

        _step("[Step 1] sanction userA, then remove");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.startPrank(complianceOps);
        compliance.addToSanctionsList(addrs);
        compliance.removeFromSanctionsList(addrs);
        vm.stopPrank();

        _step("[Step 2] checkIsCompliant should pass");
        compliance.checkIsCompliant(address(token), userA);
        _step("  PASS: no revert after removal");

        _logPass();
    }
}
