// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";

contract QATransfer is BaseQAScript {
    function run() external {
        _loadEnv();

        test_TXF01();
        test_TXF02();
        test_TXF03();
        test_TXF04();
        test_TXF05();
        test_TXF06();
    }

    // ── QA-TXF-01: 热钱包分发代币给用户 ──
    function test_TXF01() public {
        _logCase("QA-TXF-01", unicode"热钱包分发代币给用户");

        _step("[Step 1] preconditions");
        _requireNotPaused();

        _step("[Step 2] mint 1000e18 to hotWallet");
        uint256 supplyBefore = token.totalSupply();
        _mintToHotWallet(1000e18);

        _step("[Step 3] hotWallet transfers 400e18 to userA");
        uint256 hotBefore = token.balanceOf(hotWallet);
        uint256 userABefore = token.balanceOf(userA);

        vm.broadcast(hotWalletPk);
        token.transfer(userA, 400e18);

        _assertDiff(hotBefore, token.balanceOf(hotWallet), -400e18, "hotWallet diff");
        _step("  PASS: hotWallet -400e18");

        _assertDiff(userABefore, token.balanceOf(userA), 400e18, "userA diff");
        _step("  PASS: userA +400e18");

        _assertEq(token.totalSupply(), supplyBefore + 1000e18, "totalSupply only changed by mint");
        _step("  PASS: totalSupply unchanged by transfer");

        _logPass();
    }

    // ── QA-TXF-02: 用户间二级转账 ──
    function test_TXF02() public {
        _logCase("QA-TXF-02", unicode"用户间二级转账");

        _step("[Step 1] preconditions + distribute to userA");
        _requireNotPaused();
        _mintAndDistribute(userA, 400e18);

        _step("[Step 2] userA transfers 100e18 to userB");
        uint256 aBefore = token.balanceOf(userA);
        uint256 bBefore = token.balanceOf(userB);

        vm.broadcast(userAPk);
        token.transfer(userB, 100e18);

        _assertDiff(aBefore, token.balanceOf(userA), -100e18, "userA diff");
        _step("  PASS: userA -100e18");

        _assertDiff(bBefore, token.balanceOf(userB), 100e18, "userB diff");
        _step("  PASS: userB +100e18");

        _logPass();
    }

    // ── QA-TXF-03: 授权代扣 ──
    function test_TXF03() public {
        _logCase("QA-TXF-03", unicode"授权代扣 approve + transferFrom");

        _step("[Step 1] preconditions + distribute 500e18 to userA");
        _requireNotPaused();
        _mintAndDistribute(userA, 500e18);

        _step("[Step 2] userA approves userB for 200e18");
        vm.broadcast(userAPk);
        token.approve(userB, 200e18);
        _assertEq(token.allowance(userA, userB), 200e18, "allowance");
        _step("  PASS: allowance set to 200e18");

        _step("[Step 3] userB calls transferFrom");
        uint256 aBefore = token.balanceOf(userA);
        uint256 bBefore = token.balanceOf(userB);

        vm.broadcast(userBPk);
        token.transferFrom(userA, userB, 200e18);

        _assertDiff(aBefore, token.balanceOf(userA), -200e18, "userA diff");
        _step("  PASS: userA -200e18");

        _assertDiff(bBefore, token.balanceOf(userB), 200e18, "userB diff");
        _step("  PASS: userB +200e18");

        _assertEq(token.allowance(userA, userB), 0, "allowance consumed");
        _step("  PASS: allowance == 0");

        _logPass();
    }

    // ── QA-TXF-04: 自转账 ──
    function test_TXF04() public {
        _logCase("QA-TXF-04", unicode"自转账 A->A");

        _step("[Step 1] preconditions + distribute to userA");
        _requireNotPaused();
        _mintAndDistribute(userA, 100e18);
        uint256 aBefore = token.balanceOf(userA);
        _assertGt(aBefore, 0, "userA has balance");

        _step("[Step 2] userA transfers 50e18 to self");
        vm.broadcast(userAPk);
        token.transfer(userA, 50e18);

        _assertEq(token.balanceOf(userA), aBefore, "balance unchanged");
        _step("  PASS: balance unchanged after self-transfer");

        _logPass();
    }

    // ── QA-TXF-05: 超额转账回滚 ──
    function test_TXF05() public {
        _logCase("QA-TXF-05", unicode"超额转账回滚");

        _step("[Step 1] precondition: get userA balance");
        uint256 balance = token.balanceOf(userA);
        uint256 overAmount = balance + 1e18;
        _step(string.concat("  userA balance: ", vm.toString(balance), ", attempt: ", vm.toString(overAmount)));

        _step("[Step 2] userA tries transfer more than balance");
        _expectRevertFrom(
            userA,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userB, overAmount),
            // ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)
            bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)"))
        );
        _step("  PASS: reverted ERC20InsufficientBalance");

        _logPass();
    }

    // ── QA-TXF-06: 关闭 mint 不影响二级流通 ──
    function test_TXF06() public {
        _logCase("QA-TXF-06", unicode"关闭 mint 不影响二级流通");

        _step("[Step 1] preconditions + distribute to userA before disabling mint");
        _requireNotPaused();
        _mintAndDistribute(userA, 100e18);

        _step("[Step 2] admin disables mint");
        vm.broadcast(adminPk);
        token.setMintEnabled(false);
        _assertEq(token.mintEnabled(), false, "mintEnabled disabled");

        _step("[Step 3] userA transfers 50e18 to userB");
        uint256 aBefore = token.balanceOf(userA);
        uint256 bBefore = token.balanceOf(userB);

        vm.broadcast(userAPk);
        token.transfer(userB, 50e18);

        _assertDiff(aBefore, token.balanceOf(userA), -50e18, "userA diff");
        _assertDiff(bBefore, token.balanceOf(userB), 50e18, "userB diff");
        _step("  PASS: transfer succeeded with mint disabled");

        _step("[Step 4] cleanup: re-enable mint");
        vm.broadcast(adminPk);
        token.setMintEnabled(true);
        _assertEq(token.mintEnabled(), true, "mintEnabled restored");
        _step("  PASS: mintEnabled restored");

        _logPass();
    }
}
