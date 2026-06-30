// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {OperatorWallet} from "../../src/OperatorWallet/OperatorWallet.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract QAOperatorWallet is BaseQAScript {
    function run() external {
        _loadEnv();

        test_OW01();
        test_OW02();
        test_OW03();
        test_OW04();
        test_OW05();
        test_OW06();
        test_OW07();
        test_OW08();
        test_OW09();
        test_OW10();
        test_OW11();
        test_OW12();
        test_OW13();
        test_OW14();
    }

    // ── QA-OW-01: admin 添加热钱包 ──
    function test_OW01() public {
        _logCase("QA-OW-01", unicode"admin 添加热钱包");

        _step("[Step 1] precondition: if userA is already hotWallet, remove first");
        bool wasHot = wallet.isHotWallet(userA);
        if (wasHot) {
            vm.broadcast(adminPk);
            wallet.removeHotWallet(userA);
            _assertEq(wallet.isHotWallet(userA), false, "userA removed");
            _step("  userA was hotWallet, removed");
        }

        _step("[Step 2] admin adds userA as hotWallet");
        uint256 countBefore = wallet.numOfHotWallets();
        vm.broadcast(adminPk);
        wallet.addHotWallet(userA);
        _assertEq(wallet.isHotWallet(userA), true, "isHotWallet");
        _assertEq(wallet.numOfHotWallets(), countBefore + 1, "numOfHotWallets +1");
        _step("  PASS: userA added as hotWallet");

        _step("[Step 3] cleanup: remove userA to restore initial state");
        vm.broadcast(adminPk);
        wallet.removeHotWallet(userA);
        _assertEq(wallet.isHotWallet(userA), false, "userA removed");

        _logPass();
    }

    // ── QA-OW-02: 非 admin 不能添加热钱包 ──
    function test_OW02() public {
        _logCase("QA-OW-02", unicode"非 admin 不能添加热钱包");

        _step("[Step 1] precondition: walletOps has no DEFAULT_ADMIN_ROLE on wallet");
        _assertEq(wallet.hasRole(DEFAULT_ADMIN_ROLE_HASH, walletOps), false, "walletOps no admin");

        _step("[Step 2] walletOps tries addHotWallet");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(wallet.addHotWallet.selector, userA),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: reverted AccessControlUnauthorizedAccount()");

        _logPass();
    }

    // ── QA-OW-03: walletOPS mint 到热钱包 ──
    function test_OW03() public {
        _logCase("QA-OW-03", unicode"walletOPS mint 到热钱包");

        _step("[Step 1] preconditions");
        _requireNotPaused();
        _requireRole(address(wallet), WALLET_OPS_ROLE, walletOps, "walletOps");
        _requireRole(address(token), ISSUER_ROLE, address(wallet), "wallet ISSUER");

        _step("[Step 2] record before, walletOps mints 100e18");
        uint256 hotBefore = token.balanceOf(hotWallet);
        uint256 walletBefore = token.balanceOf(address(wallet));
        uint256 supplyBefore = token.totalSupply();

        vm.broadcast(walletOpsPk);
        wallet.mint(address(token), hotWallet, 100e18);

        _step("[Step 3] verify");
        _assertDiff(hotBefore, token.balanceOf(hotWallet), 100e18, "hotWallet diff");
        _step("  PASS: hotWallet +100e18");
        _assertEq(token.balanceOf(address(wallet)), walletBefore, "wallet unchanged");
        _step("  PASS: wallet balance unchanged");
        _assertDiff(supplyBefore, token.totalSupply(), 100e18, "supply diff");
        _step("  PASS: totalSupply +100e18");

        _logPass();
    }

    // ── QA-OW-04: walletOPS mint 到 wallet 自身 ──
    function test_OW04() public {
        _logCase("QA-OW-04", unicode"walletOPS mint 到 wallet 自身");

        _step("[Step 1] preconditions");
        _requireNotPaused();

        _step("[Step 2] walletOps mints 50e18 to wallet itself");
        uint256 walletBefore = token.balanceOf(address(wallet));
        vm.broadcast(walletOpsPk);
        wallet.mint(address(token), address(wallet), 50e18);
        _assertDiff(walletBefore, token.balanceOf(address(wallet)), 50e18, "wallet diff");
        _step("  PASS: wallet +50e18");

        _logPass();
    }

    // ── QA-OW-05: mint 到非热钱包回滚 ──
    function test_OW05() public {
        _logCase("QA-OW-05", unicode"mint 到非热钱包回滚");

        _step("[Step 1] precondition: userA is not hotWallet");
        _assertEq(wallet.isHotWallet(userA), false, "userA not hot");

        _step("[Step 2] walletOps tries mint to userA");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(OperatorWallet.mint.selector, address(token), userA, 1e18),
            OperatorWallet.RecipientNotHotWallet.selector
        );
        _step("  PASS: reverted RecipientNotHotWallet()");

        _logPass();
    }

    // ── QA-OW-06: walletOPS burn 从热钱包 ──
    function test_OW06() public {
        _logCase("QA-OW-06", unicode"walletOPS burn 从热钱包");

        _step("[Step 1] preconditions: mint to hotWallet, approve wallet");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        vm.broadcast(hotWalletPk);
        token.approve(address(wallet), type(uint256).max);

        _step("[Step 2] record before, walletOps burns 40e18");
        uint256 hotBefore = token.balanceOf(hotWallet);
        uint256 supplyBefore = token.totalSupply();
        vm.broadcast(walletOpsPk);
        wallet.burn(address(token), hotWallet, 40e18);

        _step("[Step 3] verify");
        _assertDiff(hotBefore, token.balanceOf(hotWallet), -40e18, "hotWallet diff");
        _step("  PASS: hotWallet -40e18");
        _assertDiff(supplyBefore, token.totalSupply(), -40e18, "supply diff");
        _step("  PASS: totalSupply -40e18");

        _logPass();
    }

    // ── QA-OW-07: burn 从 wallet 自身 ──
    function test_OW07() public {
        _logCase("QA-OW-07", unicode"burn 从 wallet 自身");

        _step("[Step 1] mint 100e18 to wallet itself");
        _requireNotPaused();
        vm.broadcast(walletOpsPk);
        wallet.mint(address(token), address(wallet), 100e18);

        _step("[Step 2] walletOps burns 30e18 from wallet");
        uint256 walletBefore = token.balanceOf(address(wallet));
        vm.broadcast(walletOpsPk);
        wallet.burn(address(token), address(wallet), 30e18);
        _assertDiff(walletBefore, token.balanceOf(address(wallet)), -30e18, "wallet diff");
        _step("  PASS: wallet -30e18");

        _logPass();
    }

    // ── QA-OW-08: burn 无 approval 回滚 ──
    function test_OW08() public {
        _logCase("QA-OW-08", unicode"burn 无 approval 回滚");

        _step("[Step 1] preconditions: mint to hotWallet, ensure no approval");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        vm.broadcast(hotWalletPk);
        token.approve(address(wallet), 0);
        _assertEq(token.allowance(hotWallet, address(wallet)), 0, "no allowance");

        _step("[Step 2] walletOps tries burn without approval (safeTransferFrom -> ERC20InsufficientAllowance)");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(OperatorWallet.burn.selector, address(token), hotWallet, 10e18),
            IERC20Errors.ERC20InsufficientAllowance.selector
        );
        _step("  PASS: reverted ERC20InsufficientAllowance()");

        _logPass();
    }

    // ── QA-OW-09: walletOPS transfer 到热钱包 ──
    function test_OW09() public {
        _logCase("QA-OW-09", unicode"walletOPS transfer 到热钱包");

        _step("[Step 1] mint 50e18 to wallet itself");
        _requireNotPaused();
        vm.broadcast(walletOpsPk);
        wallet.mint(address(token), address(wallet), 50e18);

        _step("[Step 2] walletOps transfers 30e18 to hotWallet");
        uint256 walletBefore = token.balanceOf(address(wallet));
        uint256 hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(walletOpsPk);
        wallet.transfer(address(token), hotWallet, 30e18);
        _assertDiff(walletBefore, token.balanceOf(address(wallet)), -30e18, "wallet diff");
        _assertDiff(hotBefore, token.balanceOf(hotWallet), 30e18, "hotWallet diff");
        _step("  PASS: wallet -30e18, hotWallet +30e18");

        _logPass();
    }

    // ── QA-OW-10: transfer 到非热钱包回滚 ──
    function test_OW10() public {
        _logCase("QA-OW-10", unicode"transfer 到非热钱包回滚");

        _step("[Step 1] precondition: userA is not hotWallet");
        _assertEq(wallet.isHotWallet(userA), false, "userA not hot");

        _step("[Step 2] walletOps tries transfer to userA");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(wallet.transfer.selector, address(token), userA, 1e18),
            OperatorWallet.RecipientNotHotWallet.selector
        );
        _step("  PASS: reverted RecipientNotHotWallet()");

        _logPass();
    }

    // ── QA-OW-11: admin 暂停 wallet 阻断 mint ──
    function test_OW11() public {
        _logCase("QA-OW-11", unicode"admin 暂停 wallet 阻断 mint");

        _step("[Step 1] admin pauses wallet");
        vm.broadcast(adminPk);
        wallet.pause();

        _step("[Step 2] walletOps tries mint");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(OperatorWallet.mint.selector, address(token), hotWallet, 1e18),
            Pausable.EnforcedPause.selector
        );
        _step("  PASS: reverted EnforcedPause()");

        _step("[Step 3] cleanup: unpause wallet");
        vm.broadcast(adminPk);
        wallet.unpause();
        _step("  PASS: wallet unpaused");

        _logPass();
    }

    // ── QA-OW-12: admin 提取 ERC20 ──
    function test_OW12() public {
        _logCase("QA-OW-12", unicode"admin 提取 ERC20");

        _step("[Step 1] mint 100e18 to wallet itself");
        _requireNotPaused();
        vm.broadcast(walletOpsPk);
        wallet.mint(address(token), address(wallet), 100e18);
        uint256 walletBal = token.balanceOf(address(wallet));
        _assertGt(walletBal, 0, "wallet has balance");

        _step("[Step 2] admin withdraws ERC20");
        uint256 adminBefore = token.balanceOf(admin);
        vm.broadcast(adminPk);
        wallet.withdraw(address(token));
        _assertEq(token.balanceOf(address(wallet)), 0, "wallet emptied");
        _assertDiff(adminBefore, token.balanceOf(admin), int256(walletBal), "admin received");
        _step("  PASS: wallet emptied, admin received tokens");

        _logPass();
    }

    // ── QA-OW-13: admin 提取 native ──
    function test_OW13() public {
        _logCase("QA-OW-13", unicode"admin 提取 native");

        _step("[Step 1] check wallet native balance");
        uint256 walletNative = address(wallet).balance;
        if (walletNative == 0) {
            _step("  wallet has 0 native balance, sending 0.01 MNT");
            vm.broadcast(adminPk);
            (bool ok,) = address(wallet).call{value: 0.01 ether}("");
            require(ok, "send MNT failed");
            walletNative = address(wallet).balance;
        }
        _assertGt(walletNative, 0, "wallet has native");

        _step("[Step 2] admin withdraws native");
        uint256 adminBefore = admin.balance;
        vm.broadcast(adminPk);
        wallet.withdraw(address(0));
        _assertEq(address(wallet).balance, 0, "wallet native emptied");
        _step("  PASS: wallet native balance == 0");

        _logPass();
    }

    // ── QA-OW-14: 非 admin 不能提取 ──
    function test_OW14() public {
        _logCase("QA-OW-14", unicode"非 admin 不能提取");

        _step("[Step 1] precondition: walletOps has no DEFAULT_ADMIN_ROLE");
        _assertEq(wallet.hasRole(DEFAULT_ADMIN_ROLE_HASH, walletOps), false, "walletOps no admin");

        _step("[Step 2] walletOps tries withdraw");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(wallet.withdraw.selector, address(token)),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: reverted AccessControlUnauthorizedAccount()");

        _logPass();
    }
}
