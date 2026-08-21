// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract QATokenIssuer is BaseQAScript {
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
        bool wasHot = vault.isApprovedRecipient(userA);
        if (wasHot) {
            vm.broadcast(adminPk);
            vault.removeApprovedRecipient(userA);
            _assertEq(vault.isApprovedRecipient(userA), false, "userA removed");
            _step("  userA was hotWallet, removed");
        }

        _step("[Step 2] admin adds userA as hotWallet");
        uint256 countBefore = vault.numApprovedRecipients();
        vm.broadcast(adminPk);
        vault.addApprovedRecipient(userA);
        _assertEq(vault.isApprovedRecipient(userA), true, "isApprovedRecipient");
        _assertEq(vault.numApprovedRecipients(), countBefore + 1, "numApprovedRecipients +1");
        _step("  PASS: userA added as hotWallet");

        _step("[Step 3] cleanup: remove userA to restore initial state");
        vm.broadcast(adminPk);
        vault.removeApprovedRecipient(userA);
        _assertEq(vault.isApprovedRecipient(userA), false, "userA removed");

        _logPass();
    }

    // ── QA-OW-02: 非 admin 不能添加热钱包 ──
    function test_OW02() public {
        _logCase("QA-OW-02", unicode"非 admin 不能添加热钱包");

        _step("[Step 1] precondition: walletOps has no DEFAULT_ADMIN_ROLE on wallet");
        _assertEq(vault.hasRole(DEFAULT_ADMIN_ROLE_HASH, walletOps), false, "walletOps no admin");

        _step("[Step 2] walletOps tries addApprovedRecipient");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(vault.addApprovedRecipient.selector, userA),
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
        _requireRole(address(vault), WALLET_OPS_ROLE, walletOps, "walletOps");
        _requireRole(address(token), ISSUER_ROLE, address(vault), "wallet ISSUER");

        _step("[Step 2] record before, walletOps mints 100e18");
        uint256 hotBefore = token.balanceOf(hotWallet);
        uint256 walletBefore = token.balanceOf(address(vault));
        uint256 supplyBefore = token.totalSupply();

        vm.broadcast(walletOpsPk);
        vault.mint(address(token), hotWallet, 100e18);

        _step("[Step 3] verify");
        _assertDiff(hotBefore, token.balanceOf(hotWallet), 100e18, "hotWallet diff");
        _step("  PASS: hotWallet +100e18");
        _assertEq(token.balanceOf(address(vault)), walletBefore, "wallet unchanged");
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
        uint256 walletBefore = token.balanceOf(address(vault));
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), address(vault), 50e18);
        _assertDiff(walletBefore, token.balanceOf(address(vault)), 50e18, "wallet diff");
        _step("  PASS: wallet +50e18");

        _logPass();
    }

    // ── QA-OW-05: mint 到非热钱包回滚 ──
    function test_OW05() public {
        _logCase("QA-OW-05", unicode"mint 到非热钱包回滚");

        _step("[Step 1] precondition: userA is not hotWallet");
        _assertEq(vault.isApprovedRecipient(userA), false, "userA not hot");

        _step("[Step 2] walletOps tries mint to userA");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(TokenIssuer.mint.selector, address(token), userA, 1e18),
            TokenIssuer.RecipientNotApproved.selector
        );
        _step("  PASS: reverted RecipientNotApproved()");

        _logPass();
    }

    // ── QA-OW-06: walletOPS burn 从热钱包 ──
    function test_OW06() public {
        _logCase("QA-OW-06", unicode"walletOPS burn 从热钱包");

        _step("[Step 1] preconditions: mint to hotWallet, approve wallet");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        vm.broadcast(hotWalletPk);
        token.approve(address(vault), type(uint256).max);

        _step("[Step 2] record before, walletOps burns 40e18");
        uint256 hotBefore = token.balanceOf(hotWallet);
        uint256 supplyBefore = token.totalSupply();
        vm.broadcast(walletOpsPk);
        vault.burn(address(token), hotWallet, 40e18);

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
        vault.mint(address(token), address(vault), 100e18);

        _step("[Step 2] walletOps burns 30e18 from wallet");
        uint256 walletBefore = token.balanceOf(address(vault));
        vm.broadcast(walletOpsPk);
        vault.burn(address(token), address(vault), 30e18);
        _assertDiff(walletBefore, token.balanceOf(address(vault)), -30e18, "wallet diff");
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
        token.approve(address(vault), 0);
        _assertEq(token.allowance(hotWallet, address(vault)), 0, "no allowance");

        _step("[Step 2] walletOps tries burn without approval (safeTransferFrom -> ERC20InsufficientAllowance)");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(TokenIssuer.burn.selector, address(token), hotWallet, 10e18),
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
        vault.mint(address(token), address(vault), 50e18);

        _step("[Step 2] walletOps transfers 30e18 to hotWallet");
        uint256 walletBefore = token.balanceOf(address(vault));
        uint256 hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(walletOpsPk);
        vault.transfer(address(token), hotWallet, 30e18);
        _assertDiff(walletBefore, token.balanceOf(address(vault)), -30e18, "wallet diff");
        _assertDiff(hotBefore, token.balanceOf(hotWallet), 30e18, "hotWallet diff");
        _step("  PASS: wallet -30e18, hotWallet +30e18");

        _logPass();
    }

    // ── QA-OW-10: transfer 到非热钱包回滚 ──
    function test_OW10() public {
        _logCase("QA-OW-10", unicode"transfer 到非热钱包回滚");

        _step("[Step 1] precondition: userA is not hotWallet");
        _assertEq(vault.isApprovedRecipient(userA), false, "userA not hot");

        _step("[Step 2] walletOps tries transfer to userA");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(vault.transfer.selector, address(token), userA, 1e18),
            TokenIssuer.RecipientNotApproved.selector
        );
        _step("  PASS: reverted RecipientNotApproved()");

        _logPass();
    }

    // ── QA-OW-11: admin 暂停 wallet 阻断 mint ──
    function test_OW11() public {
        _logCase("QA-OW-11", unicode"admin 暂停 wallet 阻断 mint");

        _step("[Step 1] admin pauses wallet");
        vm.broadcast(adminPk);
        vault.pause();

        _step("[Step 2] walletOps tries mint");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(TokenIssuer.mint.selector, address(token), hotWallet, 1e18),
            Pausable.EnforcedPause.selector
        );
        _step("  PASS: reverted EnforcedPause()");

        _step("[Step 3] cleanup: unpause wallet");
        vm.broadcast(adminPk);
        vault.unpause();
        _step("  PASS: wallet unpaused");

        _logPass();
    }

    // ── QA-OW-12: admin 提取 ERC20 ──
    function test_OW12() public {
        _logCase("QA-OW-12", unicode"admin 提取 ERC20");

        _step("[Step 1] mint 100e18 to wallet itself");
        _requireNotPaused();
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), address(vault), 100e18);
        uint256 walletBal = token.balanceOf(address(vault));
        _assertGt(walletBal, 0, "wallet has balance");

        _step("[Step 2] admin withdraws ERC20");
        uint256 adminBefore = token.balanceOf(admin);
        vm.broadcast(adminPk);
        vault.withdraw(address(token));
        _assertEq(token.balanceOf(address(vault)), 0, "wallet emptied");
        _assertDiff(adminBefore, token.balanceOf(admin), int256(walletBal), "admin received");
        _step("  PASS: wallet emptied, admin received tokens");

        _logPass();
    }

    // ── QA-OW-13: withdraw(address(0)) revert ZeroAddress ──
    function test_OW13() public {
        _logCase("QA-OW-13", unicode"withdraw(address(0)) 回滚 ZeroAddress");

        _step("[Step 1] admin tries withdraw(address(0))");
        _expectRevertFrom(
            admin,
            address(vault),
            abi.encodeWithSelector(vault.withdraw.selector, address(0)),
            TokenIssuer.ZeroAddress.selector
        );
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── QA-OW-14: 非 admin 不能提取 ──
    function test_OW14() public {
        _logCase("QA-OW-14", unicode"非 admin 不能提取");

        _step("[Step 1] precondition: walletOps has no DEFAULT_ADMIN_ROLE");
        _assertEq(vault.hasRole(DEFAULT_ADMIN_ROLE_HASH, walletOps), false, "walletOps no admin");

        _step("[Step 2] walletOps tries withdraw");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(vault.withdraw.selector, address(token)),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: reverted AccessControlUnauthorizedAccount()");

        _logPass();
    }
}
