// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {OperatorWallet} from "../../src/OperatorWallet/OperatorWallet.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract OperatorWalletQA2 is BaseQA {
    string constant MODULE = unicode"OperatorWallet 补充";

    // ═══════════════════════════════════════════════
    //      removeHotWallet 权限与边界
    // ═══════════════════════════════════════════════

    // ── OW-HW-07 ──
    function test_OWHW07_NonAdminCannotRemove() public {
        _logCase("OW-HW-07", unicode"非 admin 不能移除热钱包");

        _step("[Step 1] ops tries removeHotWallet");
        vm.prank(walletOps);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, walletOps, DEFAULT_ADMIN_ROLE_HASH));
        wallet.removeHotWallet(hotWallet1);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── OW-HW-08 ──
    function test_OWHW08_StrangerCannotRemove() public {
        _logCase("OW-HW-08", unicode"stranger 不能移除热钱包");

        _step("[Step 1] stranger tries removeHotWallet");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE_HASH));
        wallet.removeHotWallet(hotWallet1);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── OW-HW-09 ──
    function test_OWHW09_RemoveZeroAddressReverts() public {
        _logCase("OW-HW-09", unicode"移除零地址回滚");

        _step("[Step 1] removeHotWallet(address(0))");
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.ZeroAddress.selector);
        wallet.removeHotWallet(address(0));
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── OW-HW-10 ──
    function test_OWHW10_RemoveNonExistentReverts() public {
        _logCase("OW-HW-10", unicode"移除不存在的热钱包回滚");

        _step("[Step 1] removeHotWallet(stranger)");
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.HotWalletNotFound.selector);
        wallet.removeHotWallet(stranger);
        _step("  PASS: reverted HotWalletNotFound()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      transfer 权限
    // ═══════════════════════════════════════════════

    // ── OW-TXF-03 ──
    function test_OWTXF03_AdminCannotTransfer() public {
        _logCase("OW-TXF-03", unicode"admin 不能 transfer");

        _step("[Step 1] mint to wallet, admin tries transfer");
        vm.prank(walletOps);
        wallet.mint(address(token), address(wallet), 50e18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, WALLET_OPS_ROLE));
        wallet.transfer(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── OW-TXF-04 ──
    function test_OWTXF04_StrangerCannotTransfer() public {
        _logCase("OW-TXF-04", unicode"stranger 不能 transfer");

        _step("[Step 1] mint to wallet, stranger tries transfer");
        vm.prank(walletOps);
        wallet.mint(address(token), address(wallet), 50e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, WALLET_OPS_ROLE));
        wallet.transfer(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── OW-TXF-05 ──
    function test_OWTXF05_PausedTransferReverts() public {
        _logCase("OW-TXF-05", unicode"暂停后 transfer 回滚");

        _step("[Step 1] mint to wallet, pause, ops tries transfer");
        vm.prank(walletOps);
        wallet.mint(address(token), address(wallet), 50e18);
        vm.prank(admin);
        wallet.pause();
        vm.prank(walletOps);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wallet.transfer(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted (EnforcedPause)");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      hotWallets 数组访问
    // ═══════════════════════════════════════════════

    // ── OW-HW-11 ──
    function test_OWHW11_HotWalletsArrayAccess() public {
        _logCase("OW-HW-11", unicode"hotWallets 数组正确");

        _step("[Step 1] query hotWallets(0) and hotWallets(1)");
        address hw0 = wallet.hotWallets(0);
        address hw1 = wallet.hotWallets(1);
        assertTrue(hw0 == hotWallet1 || hw0 == hotWallet2);
        assertTrue(hw1 == hotWallet1 || hw1 == hotWallet2);
        assertTrue(hw0 != hw1);
        _step("  PASS: both hot wallets accessible, distinct");

        _logPass();
    }

    // ── OW-HW-12 ──
    function test_OWHW12_RemoveLastSwapsCorrectly() public {
        _logCase("OW-HW-12", unicode"移除第一个后数组交换正确");

        _step("[Step 1] remove hotWallet1 (not the last element)");
        vm.prank(admin);
        wallet.removeHotWallet(hotWallet1);

        assertFalse(wallet.isHotWallet(hotWallet1));
        assertTrue(wallet.isHotWallet(hotWallet2));
        assertEq(wallet.numOfHotWallets(), 1);
        assertEq(wallet.hotWallets(0), hotWallet2);
        _step("  PASS: hotWallet2 moved to index 0 after swap-remove");

        _logPass();
    }
}
