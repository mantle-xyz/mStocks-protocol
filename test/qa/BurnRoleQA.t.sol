// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";

/// @dev Minimal contract that can hold BURN_ROLE (code.length > 0).
contract Burner {
    function doBurn(ScaledToken t, uint256 amount) external {
        t.burn(amount);
    }

    function doMint(ScaledToken t, uint256 amount) external {
        t.mint(amount);
    }
}

contract BurnRoleQA is BaseQA {
    string constant MODULE = unicode"ScaledToken BURN_ROLE";

    Burner internal burner;
    bytes32 internal BURN_ROLE;

    function setUp() public override {
        super.setUp();
        BURN_ROLE = token.BURN_ROLE();
        burner = new Burner();
        vm.prank(admin);
        token.grantRole(BURN_ROLE, address(burner));
    }

    // ── BURN-01 ──
    function test_BURN01_BurnRoleCanBurnNotMint() public {
        _logCase("BURN-01", unicode"BURN_ROLE 可 burn 不可 mint");

        _step("[Step 1] mint tokens and transfer to burner");
        _mintAndTransfer(address(burner), 100e18);
        assertEq(token.balanceOf(address(burner)), 100e18);

        _step("[Step 2] burner burns via BURN_ROLE - should succeed");
        burner.doBurn(token, 50e18);
        assertEq(token.balanceOf(address(burner)), 50e18);
        _step("  burn succeeded");

        _step("[Step 3] burner tries to mint - should revert UnauthorizedRole");
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        burner.doMint(token, 1e18);
        _step("  PASS: BURN_ROLE can burn but cannot mint");

        _logPass();
    }

    // ── BURN-02 ──
    function test_BURN02_IssuerRoleCanMintAndBurn() public {
        _logCase("BURN-02", unicode"ISSUER_ROLE 仍可 mint + burn（回归）");

        _step("[Step 1] issuer mints via ISSUER_ROLE");
        vm.prank(walletOps);
        vault.mint(address(token), hotWallet1, 100e18);
        assertEq(token.balanceOf(hotWallet1), 100e18);

        _step("[Step 2] issuer burns via ISSUER_ROLE");
        vm.prank(hotWallet1);
        token.approve(address(vault), 100e18);
        vm.prank(walletOps);
        vault.burn(address(token), hotWallet1, 40e18);
        assertEq(token.balanceOf(hotWallet1), 60e18);
        _step("  PASS: ISSUER_ROLE mint + burn both work (additive, not replaced)");

        _logPass();
    }

    // ── BURN-03 ──
    function test_BURN03_BurnRoleToEOAReverts() public {
        _logCase("BURN-03", unicode"BURN_ROLE 不能授予 EOA");

        _step("[Step 1] admin tries grantRole(BURN_ROLE, EOA)");
        vm.prank(admin);
        vm.expectRevert(ScaledToken.IssuerNotContract.selector);
        token.grantRole(BURN_ROLE, userA);
        _step("  PASS: revert IssuerNotContract");

        _logPass();
    }

    // ── BURN-04 ──
    function test_BURN04_BurnAllowedFalseBlocksBurnRole() public {
        _logCase("BURN-04", unicode"burnAllowed=false 时 BURN_ROLE 也不能 burn");

        _step("[Step 1] mint tokens to burner");
        _mintAndTransfer(address(burner), 100e18);

        _step("[Step 2] tokenOps sets burnAllowed=false");
        vm.prank(tokenOps);
        token.setBurnAllowed(false);

        _step("[Step 3] burner tries to burn - should revert BurnNotAllowed");
        vm.expectRevert(ScaledToken.BurnNotAllowed.selector);
        burner.doBurn(token, 10e18);
        _step("  PASS: BurnNotAllowed even with BURN_ROLE");

        _logPass();
    }

    // ── BURN-05 ──
    function test_BURN05_RevokeBurnRoleCantBurn() public {
        _logCase("BURN-05", unicode"revoke BURN_ROLE 后不能 burn");

        _step("[Step 1] mint tokens to burner");
        _mintAndTransfer(address(burner), 100e18);

        _step("[Step 2] admin revokes BURN_ROLE from burner");
        vm.prank(admin);
        token.revokeRole(BURN_ROLE, address(burner));
        assertFalse(token.hasRole(BURN_ROLE, address(burner)));

        _step("[Step 3] burner tries to burn - should revert UnauthorizedRole");
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        burner.doBurn(token, 10e18);
        _step("  PASS: revoked BURN_ROLE cannot burn");

        _logPass();
    }

    // ── BURN-06 ──
    function test_BURN06_IssuerRoleToEOAReverts() public {
        _logCase("BURN-06", unicode"ISSUER_ROLE 授 EOA 回归 revert");

        _step("[Step 1] admin tries grantRole(ISSUER_ROLE, EOA)");
        vm.prank(admin);
        vm.expectRevert(ScaledToken.IssuerNotContract.selector);
        token.grantRole(ISSUER_ROLE, userA);
        _step("  PASS: revert IssuerNotContract (regression - ISSUER_ROLE same guard)");

        _logPass();
    }
}
