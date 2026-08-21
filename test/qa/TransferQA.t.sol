// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TransferQA is BaseQA {
    string constant MODULE = unicode"ERC20 转账";

    event TransferWithUIAmount(address indexed from, address indexed to, uint256 amount, uint256 uiAmount);

    // ── ST-TXF-01 ──
    function test_STTXF01_DirectTransfer() public {
        _logCase("ST-TXF-01", unicode"直接转账正常路径");

        _step("[Step 1] issuer mints 1000e18, transfers 400e18 to userA");
        _issuerMint(1000e18);
        vm.prank(issuer);
        token.transfer(userA, 400e18);

        assertEq(token.balanceOf(issuer), 600e18);
        _step("  PASS: issuer balance == 600e18");
        assertEq(token.balanceOf(userA), 400e18);
        _step("  PASS: userA balance == 400e18");

        _logPass();
    }

    // ── ST-TXF-02 ──
    function test_STTXF02_UserToUserTransfer() public {
        _logCase("ST-TXF-02", unicode"用户间转账");

        _step("[Step 1] mint 400e18 to userA via issuer");
        _issuerMint(400e18);
        vm.prank(issuer);
        token.transfer(userA, 400e18);

        _step("[Step 2] userA transfers 150e18 to userB");
        vm.prank(userA);
        token.transfer(userB, 150e18);

        assertEq(token.balanceOf(userA), 250e18);
        _step("  PASS: userA balance == 250e18");
        assertEq(token.balanceOf(userB), 150e18);
        _step("  PASS: userB balance == 150e18");

        _logPass();
    }

    // ── ST-TXF-03 ──
    function test_STTXF03_TransferZeroAmount() public {
        _logCase("ST-TXF-03", unicode"转账零金额");

        _step("[Step 1] issuer mints 100e18");
        _issuerMint(100e18);

        _step("[Step 2] issuer transfers 0 to userA");
        vm.prank(issuer);
        token.transfer(userA, 0);

        assertEq(token.balanceOf(issuer), 100e18);
        _step("  PASS: issuer balance unchanged");
        assertEq(token.balanceOf(userA), 0);
        _step("  PASS: userA balance still 0");

        _logPass();
    }

    // ── ST-TXF-04 ──
    function test_STTXF04_TransferExceedsBalanceReverts() public {
        _logCase("ST-TXF-04", unicode"超额转账回滚");

        _step("[Step 1] mint 100e18 to userA");
        _mintAndTransfer(userA, 100e18);

        _step("[Step 2] userA tries to transfer 200e18 to userB");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, userA, 100e18, 200e18));
        token.transfer(userB, 200e18);
        _step("  PASS: reverted (insufficient balance)");

        _logPass();
    }

    // ── ST-TXF-05 ──
    function test_STTXF05_ApproveAndTransferFrom() public {
        _logCase("ST-TXF-05", unicode"approve + transferFrom");

        _step("[Step 1] mint 500e18 to userA");
        _mintAndTransfer(userA, 500e18);

        _step("[Step 2] userA approves userB for 200e18");
        vm.prank(userA);
        token.approve(userB, 200e18);

        _step("[Step 3] userB calls transferFrom(userA, userB, 200e18)");
        vm.prank(userB);
        token.transferFrom(userA, userB, 200e18);

        assertEq(token.balanceOf(userA), 300e18);
        _step("  PASS: userA balance == 300e18");
        assertEq(token.balanceOf(userB), 200e18);
        _step("  PASS: userB balance == 200e18");
        assertEq(token.allowance(userA, userB), 0);
        _step("  PASS: allowance == 0");

        _logPass();
    }

    // ── ST-TXF-06 ──
    function test_STTXF06_TransferFromWithoutApprovalReverts() public {
        _logCase("ST-TXF-06", unicode"未授权 transferFrom 回滚");

        _step("[Step 1] mint 100e18 to userA, no approval for userB");
        _mintAndTransfer(userA, 100e18);

        _step("[Step 2] userB calls transferFrom(userA, userB, 50e18)");
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, userB, 0, 50e18));
        token.transferFrom(userA, userB, 50e18);
        _step("  PASS: reverted (insufficient allowance)");

        _logPass();
    }

    // ── ST-TXF-07 ──
    function test_STTXF07_TransferFromExceedsAllowanceReverts() public {
        _logCase("ST-TXF-07", unicode"transferFrom 超额授权回滚");

        _step("[Step 1] mint 500e18 to userA, approve userB for 100e18");
        _mintAndTransfer(userA, 500e18);
        vm.prank(userA);
        token.approve(userB, 100e18);

        _step("[Step 2] userB tries transferFrom 200e18");
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, userB, 100e18, 200e18));
        token.transferFrom(userA, userB, 200e18);
        _step("  PASS: reverted (insufficient allowance)");

        _logPass();
    }

    // ── ST-TXF-08 ──
    function test_STTXF08_SelfTransfer() public {
        _logCase("ST-TXF-08", unicode"自转账（A→A）");

        _step("[Step 1] mint 100e18 to userA");
        _mintAndTransfer(userA, 100e18);

        _step("[Step 2] userA transfers 50e18 to self");
        vm.prank(userA);
        token.transfer(userA, 50e18);

        assertEq(token.balanceOf(userA), 100e18);
        _step("  PASS: balance unchanged at 100e18");

        _logPass();
    }

    // ── ST-TXF-09 ──
    function test_STTXF09_TransferEmitsUIAmountEvent() public {
        _logCase("ST-TXF-09", unicode"转账触发 TransferWithUIAmount");

        _step("[Step 1] set multiplier to 2e18 and activate");
        vm.prank(operator);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours);

        _step("[Step 2] mint 100e18 to userA");
        _mintAndTransfer(userA, 100e18);

        _step("[Step 3] userA transfers 100e18, expect TransferWithUIAmount uiAmount==200e18");
        vm.prank(userA);
        vm.expectEmit(true, true, false, true);
        emit TransferWithUIAmount(userA, userB, 100e18, 200e18);
        token.transfer(userB, 100e18);
        _step("  PASS: TransferWithUIAmount emitted with uiAmount==200e18");

        _logPass();
    }

    // ── ST-TXF-10 ──
    function test_STTXF10_UnlimitedApprovalNotDecremented() public {
        _logCase("ST-TXF-10", unicode"无限授权不扣减 allowance");

        _step("[Step 1] mint 500e18 to userA");
        _mintAndTransfer(userA, 500e18);

        _step("[Step 2] userA approves userB for type(uint256).max");
        vm.prank(userA);
        token.approve(userB, type(uint256).max);

        _step("[Step 3] userB transferFrom 100e18");
        vm.prank(userB);
        token.transferFrom(userA, userB, 100e18);

        assertEq(token.allowance(userA, userB), type(uint256).max);
        _step("  PASS: allowance still type(uint256).max");

        _logPass();
    }
}
