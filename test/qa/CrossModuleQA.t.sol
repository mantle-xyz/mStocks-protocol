// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {PauseManager} from "../../src/pauseManager/PauseManager.sol";
import {PauseManagerClientUpgradeable} from "../../src/pauseManager/PauseManagerClientUpgradeable.sol";

contract CrossModuleQA is BaseQA {
    string constant MODULE = unicode"跨模块交互";

    // ═══════════════════════════════════════════════
    //      Compliance × OperatorWallet
    // ═══════════════════════════════════════════════

    // ── XM-01 ──
    function test_XM01_BlockedHotWalletBlocksMintTransfer() public {
        _logCase("XM-01", unicode"被封锁热钱包导致 OperatorWallet.mint 转账失败");

        _step("[Step 1] block hotWallet1");
        address[] memory addrs = new address[](1);
        addrs[0] = hotWallet1;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);

        _step("[Step 2] walletOps tries mint to hotWallet1");
        vm.prank(walletOps);
        vm.expectRevert(Compliance.UserBlocked.selector);
        wallet.mint(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted UserBlocked - blocked recipient");

        _logPass();
    }

    // ── XM-02 ──
    function test_XM02_SanctionedHotWalletBlocksMintTransfer() public {
        _logCase("XM-02", unicode"被制裁热钱包导致 OperatorWallet.mint 转账失败");

        _step("[Step 1] sanction hotWallet1");
        address[] memory addrs = new address[](1);
        addrs[0] = hotWallet1;
        vm.prank(complianceOps);
        compliance.addToSanctionsList(addrs);

        _step("[Step 2] walletOps tries mint to hotWallet1");
        vm.prank(walletOps);
        vm.expectRevert(Compliance.UserSanctioned.selector);
        wallet.mint(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted UserSanctioned - sanctioned recipient");

        _logPass();
    }

    // ── XM-03 ──
    function test_XM03_BlockedWalletBlocksSelfMint() public {
        _logCase("XM-03", unicode"封锁 wallet 自身导致 mint(self) 失败");

        _step("[Step 1] block the wallet contract itself");
        address[] memory addrs = new address[](1);
        addrs[0] = address(wallet);
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);

        _step("[Step 2] walletOps tries mint to self");
        vm.prank(walletOps);
        vm.expectRevert(Compliance.UserBlocked.selector);
        wallet.mint(address(token), address(wallet), 10e18);
        _step("  PASS: reverted UserBlocked - wallet itself blocked");

        _logPass();
    }

    // ── XM-04 ──
    function test_XM04_BlockedHotWalletBlocksBurn() public {
        _logCase("XM-04", unicode"被封锁热钱包导致 burn(from=hotWallet) 失败");

        _step("[Step 1] mint to hotWallet1 first");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 50e18);

        _step("[Step 2] hotWallet1 approves wallet");
        vm.prank(hotWallet1);
        token.approve(address(wallet), type(uint256).max);

        _step("[Step 3] block hotWallet1, then try burn from hotWallet1");
        address[] memory addrs = new address[](1);
        addrs[0] = hotWallet1;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);

        vm.prank(walletOps);
        vm.expectRevert(Compliance.UserBlocked.selector);
        wallet.burn(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted UserBlocked - blocked source on transferFrom");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      PauseManager × Token × OperatorWallet
    // ═══════════════════════════════════════════════

    // ── XM-05 ──
    function test_XM05_TokenPausedBlocksWalletMint() public {
        _logCase("XM-05", unicode"Token 暂停阻止 OperatorWallet.mint");

        _step("[Step 1] pause the token");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        _step("[Step 2] walletOps tries mint");
        vm.prank(walletOps);
        vm.expectRevert(PauseManagerClientUpgradeable.TokenPaused.selector);
        wallet.mint(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted TokenPaused");

        _logPass();
    }

    // ── XM-06 ──
    function test_XM06_TokenPausedBlocksWalletBurn() public {
        _logCase("XM-06", unicode"Token 暂停阻止 OperatorWallet.burn");

        _step("[Step 1] mint first, then pause");
        vm.prank(walletOps);
        wallet.mint(address(token), address(wallet), 50e18);
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        _step("[Step 2] walletOps tries burn");
        vm.prank(walletOps);
        vm.expectRevert(PauseManagerClientUpgradeable.TokenPaused.selector);
        wallet.burn(address(token), address(wallet), 10e18);
        _step("  PASS: reverted TokenPaused");

        _logPass();
    }

    // ── XM-07 ──
    function test_XM07_GlobalPauseBlocksWalletMint() public {
        _logCase("XM-07", unicode"全局暂停阻止 OperatorWallet.mint");

        _step("[Step 1] pauseAllTokens");
        vm.prank(pauseOps);
        pauseManager.pauseAllTokens();

        _step("[Step 2] walletOps tries mint");
        vm.prank(walletOps);
        vm.expectRevert(PauseManagerClientUpgradeable.TokenPaused.selector);
        wallet.mint(address(token), hotWallet1, 10e18);
        _step("  PASS: reverted TokenPaused via global pause");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Compliance / PauseManager 替换效果
    // ═══════════════════════════════════════════════

    // ── XM-08 ──
    function test_XM08_ComplianceReplacementClearsBlocklist() public {
        _logCase("XM-08", unicode"替换 Compliance 后旧黑名单失效");

        _step("[Step 1] block hotWallet1 on old compliance");
        address[] memory addrs = new address[](1);
        addrs[0] = hotWallet1;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);

        _step("[Step 2] deploy new Compliance, set on token");
        vm.startPrank(admin);
        Compliance newCompliance = new Compliance(admin);
        token.setCompliance(address(newCompliance));
        vm.stopPrank();

        _step("[Step 3] mint to hotWallet1 should succeed");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 10e18);
        assertEq(token.balanceOf(hotWallet1), 10e18);
        _step("  PASS: new compliance has no blocklist - mint succeeds");

        _logPass();
    }

    // ── XM-09 ──
    function test_XM09_PauseManagerReplacementClearsPause() public {
        _logCase("XM-09", unicode"替换 PauseManager 后旧暂停失效");

        _step("[Step 1] pause token on old PauseManager");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        _step("[Step 2] deploy new PauseManager, set on token");
        vm.startPrank(admin);
        PauseManager newPM = new PauseManager(admin);
        token.setPauseManager(address(newPM));
        vm.stopPrank();

        _step("[Step 3] mint should succeed (new PM has no paused tokens)");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 10e18);
        assertEq(token.balanceOf(hotWallet1), 10e18);
        _step("  PASS: new PauseManager not paused - mint succeeds");

        _logPass();
    }

    // ── XM-10 ──
    function test_XM10_UnblockRestoresFullFlow() public {
        _logCase("XM-10", unicode"解除封锁后 mint+transfer 全流程恢复");

        _step("[Step 1] block hotWallet1, verify blocked");
        address[] memory addrs = new address[](1);
        addrs[0] = hotWallet1;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);

        vm.prank(walletOps);
        vm.expectRevert(Compliance.UserBlocked.selector);
        wallet.mint(address(token), hotWallet1, 10e18);
        _step("  mint blocked as expected");

        _step("[Step 2] unblock hotWallet1");
        vm.prank(complianceOps);
        compliance.removeFromBlocklist(address(token), addrs);

        _step("[Step 3] mint to hotWallet1 succeeds");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 20e18);
        assertEq(token.balanceOf(hotWallet1), 20e18);
        _step("  PASS: full mint flow restored after unblock");

        _logPass();
    }

    // ── XM-11 ──
    function test_XM11_UnpauseRestoresFullFlow() public {
        _logCase("XM-11", unicode"解除暂停后 mint+transfer 全流程恢复");

        _step("[Step 1] pause token, verify blocked");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        vm.prank(walletOps);
        vm.expectRevert(PauseManagerClientUpgradeable.TokenPaused.selector);
        wallet.mint(address(token), hotWallet1, 10e18);
        _step("  mint blocked as expected");

        _step("[Step 2] unpause token");
        vm.prank(pauseOps);
        pauseManager.unpauseToken(address(token));

        _step("[Step 3] mint + transfer succeeds");
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, 20e18);
        assertEq(token.balanceOf(hotWallet1), 20e18);

        vm.prank(hotWallet1);
        token.transfer(userA, 5e18);
        assertEq(token.balanceOf(userA), 5e18);
        _step("  PASS: full flow restored after unpause");

        _logPass();
    }

    // ── XM-12 ──
    function test_XM12_TransferBlockedBySenderCompliance() public {
        _logCase("XM-12", unicode"发送方被封锁导致 transfer 失败");

        _step("[Step 1] mint to userA via hotWallet1");
        _mintAndTransfer(userA, 50e18);

        _step("[Step 2] block userA");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);

        _step("[Step 3] userA tries to transfer to userB");
        vm.prank(userA);
        vm.expectRevert(Compliance.UserBlocked.selector);
        token.transfer(userB, 10e18);
        _step("  PASS: reverted UserBlocked - blocked sender");

        _logPass();
    }

    // ── XM-13 ──
    function test_XM13_TransferBlockedByReceiverCompliance() public {
        _logCase("XM-13", unicode"接收方被封锁导致 transfer 失败");

        _step("[Step 1] mint to userA via hotWallet1");
        _mintAndTransfer(userA, 50e18);

        _step("[Step 2] block userB (the receiver)");
        address[] memory addrs = new address[](1);
        addrs[0] = userB;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);

        _step("[Step 3] userA tries to transfer to blocked userB");
        vm.prank(userA);
        vm.expectRevert(Compliance.UserBlocked.selector);
        token.transfer(userB, 10e18);
        _step("  PASS: reverted UserBlocked - blocked receiver");

        _logPass();
    }
}
