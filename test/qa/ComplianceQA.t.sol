// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";

contract ComplianceQA is BaseQA {
    string constant MODULE = unicode"ComplianceRegistry 独立";

    // ── CL-INIT-01 ──
    function test_CLINIT01_ConstructorSetsAdmin() public {
        _logCase("CL-INIT-01", unicode"构造设置 admin");

        _step("[Step 1] deploy new ComplianceRegistry(admin)");
        ComplianceRegistry c = new ComplianceRegistry(admin);
        assertTrue(c.hasRole(c.DEFAULT_ADMIN_ROLE(), admin));
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── CL-INIT-02 ──
    function test_CLINIT02_ZeroAddressReverts() public {
        _logCase("CL-INIT-02", unicode"零地址回滚");

        _step("[Step 1] deploy ComplianceRegistry(address(0))");
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(address(0));
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── CL-INIT-03 ──
    function test_CLINIT03_OpsAdminRole() public {
        _logCase("CL-INIT-03", unicode"OPS admin 角色");

        _step("[Step 1] getRoleAdmin(OPS_ROLE)");
        assertEq(compliance.getRoleAdmin(COMPLIANCE_OPS_ROLE), compliance.DEFAULT_ADMIN_ROLE());
        _step("  PASS: OPS_ROLE admin is DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── CL-BLK-01 ──
    function test_CLBLK01_OpsCanManageBlocklist() public {
        _logCase("CL-BLK-01", unicode"OPS 可操作黑名单");

        _step("[Step 1] complianceOps adds userA to blocklist");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.blockUsers(address(token), addrs);
        assertTrue(compliance.isBlocked(address(token), userA));
        _step("  PASS: userA blocked");

        _logPass();
    }

    // ── CL-BLK-02 ──
    function test_CLBLK02_AdminCannotManageBlocklist() public {
        _logCase("CL-BLK-02", unicode"admin 不能操作黑名单");

        _step("[Step 1] admin tries blockUsers");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.MissingOpsRole.selector);
        compliance.blockUsers(address(token), addrs);
        _step("  PASS: reverted MissingOpsRole()");

        _logPass();
    }

    // ── CL-BLK-03 ──
    function test_CLBLK03_StrangerCannotManageBlocklist() public {
        _logCase("CL-BLK-03", unicode"普通用户不能操作");

        _step("[Step 1] stranger tries blockUsers");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(stranger);
        vm.expectRevert(ComplianceRegistry.MissingOpsRole.selector);
        compliance.blockUsers(address(token), addrs);
        _step("  PASS: reverted MissingOpsRole()");

        _logPass();
    }

    // ── CL-BLK-04 ──
    function test_CLBLK04_EmptyArrayAddReverts() public {
        _logCase("CL-BLK-04", unicode"空数组（添加）");

        _step("[Step 1] blockUsers with empty array");
        address[] memory empty = new address[](0);
        vm.prank(complianceOps);
        vm.expectRevert(ComplianceRegistry.EmptyAddressList.selector);
        compliance.blockUsers(address(token), empty);
        _step("  PASS: reverted EmptyAddressList()");

        _logPass();
    }

    // ── CL-BLK-05 ──
    function test_CLBLK05_EmptyArrayRemoveReverts() public {
        _logCase("CL-BLK-05", unicode"空数组（移除）");

        _step("[Step 1] unblockUsers with empty array");
        address[] memory empty = new address[](0);
        vm.prank(complianceOps);
        vm.expectRevert(ComplianceRegistry.EmptyAddressList.selector);
        compliance.unblockUsers(address(token), empty);
        _step("  PASS: reverted EmptyAddressList()");

        _logPass();
    }

    // ── CL-BLK-06 ──
    function test_CLBLK06_ZeroAddressAddReverts() public {
        _logCase("CL-BLK-06", unicode"零地址（添加）");

        _step("[Step 1] blockUsers with [address(0)]");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        vm.prank(complianceOps);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        compliance.blockUsers(address(token), addrs);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── CL-BLK-07 ──
    function test_CLBLK07_ZeroAddressRemoveReverts() public {
        _logCase("CL-BLK-07", unicode"零地址（移除）");

        _step("[Step 1] unblockUsers with [address(0)]");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        vm.prank(complianceOps);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        compliance.unblockUsers(address(token), addrs);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── CL-BLK-08 ──
    function test_CLBLK08_BatchBlocklist() public {
        _logCase("CL-BLK-08", unicode"批量多地址");

        _step("[Step 1] blockUsers([userA, userB, stranger])");
        address[] memory addrs = new address[](3);
        addrs[0] = userA;
        addrs[1] = userB;
        addrs[2] = stranger;
        vm.prank(complianceOps);
        compliance.blockUsers(address(token), addrs);

        assertTrue(compliance.isBlocked(address(token), userA));
        assertTrue(compliance.isBlocked(address(token), userB));
        assertTrue(compliance.isBlocked(address(token), stranger));
        _step("  PASS: all three blocked");

        _logPass();
    }

    // ── CL-BLK-09 ──
    function test_CLBLK09_DuplicateAddIdempotent() public {
        _logCase("CL-BLK-09", unicode"重复添加幂等");

        _step("[Step 1] block userA twice");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.startPrank(complianceOps);
        compliance.blockUsers(address(token), addrs);
        compliance.blockUsers(address(token), addrs);
        vm.stopPrank();
        assertTrue(compliance.isBlocked(address(token), userA));
        _step("  PASS: no revert on duplicate add");

        _logPass();
    }

    // ── CL-BLK-10 ──
    function test_CLBLK10_RemoveUnblockedIdempotent() public {
        _logCase("CL-BLK-10", unicode"移除未拉黑幂等");

        _step("[Step 1] unblockUsers for non-blocked userA");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.unblockUsers(address(token), addrs);
        assertFalse(compliance.isBlocked(address(token), userA));
        _step("  PASS: no revert on removing non-blocked address");

        _logPass();
    }

    // ── CL-SAN-01 ──
    function test_CLSAN01_OpsCanManageSanctions() public {
        _logCase("CL-SAN-01", unicode"OPS 可操作制裁");

        _step("[Step 1] complianceOps adds userA to sanctions");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.sanctionUsers(addrs);
        assertTrue(compliance.isSanctioned(userA));
        _step("  PASS: userA sanctioned");

        _logPass();
    }

    // ── CL-SAN-02 ──
    function test_CLSAN02_AdminCannotManageSanctions() public {
        _logCase("CL-SAN-02", unicode"admin 不能操作制裁");

        _step("[Step 1] admin tries sanctionUsers");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.MissingOpsRole.selector);
        compliance.sanctionUsers(addrs);
        _step("  PASS: reverted MissingOpsRole()");

        _logPass();
    }

    // ── CL-SAN-03 ──
    function test_CLSAN03_StrangerCannotManageSanctions() public {
        _logCase("CL-SAN-03", unicode"普通用户不能操作");

        _step("[Step 1] stranger tries sanctionUsers");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(stranger);
        vm.expectRevert(ComplianceRegistry.MissingOpsRole.selector);
        compliance.sanctionUsers(addrs);
        _step("  PASS: reverted MissingOpsRole()");

        _logPass();
    }

    // ── CL-SAN-04 ──
    function test_CLSAN04_EmptyArrayReverts() public {
        _logCase("CL-SAN-04", unicode"空数组");

        _step("[Step 1] sanctionUsers([])");
        address[] memory empty = new address[](0);
        vm.prank(complianceOps);
        vm.expectRevert(ComplianceRegistry.EmptyAddressList.selector);
        compliance.sanctionUsers(empty);
        _step("  PASS: reverted EmptyAddressList()");

        _logPass();
    }

    // ── CL-SAN-05 ──
    function test_CLSAN05_ZeroAddressReverts() public {
        _logCase("CL-SAN-05", unicode"零地址");

        _step("[Step 1] sanctionUsers([address(0)])");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        vm.prank(complianceOps);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        compliance.sanctionUsers(addrs);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── CL-SAN-06 ──
    function test_CLSAN06_DuplicateDedup() public {
        _logCase("CL-SAN-06", unicode"重复去重");

        _step("[Step 1] sanctionUsers([userA, userA])");
        address[] memory addrs = new address[](2);
        addrs[0] = userA;
        addrs[1] = userA;
        vm.prank(complianceOps);
        vm.recordLogs();
        compliance.sanctionUsers(addrs);

        assertTrue(compliance.isSanctioned(userA));
        _step("  PASS: userA sanctioned, duplicate silently deduped");

        _logPass();
    }

    // ── CL-SAN-07 ──
    function test_CLSAN07_RemoveUnsanctionedSilent() public {
        _logCase("CL-SAN-07", unicode"移除未制裁静默");

        _step("[Step 1] unsanctionUsers([userA]) when not sanctioned");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.unsanctionUsers(addrs);
        assertFalse(compliance.isSanctioned(userA));
        _step("  PASS: no revert, event emitted with empty effective list");

        _logPass();
    }

    // ── CL-SAN-08 ──
    function test_CLSAN08_SetDedup() public {
        _logCase("CL-SAN-08", unicode"set 去重");

        _step("[Step 1] replaceSanctions([userA, userA])");
        address[] memory addrs = new address[](2);
        addrs[0] = userA;
        addrs[1] = userA;
        vm.prank(complianceOps);
        compliance.replaceSanctions(addrs);
        assertTrue(compliance.isSanctioned(userA));
        _step("  PASS: no revert, duplicate silently deduped");

        _logPass();
    }

    // ── CL-SAN-09 ──
    function test_CLSAN09_ClearSanctions() public {
        _logCase("CL-SAN-09", unicode"clearSanctions 清除全部");

        _step("[Step 1] sanction userA, then clearSanctions()");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.sanctionUsers(addrs);
        assertTrue(compliance.isSanctioned(userA));

        vm.prank(complianceOps);
        compliance.clearSanctions();
        assertFalse(compliance.isSanctioned(userA));
        _step("  PASS: all sanctions cleared via clearSanctions()");

        _logPass();
    }

    // ── CL-SAN-10 ──
    function test_CLSAN10_SetZeroAddressReverts() public {
        _logCase("CL-SAN-10", unicode"set 零地址回滚");

        _step("[Step 1] replaceSanctions([address(0)])");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        vm.prank(complianceOps);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        compliance.replaceSanctions(addrs);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }
}
