// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MintBurnQA is BaseQA {
    string constant MODULE = unicode"铸造与销毁";

    // ── ST-MINT-01 ──
    function test_STMINT01_AdminCannotMint() public {
        _logCase("ST-MINT-01", unicode"admin 不能铸造");

        _step("[Step 1] admin calls token.mint(1000e18)");
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.mint(1000e18);
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── ST-MINT-02 ──
    function test_STMINT02_IssuerCanMint() public {
        _logCase("ST-MINT-02", unicode"issuer 可铸造");

        _step("[Step 1] issuer mints 500e18");
        _issuerMint(500e18);
        assertEq(token.balanceOf(issuer), 500e18);
        _step("  PASS: balanceOf(issuer) == 500e18");
        assertEq(token.totalSupply(), 500e18);
        _step("  PASS: totalSupply == 500e18");

        _logPass();
    }

    // ── ST-MINT-03 ──
    function test_STMINT03_OperatorCannotMint() public {
        _logCase("ST-MINT-03", unicode"operator 不能铸造");

        _step("[Step 1] operator calls token.mint(1e18)");
        vm.prank(operator);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.mint(1e18);
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── ST-MINT-04 ──
    function test_STMINT04_UserCannotMint() public {
        _logCase("ST-MINT-04", unicode"普通用户不能铸造");

        _step("[Step 1] userA calls token.mint(1e18)");
        vm.prank(userA);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.mint(1e18);
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── ST-MINT-05 ──
    function test_STMINT05_MintDisabledReverts() public {
        _logCase("ST-MINT-05", unicode"铸造关闭后阻止");

        _step("[Step 1] admin disables minting");
        vm.prank(admin);
        token.setMintEnabled(false);

        _step("[Step 2] issuer tries to mint");
        vm.prank(issuer);
        vm.expectRevert(SecuritiesToken.MintDisabled.selector);
        token.mint(1e18);
        _step("  PASS: reverted MintDisabled()");

        _logPass();
    }

    // ── ST-MINT-06 ──
    function test_STMINT06_MintReenabledWorks() public {
        _logCase("ST-MINT-06", unicode"重新开启后可铸造");

        _step("[Step 1] admin disables then re-enables minting");
        vm.startPrank(admin);
        token.setMintEnabled(false);
        token.setMintEnabled(true);
        vm.stopPrank();

        _step("[Step 2] issuer mints 1e18");
        _issuerMint(1e18);
        assertEq(token.balanceOf(issuer), 1e18);
        _step("  PASS: mint succeeded after re-enable");

        _logPass();
    }

    // ── ST-MINT-07 ──
    function test_STMINT07_AdminCannotBurn() public {
        _logCase("ST-MINT-07", unicode"admin 不能销毁");

        _step("[Step 1] issuer mints 100e18");
        _issuerMint(100e18);

        _step("[Step 2] admin tries to burn");
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.burn(1e18);
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── ST-MINT-08 ──
    function test_STMINT08_IssuerCanBurn() public {
        _logCase("ST-MINT-08", unicode"issuer 可销毁");

        _step("[Step 1] issuer mints 100e18 then burns 50e18");
        _issuerMint(100e18);
        vm.prank(issuer);
        token.burn(50e18);
        assertEq(token.balanceOf(issuer), 50e18);
        _step("  PASS: balanceOf(issuer) == 50e18 after burn");

        _logPass();
    }

    // ── ST-MINT-09 ──
    function test_STMINT09_BurnDisabledReverts() public {
        _logCase("ST-MINT-09", unicode"销毁关闭后阻止");

        _step("[Step 1] issuer mints, admin disables burning");
        _issuerMint(100e18);
        vm.prank(admin);
        token.setBurnEnabled(false);

        _step("[Step 2] issuer tries to burn");
        vm.prank(issuer);
        vm.expectRevert(SecuritiesToken.BurnDisabled.selector);
        token.burn(1e18);
        _step("  PASS: reverted BurnDisabled()");

        _logPass();
    }

    // ── ST-MINT-10 ──
    function test_STMINT10_BurnExceedsBalanceReverts() public {
        _logCase("ST-MINT-10", unicode"销毁超出余额回滚");

        _step("[Step 1] issuer mints 100e18 then tries to burn 200e18");
        _issuerMint(100e18);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, issuer, 100e18, 200e18));
        token.burn(200e18);
        _step("  PASS: reverted (insufficient balance)");

        _logPass();
    }

    // ── ST-MINT-11 ──
    function test_STMINT11_MintReturnsTrue() public {
        _logCase("ST-MINT-11", unicode"mint 返回 true");

        _step("[Step 1] issuer calls token.mint(1e18) and checks return value");
        vm.prank(issuer);
        bool result = token.mint(1e18);
        assertTrue(result);
        _step("  PASS: mint returned true");

        _logPass();
    }

    // ── ST-MINT-12 ──
    function test_STMINT12_BurnReturnsTrue() public {
        _logCase("ST-MINT-12", unicode"burn 返回 true");

        _step("[Step 1] issuer mints then burns, checks return value");
        _issuerMint(100e18);
        vm.prank(issuer);
        bool result = token.burn(1e18);
        assertTrue(result);
        _step("  PASS: burn returned true");

        _logPass();
    }

    // ── ST-MINT-13 ──
    function test_STMINT13_NonAdminCannotToggleMint() public {
        _logCase("ST-MINT-13", unicode"非管理员不能切换 mintEnabled");

        _step("[Step 1] userA tries to setMintEnabled(false)");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userA, DEFAULT_ADMIN_ROLE_HASH));
        token.setMintEnabled(false);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── ST-MINT-14 ──
    function test_STMINT14_NonAdminCannotToggleBurn() public {
        _logCase("ST-MINT-14", unicode"非管理员不能切换 burnEnabled");

        _step("[Step 1] userA tries to setBurnEnabled(false)");
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userA, DEFAULT_ADMIN_ROLE_HASH));
        token.setBurnEnabled(false);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── ST-MINT-15 ──
    function test_STMINT15_MintEmitsTransferEvent() public {
        _logCase("ST-MINT-15", unicode"铸造触发 Transfer 事件");

        _step("[Step 1] issuer mints 100e18, expect Transfer(0, issuer, 100e18)");
        vm.prank(issuer);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), issuer, 100e18);
        token.mint(100e18);
        _step("  PASS: Transfer event emitted correctly");

        _logPass();
    }

    // ── ST-MINT-16 ──
    function test_STMINT16_BurnEmitsTransferEvent() public {
        _logCase("ST-MINT-16", unicode"销毁触发 Transfer 事件");

        _step("[Step 1] issuer mints 100e18");
        _issuerMint(100e18);

        _step("[Step 2] issuer burns 100e18, expect Transfer(issuer, 0, 100e18)");
        vm.prank(issuer);
        vm.expectEmit(true, true, false, true);
        emit Transfer(issuer, address(0), 100e18);
        token.burn(100e18);
        _step("  PASS: Transfer event emitted correctly");

        _logPass();
    }

    // ── ST-MINT-17 ──
    function test_STMINT17_MintOnlyAffectsCaller() public {
        _logCase("ST-MINT-17", unicode"mint 只操作 caller 余额");

        _step("[Step 1] issuer mints 100e18");
        _issuerMint(100e18);

        _step("[Step 2] check issuer and admin balances");
        assertEq(token.balanceOf(issuer), 100e18);
        _step("  PASS: issuer balance increased");
        assertEq(token.balanceOf(admin), 0);
        _step("  PASS: admin balance unchanged at 0");

        _logPass();
    }

    // ERC20 Transfer event declaration for vm.expectEmit
    event Transfer(address indexed from, address indexed to, uint256 value);
}
