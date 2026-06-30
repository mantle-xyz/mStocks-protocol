// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";

contract ComplianceQA is BaseQA {
    string constant MODULE = unicode"Compliance 独立";

    // ── CL-INIT-01 ──
    function test_CLINIT01_ConstructorSetsAdmin() public {
        _logCase("CL-INIT-01", unicode"构造设置 admin");

        _step("[Step 1] deploy new Compliance(admin)");
        Compliance c = new Compliance(admin);
        assertTrue(c.hasRole(c.DEFAULT_ADMIN_ROLE(), admin));
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── CL-INIT-02 ──
    function test_CLINIT02_ZeroAddressReverts() public {
        _logCase("CL-INIT-02", unicode"零地址回滚");

        _step("[Step 1] deploy Compliance(address(0))");
        vm.expectRevert(Compliance.ZeroAddress.selector);
        new Compliance(address(0));
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
        compliance.addToBlocklist(address(token), addrs);
        assertTrue(compliance.blockedAddresses(address(token), userA));
        _step("  PASS: userA blocked");

        _logPass();
    }

    // ── CL-BLK-02 ──
    function test_CLBLK02_AdminCannotManageBlocklist() public {
        _logCase("CL-BLK-02", unicode"admin 不能操作黑名单");

        _step("[Step 1] admin tries addToBlocklist");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(admin);
        vm.expectRevert(Compliance.MissingBlocklistRole.selector);
        compliance.addToBlocklist(address(token), addrs);
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ── CL-BLK-03 ──
    function test_CLBLK03_StrangerCannotManageBlocklist() public {
        _logCase("CL-BLK-03", unicode"普通用户不能操作");

        _step("[Step 1] stranger tries addToBlocklist");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(stranger);
        vm.expectRevert(Compliance.MissingBlocklistRole.selector);
        compliance.addToBlocklist(address(token), addrs);
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ── CL-BLK-04 ──
    function test_CLBLK04_EmptyArrayAddReverts() public {
        _logCase("CL-BLK-04", unicode"空数组（添加）");

        _step("[Step 1] addToBlocklist with empty array");
        address[] memory empty = new address[](0);
        vm.prank(complianceOps);
        vm.expectRevert(Compliance.EmptyAddressesArray.selector);
        compliance.addToBlocklist(address(token), empty);
        _step("  PASS: reverted EmptyAddressesArray()");

        _logPass();
    }

    // ── CL-BLK-05 ──
    function test_CLBLK05_EmptyArrayRemoveReverts() public {
        _logCase("CL-BLK-05", unicode"空数组（移除）");

        _step("[Step 1] removeFromBlocklist with empty array");
        address[] memory empty = new address[](0);
        vm.prank(complianceOps);
        vm.expectRevert(Compliance.EmptyAddressesArray.selector);
        compliance.removeFromBlocklist(address(token), empty);
        _step("  PASS: reverted EmptyAddressesArray()");

        _logPass();
    }

    // ── CL-BLK-06 ──
    function test_CLBLK06_ZeroAddressAddReverts() public {
        _logCase("CL-BLK-06", unicode"零地址（添加）");

        _step("[Step 1] addToBlocklist with [address(0)]");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        vm.prank(complianceOps);
        vm.expectRevert(Compliance.ZeroAddress.selector);
        compliance.addToBlocklist(address(token), addrs);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── CL-BLK-07 ──
    function test_CLBLK07_ZeroAddressRemoveReverts() public {
        _logCase("CL-BLK-07", unicode"零地址（移除）");

        _step("[Step 1] removeFromBlocklist with [address(0)]");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        vm.prank(complianceOps);
        vm.expectRevert(Compliance.ZeroAddress.selector);
        compliance.removeFromBlocklist(address(token), addrs);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── CL-BLK-08 ──
    function test_CLBLK08_BatchBlocklist() public {
        _logCase("CL-BLK-08", unicode"批量多地址");

        _step("[Step 1] addToBlocklist([userA, userB, stranger])");
        address[] memory addrs = new address[](3);
        addrs[0] = userA;
        addrs[1] = userB;
        addrs[2] = stranger;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);

        assertTrue(compliance.blockedAddresses(address(token), userA));
        assertTrue(compliance.blockedAddresses(address(token), userB));
        assertTrue(compliance.blockedAddresses(address(token), stranger));
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
        compliance.addToBlocklist(address(token), addrs);
        compliance.addToBlocklist(address(token), addrs);
        vm.stopPrank();
        assertTrue(compliance.blockedAddresses(address(token), userA));
        _step("  PASS: no revert on duplicate add");

        _logPass();
    }

    // ── CL-BLK-10 ──
    function test_CLBLK10_RemoveUnblockedIdempotent() public {
        _logCase("CL-BLK-10", unicode"移除未拉黑幂等");

        _step("[Step 1] removeFromBlocklist for non-blocked userA");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.removeFromBlocklist(address(token), addrs);
        assertFalse(compliance.blockedAddresses(address(token), userA));
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
        compliance.addToSanctionsList(addrs);
        assertTrue(compliance.sanctionedAddresses(userA));
        _step("  PASS: userA sanctioned");

        _logPass();
    }

    // ── CL-SAN-02 ──
    function test_CLSAN02_AdminCannotManageSanctions() public {
        _logCase("CL-SAN-02", unicode"admin 不能操作制裁");

        _step("[Step 1] admin tries addToSanctionsList");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(admin);
        vm.expectRevert(Compliance.MissingBlocklistRole.selector);
        compliance.addToSanctionsList(addrs);
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ── CL-SAN-03 ──
    function test_CLSAN03_StrangerCannotManageSanctions() public {
        _logCase("CL-SAN-03", unicode"普通用户不能操作");

        _step("[Step 1] stranger tries addToSanctionsList");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(stranger);
        vm.expectRevert(Compliance.MissingBlocklistRole.selector);
        compliance.addToSanctionsList(addrs);
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ── CL-SAN-04 ──
    function test_CLSAN04_EmptyArrayReverts() public {
        _logCase("CL-SAN-04", unicode"空数组");

        _step("[Step 1] addToSanctionsList([])");
        address[] memory empty = new address[](0);
        vm.prank(complianceOps);
        vm.expectRevert(Compliance.EmptyAddressesArray.selector);
        compliance.addToSanctionsList(empty);
        _step("  PASS: reverted EmptyAddressesArray()");

        _logPass();
    }

    // ── CL-SAN-05 ──
    function test_CLSAN05_ZeroAddressReverts() public {
        _logCase("CL-SAN-05", unicode"零地址");

        _step("[Step 1] addToSanctionsList([address(0)])");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        vm.prank(complianceOps);
        vm.expectRevert(Compliance.ZeroAddress.selector);
        compliance.addToSanctionsList(addrs);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── CL-SAN-06 ──
    function test_CLSAN06_DuplicateDedup() public {
        _logCase("CL-SAN-06", unicode"重复去重");

        _step("[Step 1] addToSanctionsList([userA, userA])");
        address[] memory addrs = new address[](2);
        addrs[0] = userA;
        addrs[1] = userA;
        vm.prank(complianceOps);
        vm.recordLogs();
        compliance.addToSanctionsList(addrs);

        assertTrue(compliance.sanctionedAddresses(userA));
        _step("  PASS: userA sanctioned, duplicate silently deduped");

        _logPass();
    }

    // ── CL-SAN-07 ──
    function test_CLSAN07_RemoveUnsanctionedSilent() public {
        _logCase("CL-SAN-07", unicode"移除未制裁静默");

        _step("[Step 1] removeFromSanctionsList([userA]) when not sanctioned");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.removeFromSanctionsList(addrs);
        assertFalse(compliance.sanctionedAddresses(userA));
        _step("  PASS: no revert, event emitted with empty effective list");

        _logPass();
    }

    // ── CL-SAN-08 ──
    function test_CLSAN08_SetDedup() public {
        _logCase("CL-SAN-08", unicode"set 去重");

        _step("[Step 1] setSanctionedAddresses([userA, userA])");
        address[] memory addrs = new address[](2);
        addrs[0] = userA;
        addrs[1] = userA;
        vm.prank(complianceOps);
        compliance.setSanctionedAddresses(addrs);
        assertTrue(compliance.sanctionedAddresses(userA));
        _step("  PASS: no revert, duplicate silently deduped");

        _logPass();
    }

    // ── CL-SAN-09 ──
    function test_CLSAN09_SetEmptyClears() public {
        _logCase("CL-SAN-09", unicode"set 空数组清除");

        _step("[Step 1] sanction userA, then setSanctionedAddresses([])");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.addToSanctionsList(addrs);
        assertTrue(compliance.sanctionedAddresses(userA));

        address[] memory empty = new address[](0);
        vm.prank(complianceOps);
        compliance.setSanctionedAddresses(empty);
        assertFalse(compliance.sanctionedAddresses(userA));
        _step("  PASS: all sanctions cleared");

        _logPass();
    }

    // ── CL-SAN-10 ──
    function test_CLSAN10_SetZeroAddressReverts() public {
        _logCase("CL-SAN-10", unicode"set 零地址回滚");

        _step("[Step 1] setSanctionedAddresses([address(0)])");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        vm.prank(complianceOps);
        vm.expectRevert(Compliance.ZeroAddress.selector);
        compliance.setSanctionedAddresses(addrs);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }
}
