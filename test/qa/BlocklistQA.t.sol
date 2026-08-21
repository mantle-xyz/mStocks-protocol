// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BlocklistQA is BaseQA {
    string constant MODULE = unicode"黑名单";

    ScaledToken internal tokenB;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        address[] memory empty = new address[](0);
        tokenB = ScaledToken(factory.createToken("Google", "GOOG", "US02079K3059", admin, empty, empty));
        vm.stopPrank();
    }

    function _blockUser(address tkn, address user) internal {
        address[] memory addrs = new address[](1);
        addrs[0] = user;
        vm.prank(complianceOps);
        compliance.blockUsers(tkn, addrs);
    }

    function _unblockUser(address tkn, address user) internal {
        address[] memory addrs = new address[](1);
        addrs[0] = user;
        vm.prank(complianceOps);
        compliance.unblockUsers(tkn, addrs);
    }

    // ── ST-BLK-01 ──
    function test_STBLK01_BlockedUserCannotReceive() public {
        _logCase("ST-BLK-01", unicode"拉黑后转入回滚");

        _step("[Step 1] block userA on token");
        _blockUser(address(token), userA);

        _step("[Step 2] issuer tries to transfer to userA");
        _issuerMint(100e18);
        vm.prank(issuer);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        token.transfer(userA, 50e18);
        _step("  PASS: reverted UserBlocked()");

        _logPass();
    }

    // ── ST-BLK-02 ──
    function test_STBLK02_BlockedUserCannotSend() public {
        _logCase("ST-BLK-02", unicode"拉黑后转出回滚");

        _step("[Step 1] mint to userA, then block userA");
        _mintAndTransfer(userA, 100e18);
        _blockUser(address(token), userA);

        _step("[Step 2] userA tries to transfer to userB");
        vm.prank(userA);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        token.transfer(userB, 50e18);
        _step("  PASS: reverted UserBlocked()");

        _logPass();
    }

    // ── ST-BLK-03 ──
    function test_STBLK03_UnblockRestoresTransfer() public {
        _logCase("ST-BLK-03", unicode"解除拉黑后恢复");

        _step("[Step 1] block then unblock userA");
        _blockUser(address(token), userA);
        _unblockUser(address(token), userA);

        _step("[Step 2] issuer transfers to userA");
        _issuerMint(100e18);
        vm.prank(issuer);
        token.transfer(userA, 50e18);
        assertEq(token.balanceOf(userA), 50e18);
        _step("  PASS: transfer succeeded after unblock");

        _logPass();
    }

    // ── ST-BLK-04 ──
    function test_STBLK04_BlocklistIsolatedPerToken() public {
        _logCase("ST-BLK-04", unicode"黑名单按 token 隔离");

        _step("[Step 1] block userA on token, setup tokenB with balance for userA");
        _blockUser(address(token), userA);
        vm.startPrank(admin);
        tokenB.grantRole(tokenB.ISSUER_ROLE(), address(vault));
        vm.stopPrank();
        vm.startPrank(address(vault));
        tokenB.mint(100e18);
        tokenB.transfer(userA, 100e18);
        vm.stopPrank();

        _step("[Step 2] token transfer to userA reverts");
        _issuerMint(100e18);
        vm.prank(issuer);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        token.transfer(userA, 50e18);
        _step("  token: reverted UserBlocked()");

        _step("[Step 3] tokenB transfer from userA succeeds");
        vm.prank(userA);
        tokenB.transfer(userB, 50e18);
        assertEq(tokenB.balanceOf(userB), 50e18);
        _step("  PASS: tokenB transfer succeeded, blocklist is token-isolated");

        _logPass();
    }

    // ── ST-BLK-05 ──
    function test_STBLK05_TransferFromChecksThirdParty() public {
        _logCase("ST-BLK-05", unicode"transferFrom 检查第三方");

        _step("[Step 1] mint to userA, userA approves userB, block userB");
        _mintAndTransfer(userA, 100e18);
        vm.prank(userA);
        token.approve(userB, 100e18);
        _blockUser(address(token), userB);

        _step("[Step 2] userB calls transferFrom(userA, stranger, 50e18)");
        vm.prank(userB);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        token.transferFrom(userA, stranger, 50e18);
        _step("  PASS: reverted UserBlocked() for blocked msg.sender");

        _logPass();
    }

    // ── ST-BLK-06 ──
    function test_STBLK06_SelfTransferFromNoExtraCheck() public {
        _logCase("ST-BLK-06", unicode"from==sender 不重复检查");

        _step("[Step 1] mint to userA, userA approves self");
        _mintAndTransfer(userA, 100e18);
        vm.prank(userA);
        token.approve(userA, 100e18);

        _step("[Step 2] userA calls transferFrom(userA, userB, 50e18)");
        vm.prank(userA);
        token.transferFrom(userA, userB, 50e18);
        assertEq(token.balanceOf(userB), 50e18);
        _step("  PASS: transfer succeeded (no extra compliance check for from==sender)");

        _logPass();
    }

    // ── ST-BLK-07 ──
    function test_STBLK07_MintSkipsFromCheck() public {
        _logCase("ST-BLK-07", unicode"铸造跳过 from 检查");

        _step("[Step 1] mint, verify Transfer event from==address(0)");
        vm.prank(issuer);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), issuer, 100e18);
        token.mint(100e18);
        assertEq(token.balanceOf(issuer), 100e18);
        _step("  PASS: Transfer(address(0), issuer, 100e18)");

        _logPass();
    }

    // ── ST-BLK-08 ──
    function test_STBLK08_BurnSkipsToCheck() public {
        _logCase("ST-BLK-08", unicode"销毁跳过 to 检查");

        _step("[Step 1] mint then burn, verify Transfer event to==address(0)");
        _issuerMint(100e18);
        vm.prank(issuer);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(issuer, address(0), 50e18);
        token.burn(50e18);
        assertEq(token.balanceOf(issuer), 50e18);
        _step("  PASS: Transfer(issuer, address(0), 50e18)");

        _logPass();
    }

    // ── ST-BLK-09 ──
    function test_STBLK09_AdminCannotManageBlocklist() public {
        _logCase("ST-BLK-09", unicode"admin 不能管理黑名单");

        _step("[Step 1] admin tries blockUsers");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.MissingOpsRole.selector);
        compliance.blockUsers(address(token), addrs);
        _step("  PASS: reverted MissingOpsRole()");

        _logPass();
    }
}
