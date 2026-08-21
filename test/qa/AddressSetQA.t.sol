// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {PauseGuardUpgradeable} from "../../src/pauseRegistry/PauseGuardUpgradeable.sol";
import {ComplianceGuardUpgradeable} from "../../src/complianceRegistry/ComplianceGuardUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract AddressSetQA is BaseQA {
    string constant MODULE = unicode"地址管理";

    // ── ST-SET-01 ──
    function test_STSET01_AdminSetNewCompliance() public {
        _logCase("ST-SET-01", unicode"admin 设新 compliance");

        _step("[Step 1] deploy new ComplianceRegistry, updateCompliance on token");
        ComplianceRegistry newC = new ComplianceRegistry(admin);
        vm.prank(admin);
        token.updateCompliance(address(newC));

        _step("[Step 2] query compliance(), verify updated");
        assertEq(address(token.compliance()), address(newC));
        _step("  PASS: compliance() == newC");

        _logPass();
    }

    // ── ST-SET-02 ──
    function test_STSET02_AdminSetNewPauseManager() public {
        _logCase("ST-SET-02", unicode"admin 设新 pauseManager");

        _step("[Step 1] deploy new PauseRegistry, updatePauseManager on token");
        PauseRegistry newPM = new PauseRegistry(admin);
        vm.prank(admin);
        token.updatePauseManager(address(newPM));

        _step("[Step 2] query pauseManager(), verify updated");
        assertEq(address(token.pauseManager()), address(newPM));
        _step("  PASS: pauseManager() == newPM");

        _logPass();
    }

    // ── ST-SET-03 ──
    function test_STSET03_NonAdminCannotSetCompliance() public {
        _logCase("ST-SET-03", unicode"非 admin 不能设 compliance");

        _step("[Step 1] stranger tries setDefaultCompliance");
        ComplianceRegistry newC = new ComplianceRegistry(admin);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE_HASH));
        token.updateCompliance(address(newC));
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── ST-SET-04 ──
    function test_STSET04_NonAdminCannotSetPauseManager() public {
        _logCase("ST-SET-04", unicode"非 admin 不能设 pauseManager");

        _step("[Step 1] stranger tries setDefaultPauseManager");
        PauseRegistry newPM = new PauseRegistry(admin);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE_HASH));
        token.updatePauseManager(address(newPM));
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── ST-SET-05 ──
    function test_STSET05_ZeroComplianceReverts() public {
        _logCase("ST-SET-05", unicode"零地址 compliance 回滚");

        _step("[Step 1] setDefaultCompliance(address(0))");
        vm.prank(admin);
        vm.expectRevert(ComplianceGuardUpgradeable.ComplianceZeroAddress.selector);
        token.updateCompliance(address(0));
        _step("  PASS: reverted ComplianceCantBeZero()");

        _logPass();
    }

    // ── ST-SET-06 ──
    function test_STSET06_ZeroPauseManagerReverts() public {
        _logCase("ST-SET-06", unicode"零地址 pauseManager 回滚");

        _step("[Step 1] updatePauseManager(address(0))");
        vm.prank(admin);
        vm.expectRevert(PauseGuardUpgradeable.PauseManagerCantBeZero.selector);
        token.updatePauseManager(address(0));
        _step("  PASS: reverted PauseManagerCantBeZero()");

        _logPass();
    }

    // ── ST-SET-07 ──
    function test_STSET07_EOAComplianceReverts() public {
        _logCase("ST-SET-07", unicode"EOA 作为 compliance 回滚");

        _step("[Step 1] updateCompliance(EOA address)");
        vm.prank(admin);
        vm.expectRevert(ComplianceGuardUpgradeable.InvalidComplianceContract.selector);
        token.updateCompliance(makeAddr("someEOA"));
        _step("  PASS: reverted InvalidComplianceContract()");

        _logPass();
    }

    // ── ST-SET-08 ──
    function test_STSET08_EOAPauseManagerReverts() public {
        _logCase("ST-SET-08", unicode"EOA 作为 pauseManager 回滚");

        _step("[Step 1] updatePauseManager(EOA address)");
        vm.prank(admin);
        vm.expectRevert(PauseGuardUpgradeable.InvalidPauseManagerContract.selector);
        token.updatePauseManager(makeAddr("someEOA"));
        _step("  PASS: reverted InvalidPauseManagerContract()");

        _logPass();
    }
}
