// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";

contract RenounceQA is BaseQA {
    string constant MODULE = unicode"CannotRenounceLastAdmin 守卫";

    // ═══════════════════════════════════════════════
    //      ScaledToken
    // ═══════════════════════════════════════════════

    // ── RN-TOKEN-01 ──
    function test_RNTOKEN01_LastAdminCannotRenounce() public {
        _logCase("RN-TOKEN-01", unicode"ScaledToken: 唯一 admin 不能 renounce");

        _step("[Step 1] admin renounces DEFAULT_ADMIN_ROLE (sole admin)");
        vm.prank(admin);
        vm.expectRevert(ScaledToken.CannotRenounceLastAdmin.selector);
        token.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── RN-TOKEN-02 ──
    function test_RNTOKEN02_NonLastAdminCanRenounce() public {
        _logCase("RN-TOKEN-02", unicode"ScaledToken: 有 2 admin 时可 renounce");

        _step("[Step 1] grant second admin, then first admin renounces");
        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE_HASH, userA));
        _step("  PASS: renounce succeeded, userA is sole admin");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      ComplianceRegistry
    // ═══════════════════════════════════════════════

    // ── RN-COMP-01 ──
    function test_RNCOMP01_LastAdminCannotRenounce() public {
        _logCase("RN-COMP-01", unicode"ComplianceRegistry: 唯一 admin 不能 renounce");

        _step("[Step 1] admin renounces");
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.CannotRenounceLastAdmin.selector);
        compliance.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── RN-COMP-02 ──
    function test_RNCOMP02_NonLastAdminCanRenounce() public {
        _logCase("RN-COMP-02", unicode"ComplianceRegistry: 有 2 admin 时可 renounce");

        _step("[Step 1] grant second admin, then first admin renounces");
        vm.startPrank(admin);
        compliance.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        compliance.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        vm.stopPrank();
        assertFalse(compliance.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        _step("  PASS: renounce succeeded");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      PauseRegistry
    // ═══════════════════════════════════════════════

    // ── RN-PAUSE-01 ──
    function test_RNPAUSE01_LastAdminCannotRenounce() public {
        _logCase("RN-PAUSE-01", unicode"PauseRegistry: 唯一 admin 不能 renounce");

        _step("[Step 1] admin renounces");
        vm.prank(admin);
        vm.expectRevert(PauseRegistry.CannotRenounceLastAdmin.selector);
        pauseManager.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── RN-PAUSE-02 ──
    function test_RNPAUSE02_NonLastAdminCanRenounce() public {
        _logCase("RN-PAUSE-02", unicode"PauseRegistry: 有 2 admin 时可 renounce");

        _step("[Step 1] grant second admin, then first admin renounces");
        vm.startPrank(admin);
        pauseManager.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        pauseManager.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        vm.stopPrank();
        assertFalse(pauseManager.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        _step("  PASS: renounce succeeded");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      TokenIssuer
    // ═══════════════════════════════════════════════

    // ── RN-ISSUER-01 ──
    function test_RNISSUER01_LastAdminCannotRenounce() public {
        _logCase("RN-ISSUER-01", unicode"TokenIssuer: 唯一 admin 不能 renounce");

        _step("[Step 1] admin renounces");
        vm.prank(admin);
        vm.expectRevert(TokenIssuer.CannotRenounceLastAdmin.selector);
        vault.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── RN-ISSUER-02 ──
    function test_RNISSUER02_NonLastAdminCanRenounce() public {
        _logCase("RN-ISSUER-02", unicode"TokenIssuer: 有 2 admin 时可 renounce");

        _step("[Step 1] grant second admin, then first admin renounces");
        vm.startPrank(admin);
        vault.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        vault.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        vm.stopPrank();
        assertFalse(vault.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        _step("  PASS: renounce succeeded");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      ScaledTokenFactory
    // ═══════════════════════════════════════════════

    // ── RN-FACTORY-01 ──
    function test_RNFACTORY01_LastAdminCannotRenounce() public {
        _logCase("RN-FACTORY-01", unicode"ScaledTokenFactory: 唯一 admin 不能 renounce");

        _step("[Step 1] admin renounces");
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.CannotRenounceLastAdmin.selector);
        factory.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── RN-FACTORY-02 ──
    function test_RNFACTORY02_NonLastAdminCanRenounce() public {
        _logCase("RN-FACTORY-02", unicode"ScaledTokenFactory: 有 2 admin 时可 renounce");

        _step("[Step 1] grant second admin, then first admin renounces");
        vm.startPrank(admin);
        factory.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        factory.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        vm.stopPrank();
        assertFalse(factory.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        _step("  PASS: renounce succeeded");

        _logPass();
    }
}
