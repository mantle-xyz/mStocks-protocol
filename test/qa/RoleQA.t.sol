// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {PauseManager} from "../../src/pauseManager/PauseManager.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {OperatorWallet} from "../../src/OperatorWallet/OperatorWallet.sol";

contract RoleQA is BaseQA {
    string constant MODULE = unicode"角色管理";

    // ═══════════════════════════════════════════════
    //      A.11 角色管理 [P0]
    // ═══════════════════════════════════════════════

    // ── AC-ROLE-01 ──
    function test_ACROLE01_GrantIssuerThenMint() public {
        _logCase("AC-ROLE-01", unicode"grant ISSUER → mint");

        _step("[Step 1] deploy OperatorWallet, grant ISSUER_ROLE");
        address newIssuer = address(new OperatorWallet());
        vm.prank(admin);
        token.grantRole(ISSUER_ROLE, newIssuer);
        assertTrue(token.hasRole(ISSUER_ROLE, newIssuer));
        _step("  PASS: newIssuer has ISSUER_ROLE");

        _step("[Step 2] newIssuer mints 100e18");
        vm.prank(newIssuer);
        token.mint(100e18);
        assertEq(token.balanceOf(newIssuer), 100e18);
        _step("  PASS: mint succeeded, balanceOf == 100e18");

        _logPass();
    }

    // ── AC-ROLE-02 ──
    function test_ACROLE02_GrantOpsThenMultiplier() public {
        _logCase("AC-ROLE-02", unicode"grant OPS → setUIMultiplier");

        _step("[Step 1] grant OPS_ROLE to userA, then call setUIMultiplier");
        vm.prank(admin);
        token.grantRole(OPS_ROLE, userA);

        vm.prank(userA);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _step("  PASS: setUIMultiplier succeeded with new OPS_ROLE holder");

        _logPass();
    }

    // ── AC-ROLE-03 ──
    function test_ACROLE03_RevokeRoleBlocksMint() public {
        _logCase("AC-ROLE-03", unicode"revokeRole 后失效");

        _step("[Step 1] deploy OperatorWallet, grant then revoke ISSUER_ROLE");
        address newIssuer = address(new OperatorWallet());
        vm.startPrank(admin);
        token.grantRole(ISSUER_ROLE, newIssuer);
        token.revokeRole(ISSUER_ROLE, newIssuer);
        vm.stopPrank();

        _step("[Step 2] newIssuer tries to mint");
        vm.prank(newIssuer);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.mint(1e18);
        _step("  PASS: reverted UnauthorizedRole() after revoke");

        _logPass();
    }

    // ── AC-ROLE-04 ──
    function test_ACROLE04_NonAdminCannotGrant() public {
        _logCase("AC-ROLE-04", unicode"非 admin 无权 grant");

        _step("[Step 1] stranger tries grantRole");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE_HASH));
        token.grantRole(OPS_ROLE, userA);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── AC-ROLE-05 ──
    function test_ACROLE05_IssuerCannotGrant() public {
        _logCase("AC-ROLE-05", unicode"issuer 无权 grant");

        _step("[Step 1] issuer tries grantRole");
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, DEFAULT_ADMIN_ROLE_HASH));
        token.grantRole(OPS_ROLE, userA);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── AC-ROLE-06 ──
    function test_ACROLE06_GetRoleAdminCorrect() public {
        _logCase("AC-ROLE-06", unicode"getRoleAdmin 正确");

        _step("[Step 1] query getRoleAdmin for ISSUER_ROLE and OPS_ROLE");
        assertEq(token.getRoleAdmin(ISSUER_ROLE), DEFAULT_ADMIN_ROLE_HASH);
        _step("  PASS: ISSUER_ROLE admin == DEFAULT_ADMIN_ROLE");
        assertEq(token.getRoleAdmin(OPS_ROLE), DEFAULT_ADMIN_ROLE_HASH);
        _step("  PASS: OPS_ROLE admin == DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.12 角色枚举 [P2]
    // ═══════════════════════════════════════════════

    // ── AC-ENUM-01 ──
    function test_ACENUM01_InitialCount() public {
        _logCase("AC-ENUM-01", unicode"初始计数");

        _step("[Step 1] getRoleMemberCount(ISSUER_ROLE)");
        // setUp grants ISSUER_ROLE to wallet (issuer)
        uint256 count = token.getRoleMemberCount(ISSUER_ROLE);
        assertEq(count, 1);
        _step("  PASS: ISSUER_ROLE member count == 1 (wallet)");

        _logPass();
    }

    // ── AC-ENUM-02 ──
    function test_ACENUM02_GrantIncreasesCount() public {
        _logCase("AC-ENUM-02", unicode"授予后增加");

        _step("[Step 1] grant ISSUER_ROLE to new contract");
        address newIssuer = address(new OperatorWallet());
        vm.prank(admin);
        token.grantRole(ISSUER_ROLE, newIssuer);

        uint256 count = token.getRoleMemberCount(ISSUER_ROLE);
        assertEq(count, 2);
        _step("  PASS: count == 2");

        _logPass();
    }

    // ── AC-ENUM-03 ──
    function test_ACENUM03_RevokeDecreasesCount() public {
        _logCase("AC-ENUM-03", unicode"撤销后减少");

        _step("[Step 1] grant then revoke");
        address newIssuer = address(new OperatorWallet());
        vm.startPrank(admin);
        token.grantRole(ISSUER_ROLE, newIssuer);
        token.revokeRole(ISSUER_ROLE, newIssuer);
        vm.stopPrank();

        uint256 count = token.getRoleMemberCount(ISSUER_ROLE);
        assertEq(count, 1);
        _step("  PASS: count back to 1");

        _logPass();
    }

    // ── AC-ENUM-04 ──
    function test_ACENUM04_GetMemberCorrect() public {
        _logCase("AC-ENUM-04", unicode"getMember 正确");

        _step("[Step 1] getRoleMember(ISSUER_ROLE, 0)");
        address member0 = token.getRoleMember(ISSUER_ROLE, 0);
        assertEq(member0, address(wallet));
        _step("  PASS: wallet is the sole ISSUER_ROLE member");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      A.13 Self-grant 守卫 [P0]
    // ═══════════════════════════════════════════════

    // ── AC-SELF-01 ──
    function test_ACSELF01_TokenAdminCannotSelfGrantIssuer() public {
        _logCase("AC-SELF-01", unicode"token: admin→自己 ISSUER");

        _step("[Step 1] admin tries grantRole(ISSUER_ROLE, admin)");
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.SelfGrantNotAllowed.selector);
        token.grantRole(ISSUER_ROLE, admin);
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── AC-SELF-02 ──
    function test_ACSELF02_TokenAdminCannotSelfGrantOps() public {
        _logCase("AC-SELF-02", unicode"token: admin→自己 OPS");

        _step("[Step 1] admin tries grantRole(OPS_ROLE, admin)");
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.SelfGrantNotAllowed.selector);
        token.grantRole(OPS_ROLE, admin);
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── AC-SELF-03 ──
    function test_ACSELF03_ComplianceAdminCannotSelfGrant() public {
        _logCase("AC-SELF-03", unicode"compliance: admin→自己 OPS");

        _step("[Step 1] admin tries compliance.grantRole(OPS, admin)");
        vm.prank(admin);
        vm.expectRevert(Compliance.SelfGrantNotAllowed.selector);
        compliance.grantRole(COMPLIANCE_OPS_ROLE, admin);
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── AC-SELF-04 ──
    function test_ACSELF04_PauseManagerAdminCannotSelfGrant() public {
        _logCase("AC-SELF-04", unicode"pauseManager: admin→自己 OPS");

        _step("[Step 1] admin tries pauseManager.grantRole(OPS, admin)");
        vm.prank(admin);
        vm.expectRevert(PauseManager.SelfGrantNotAllowed.selector);
        pauseManager.grantRole(PAUSE_MANAGER_OPS_ROLE, admin);
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── AC-SELF-05 ──
    function test_ACSELF05_ConstructorGrantNotRestricted() public {
        _logCase("AC-SELF-05", unicode"构造时 _grantRole 不受限");

        _step("[Step 1] check admin has DEFAULT_ADMIN_ROLE (set in constructor)");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE (internal _grantRole bypasses guard)");

        _logPass();
    }

    // ── AC-SELF-06 ──
    function test_ACSELF06_RenounceNotRestricted() public {
        _logCase("AC-SELF-06", unicode"renounce 不受限");

        _step("[Step 1] admin renounces DEFAULT_ADMIN_ROLE");
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        _step("  PASS: renounceRole succeeded");

        _logPass();
    }

    // ── AC-SELF-07 ──
    function test_ACSELF07_WalletAdminCannotSelfGrant() public {
        _logCase("AC-SELF-07", unicode"operatorWallet: admin→自己 OPS");

        _step("[Step 1] admin tries wallet.grantRole(OPS_ROLE, admin)");
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.SelfGrantNotAllowed.selector);
        wallet.grantRole(WALLET_OPS_ROLE, admin);
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── AC-SELF-08 ──
    function test_ACSELF08_WalletAdminCanGrantToOthers() public {
        _logCase("AC-SELF-08", unicode"operatorWallet: admin→他人 OPS");

        _step("[Step 1] admin grants OPS_ROLE to userA on wallet");
        address newOps = makeAddr("newOps");
        vm.prank(admin);
        wallet.grantRole(WALLET_OPS_ROLE, newOps);
        assertTrue(wallet.hasRole(WALLET_OPS_ROLE, newOps));
        _step("  PASS: newOps has OPS_ROLE on wallet");

        _logPass();
    }
}
