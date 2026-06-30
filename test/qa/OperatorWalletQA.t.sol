// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {OperatorWallet} from "../../src/OperatorWallet/OperatorWallet.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract OperatorWalletQA is BaseQA {
    string constant MODULE = "OperatorWallet";

    // ═══════════════════════════════════════════════
    //      A.20 初始化 [P1]
    // ═══════════════════════════════════════════════

    // ── OW-INIT-01 ──
    function test_OWINIT01_AdminHasDefaultAdminRole() public {
        _logCase("OW-INIT-01", unicode"admin 持有 DEFAULT_ADMIN_ROLE");

        _step("[Step 1] hasRole(DEFAULT_ADMIN_ROLE, admin)");
        assertTrue(wallet.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        _step("  PASS: true");

        _logPass();
    }

    // ── OW-INIT-02 ──
    function test_OWINIT02_OpsRoleAdminCorrect() public {
        _logCase("OW-INIT-02", unicode"OPS_ROLE admin 角色正确");

        _step("[Step 1] getRoleAdmin(OPS_ROLE)");
        assertEq(wallet.getRoleAdmin(WALLET_OPS_ROLE), DEFAULT_ADMIN_ROLE_HASH);
        _step("  PASS: DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── OW-INIT-03 ──
    function test_OWINIT03_CannotReinitialize() public {
        _logCase("OW-INIT-03", unicode"不能重复初始化");

        _step("[Step 1] wallet.initialize(admin) again");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wallet.initialize(admin);
        _step("  PASS: reverted (already initialized)");

        _logPass();
    }

    // ── OW-INIT-04 ──
    function test_OWINIT04_ZeroAdminReverts() public {
        _logCase("OW-INIT-04", unicode"零地址 admin 回滚");

        _step("[Step 1] deploy new OperatorWallet with address(0)");
        OperatorWallet impl = new OperatorWallet();
        bytes memory initData = abi.encodeWithSelector(OperatorWallet.initialize.selector, address(0));
        vm.expectRevert(OperatorWallet.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.21 热钱包管理 [P0]
    // ═══════════════════════════════════════════════

    // ── OW-HW-01 ──
    function test_OWHW01_AdminAddHotWallet() public {
        _logCase("OW-HW-01", unicode"admin 添加热钱包");

        _step("[Step 1] deploy fresh wallet, add hotWallet");
        OperatorWallet w = _deployFreshWallet();
        address hw = makeAddr("freshHW");
        vm.prank(admin);
        w.addHotWallet(hw);
        assertTrue(w.isHotWallet(hw));
        assertEq(w.numOfHotWallets(), 1);
        _step("  PASS: isHotWallet==true, numOfHotWallets==1");

        _logPass();
    }

    // ── OW-HW-02 ──
    function test_OWHW02_NonAdminCannotAdd() public {
        _logCase("OW-HW-02", unicode"非 admin 不能添加");

        _step("[Step 1] ops tries addHotWallet");
        address hw = makeAddr("hwX");
        vm.prank(walletOps);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, walletOps, DEFAULT_ADMIN_ROLE_HASH));
        wallet.addHotWallet(hw);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── OW-HW-03 ──
    function test_OWHW03_ZeroAddressReverts() public {
        _logCase("OW-HW-03", unicode"零地址回滚");

        _step("[Step 1] addHotWallet(address(0))");
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.ZeroAddress.selector);
        wallet.addHotWallet(address(0));
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── OW-HW-04 ──
    function test_OWHW04_DuplicateReverts() public {
        _logCase("OW-HW-04", unicode"重复添加回滚");

        _step("[Step 1] addHotWallet(hotWallet1) again");
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.HotWalletAlreadyExists.selector);
        wallet.addHotWallet(hotWallet1);
        _step("  PASS: reverted HotWalletAlreadyExists()");

        _logPass();
    }

    // ── OW-HW-05 ──
    function test_OWHW05_SelfAddressReverts() public {
        _logCase("OW-HW-05", unicode"自身地址回滚");

        _step("[Step 1] addHotWallet(address(wallet))");
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.CannotBeSelf.selector);
        wallet.addHotWallet(address(wallet));
        _step("  PASS: reverted CannotBeSelf()");

        _logPass();
    }

    // ── OW-HW-06 ──
    function test_OWHW06_AdminRemoveHotWallet() public {
        _logCase("OW-HW-06", unicode"admin 移除热钱包");

        _step("[Step 1] removeHotWallet(hotWallet1)");
        vm.prank(admin);
        wallet.removeHotWallet(hotWallet1);
        assertFalse(wallet.isHotWallet(hotWallet1));
        assertTrue(wallet.isHotWallet(hotWallet2));
        assertEq(wallet.numOfHotWallets(), 1);
        _step("  PASS: hotWallet1 removed, hotWallet2 unaffected, count==1");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.22 暂停 [P0]
    // ═══════════════════════════════════════════════

    // ── OW-PSE-01 ──
    function test_OWPSE01_AdminCanPauseUnpause() public {
        _logCase("OW-PSE-01", unicode"admin 可暂停和解除");

        _step("[Step 1] admin pauses, addHotWallet reverts");
        vm.startPrank(admin);
        wallet.pause();
        address hw = makeAddr("hwPause");
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wallet.addHotWallet(hw);
        _step("  addHotWallet reverted under pause");

        _step("[Step 2] admin unpauses, addHotWallet succeeds");
        wallet.unpause();
        uint256 countBefore = wallet.numOfHotWallets();
        wallet.addHotWallet(hw);
        assertTrue(wallet.isHotWallet(hw));
        assertEq(wallet.numOfHotWallets(), countBefore + 1);
        vm.stopPrank();
        _step("  PASS: pause blocks, unpause restores, hot wallet count increased");

        _logPass();
    }

    // ── OW-PSE-02 ──
    function test_OWPSE02_PausedMintReverts() public {
        _logCase("OW-PSE-02", unicode"暂停后 mint 回滚");

        _step("[Step 1] admin pauses, ops tries mint");
        vm.prank(admin);
        wallet.pause();
        vm.prank(walletOps);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wallet.mint(address(token), hotWallet1, 1e18);
        _step("  PASS: reverted (EnforcedPause)");

        _logPass();
    }

    // ── OW-PSE-03 ──
    function test_OWPSE03_NonAdminCannotPause() public {
        _logCase("OW-PSE-03", unicode"非 admin 不能暂停");

        _step("[Step 1] ops tries pause");
        vm.prank(walletOps);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, walletOps, DEFAULT_ADMIN_ROLE_HASH));
        wallet.pause();
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── OW-PSE-04 ──
    function test_OWPSE04_PausedRemoveHotWalletReverts() public {
        _logCase("OW-PSE-04", unicode"暂停后 removeHotWallet 回滚");

        _step("[Step 1] admin pauses, tries removeHotWallet");
        vm.startPrank(admin);
        wallet.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wallet.removeHotWallet(hotWallet1);
        vm.stopPrank();
        _step("  PASS: reverted (EnforcedPause)");

        _logPass();
    }

    // ── OW-PSE-05 ──
    function test_OWPSE05_PausedWithdrawReverts() public {
        _logCase("OW-PSE-05", unicode"暂停后 withdraw 回滚");

        _step("[Step 1] admin pauses, tries withdraw");
        vm.startPrank(admin);
        wallet.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wallet.withdraw(address(0));
        vm.stopPrank();
        _step("  PASS: reverted (EnforcedPause)");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.23 Mint/Transfer [P0]
    // ═══════════════════════════════════════════════

    // ── OW-MINT-01 ──
    function test_OWMINT01_OpsMintToHotWallet() public {
        _logCase("OW-MINT-01", unicode"OPS mint 到热钱包");

        _step("[Step 1] ops mints 100e18 to hotWallet1");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 100e18);
        assertEq(token.balanceOf(hotWallet1), 100e18);
        assertEq(token.balanceOf(address(wallet)), 0);
        assertEq(token.totalSupply(), 100e18);
        _step("  PASS: hotWallet1==100e18, wallet==0, totalSupply==100e18");

        _logPass();
    }

    // ── OW-MINT-02 ──
    function test_OWMINT02_OpsMintToSelf() public {
        _logCase("OW-MINT-02", unicode"OPS mint 到 self");

        _step("[Step 1] ops mints 50e18 to wallet itself");
        vm.prank(walletOps);
        wallet.mint(address(token), address(wallet), 50e18);
        assertEq(token.balanceOf(address(wallet)), 50e18);
        _step("  PASS: wallet balance == 50e18");

        _logPass();
    }

    // ── OW-MINT-03 ──
    function test_OWMINT03_MintToNonHotWalletReverts() public {
        _logCase("OW-MINT-03", unicode"mint 到非热钱包回滚");

        _step("[Step 1] ops mints to stranger");
        vm.prank(walletOps);
        vm.expectRevert(OperatorWallet.RecipientNotHotWallet.selector);
        wallet.mint(address(token), stranger, 1e18);
        _step("  PASS: reverted RecipientNotHotWallet()");

        _logPass();
    }

    // ── OW-MINT-04 ──
    function test_OWMINT04_AdminCannotMint() public {
        _logCase("OW-MINT-04", unicode"admin 不能 mint");

        _step("[Step 1] admin tries mint");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, WALLET_OPS_ROLE));
        wallet.mint(address(token), hotWallet1, 1e18);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── OW-MINT-05 ──
    function test_OWMINT05_NoIssuerRoleMintReverts() public {
        _logCase("OW-MINT-05", unicode"无 ISSUER_ROLE 时 mint 回滚");

        _step("[Step 1] revoke ISSUER_ROLE from wallet, then ops tries mint");
        vm.prank(admin);
        token.revokeRole(ISSUER_ROLE, address(wallet));
        vm.prank(walletOps);
        vm.expectRevert(OperatorWallet.MissingIssuerRole.selector);
        wallet.mint(address(token), hotWallet1, 1e18);
        _step("  PASS: reverted MissingIssuerRole()");

        _logPass();
    }

    // ── OW-TXF-01 ──
    function test_OWTXF01_OpsTransferToHotWallet() public {
        _logCase("OW-TXF-01", unicode"OPS transfer 到热钱包");

        _step("[Step 1] mint 50e18 to wallet, transfer 30e18 to hotWallet1");
        vm.prank(walletOps);
        wallet.mint(address(token), address(wallet), 50e18);
        vm.prank(walletOps);
        wallet.transfer(address(token), hotWallet1, 30e18);
        assertEq(token.balanceOf(hotWallet1), 30e18);
        assertEq(token.balanceOf(address(wallet)), 20e18);
        _step("  PASS: hotWallet1==30e18, wallet==20e18");

        _logPass();
    }

    // ── OW-TXF-02 ──
    function test_OWTXF02_TransferToNonHotWalletReverts() public {
        _logCase("OW-TXF-02", unicode"transfer 到非热钱包回滚");

        _step("[Step 1] mint 50e18 to wallet, transfer to stranger reverts");
        vm.prank(walletOps);
        wallet.mint(address(token), address(wallet), 50e18);
        vm.prank(walletOps);
        vm.expectRevert(OperatorWallet.RecipientNotHotWallet.selector);
        wallet.transfer(address(token), stranger, 1e18);
        _step("  PASS: reverted RecipientNotHotWallet()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.24 Burn [P0]
    // ═══════════════════════════════════════════════

    // ── OW-BURN-01 ──
    function test_OWBURN01_OpsBurnFromHotWallet() public {
        _logCase("OW-BURN-01", unicode"OPS burn 从热钱包");

        _step("[Step 1] mint 100e18 to hotWallet1, approve wallet, burn 40e18");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 100e18);
        vm.prank(hotWallet1);
        token.approve(address(wallet), type(uint256).max);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(walletOps);
        wallet.burn(address(token), hotWallet1, 40e18);
        assertEq(token.balanceOf(hotWallet1), 60e18);
        assertEq(token.totalSupply(), supplyBefore - 40e18);
        _step("  PASS: hotWallet1==60e18, totalSupply decreased by 40e18");

        _logPass();
    }

    // ── OW-BURN-02 ──
    function test_OWBURN02_OpsBurnFromSelf() public {
        _logCase("OW-BURN-02", unicode"OPS burn 从 self");

        _step("[Step 1] mint 100e18 to wallet, burn 30e18");
        vm.prank(walletOps);
        wallet.mint(address(token), address(wallet), 100e18);
        vm.prank(walletOps);
        wallet.burn(address(token), address(wallet), 30e18);
        assertEq(token.balanceOf(address(wallet)), 70e18);
        _step("  PASS: wallet balance == 70e18");

        _logPass();
    }

    // ── OW-BURN-03 ──
    function test_OWBURN03_NoApprovalReverts() public {
        _logCase("OW-BURN-03", unicode"无 approval 回滚");

        _step("[Step 1] mint 100e18 to hotWallet1, burn without approval");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 100e18);
        vm.prank(walletOps);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(wallet), 0, 10e18));
        wallet.burn(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted (insufficient allowance)");

        _logPass();
    }

    // ── OW-BURN-04 ──
    function test_OWBURN04_NoBalanceReverts() public {
        _logCase("OW-BURN-04", unicode"无余额回滚");

        _step("[Step 1] hotWallet1 has 0 balance but approves, burn reverts");
        vm.prank(hotWallet1);
        token.approve(address(wallet), type(uint256).max);
        vm.prank(walletOps);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, hotWallet1, 0, 10e18));
        wallet.burn(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted (insufficient balance)");

        _logPass();
    }

    // ── OW-BURN-05 ──
    function test_OWBURN05_NonHotWalletBurnReverts() public {
        _logCase("OW-BURN-05", unicode"非热钱包 burn 回滚");

        _step("[Step 1] mint to hotWallet1, transfer to userA, remove hotWallet1, burn from userA reverts");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 100e18);
        vm.prank(hotWallet1);
        token.transfer(userA, 50e18);
        vm.prank(userA);
        token.approve(address(wallet), type(uint256).max);
        vm.prank(walletOps);
        vm.expectRevert(OperatorWallet.FromNotHotWallet.selector);
        wallet.burn(address(token), userA, 20e18);
        _step("  PASS: reverted FromNotHotWallet()");

        _logPass();
    }

    // ── OW-BURN-06 ──
    function test_OWBURN06_NoIssuerRoleBurnReverts() public {
        _logCase("OW-BURN-06", unicode"无 ISSUER_ROLE 时 burn 回滚");

        _step("[Step 1] mint, approve, revoke ISSUER_ROLE, burn reverts");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 100e18);
        vm.prank(hotWallet1);
        token.approve(address(wallet), type(uint256).max);
        vm.prank(admin);
        token.revokeRole(ISSUER_ROLE, address(wallet));
        vm.prank(walletOps);
        vm.expectRevert(OperatorWallet.MissingIssuerRole.selector);
        wallet.burn(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted MissingIssuerRole()");

        _logPass();
    }

    // ── OW-BURN-07 ──
    function test_OWBURN07_BurnDisabledReverts() public {
        _logCase("OW-BURN-07", unicode"token burn 开关关闭");

        _step("[Step 1] mint, approve, disable burn, burn reverts");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 100e18);
        vm.prank(hotWallet1);
        token.approve(address(wallet), type(uint256).max);
        vm.prank(admin);
        token.setBurnEnabled(false);
        vm.prank(walletOps);
        vm.expectRevert(SecuritiesToken.BurnDisabled.selector);
        wallet.burn(address(token), hotWallet1, 1e18);
        _step("  PASS: reverted BurnDisabled()");

        _logPass();
    }

    // ── OW-BURN-08 ──
    function test_OWBURN08_WalletPausedBurnReverts() public {
        _logCase("OW-BURN-08", unicode"wallet 暂停后 burn 回滚");

        _step("[Step 1] mint, approve, pause wallet, burn reverts");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 100e18);
        vm.prank(hotWallet1);
        token.approve(address(wallet), type(uint256).max);
        vm.prank(admin);
        wallet.pause();
        vm.prank(walletOps);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wallet.burn(address(token), hotWallet1, 1e18);
        _step("  PASS: reverted (EnforcedPause)");

        _logPass();
    }

    // ── OW-BURN-09 ──
    function test_OWBURN09_AdminCannotBurn() public {
        _logCase("OW-BURN-09", unicode"admin 不能 burn");

        _step("[Step 1] mint to hotWallet1, approve, admin tries burn");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 100e18);
        vm.prank(hotWallet1);
        token.approve(address(wallet), type(uint256).max);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, WALLET_OPS_ROLE));
        wallet.burn(address(token), hotWallet1, 1e18);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.25 Withdraw [P1]
    // ═══════════════════════════════════════════════

    // ── OW-WD-01 ──
    function test_OWWD01_AdminWithdrawNative() public {
        _logCase("OW-WD-01", unicode"admin 提取 native");

        _step("[Step 1] send 1 ether to wallet, admin withdraws");
        vm.deal(address(wallet), 1 ether);
        uint256 adminBefore = admin.balance;
        vm.prank(admin);
        wallet.withdraw(address(0));
        assertEq(address(wallet).balance, 0);
        assertEq(admin.balance, adminBefore + 1 ether);
        _step("  PASS: wallet==0, admin balance increased by 1 ether");

        _logPass();
    }

    // ── OW-WD-02 ──
    function test_OWWD02_AdminWithdrawERC20() public {
        _logCase("OW-WD-02", unicode"admin 提取 ERC20");

        _step("[Step 1] mint 100e18 to wallet, admin withdraws ERC20");
        vm.prank(walletOps);
        wallet.mint(address(token), address(wallet), 100e18);
        vm.prank(admin);
        wallet.withdraw(address(token));
        assertEq(token.balanceOf(admin), 100e18);
        assertEq(token.balanceOf(address(wallet)), 0);
        _step("  PASS: admin==100e18, wallet==0");

        _logPass();
    }

    // ── OW-WD-03 ──
    function test_OWWD03_NonAdminCannotWithdraw() public {
        _logCase("OW-WD-03", unicode"非 admin 不能提取");

        _step("[Step 1] ops tries withdraw");
        vm.deal(address(wallet), 1 ether);
        vm.prank(walletOps);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, walletOps, DEFAULT_ADMIN_ROLE_HASH));
        wallet.withdraw(address(0));
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //                Helper
    // ═══════════════════════════════════════════════

    function _deployFreshWallet() internal returns (OperatorWallet) {
        OperatorWallet impl = new OperatorWallet();
        bytes memory initData = abi.encodeWithSelector(OperatorWallet.initialize.selector, admin);
        return OperatorWallet(payable(address(new ERC1967Proxy(address(impl), initData))));
    }
}
