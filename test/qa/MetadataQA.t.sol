// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MetadataQA is BaseQA {
    string constant MODULE = unicode"元数据管理";

    event NameChanged(string oldName, string newName);
    event SymbolChanged(string oldSymbol, string newSymbol);
    event IdentifierChanged(string oldIdentifier, string newIdentifier);

    // ── META-01 ──
    function test_META01_AdminChangeName() public {
        _logCase("META-01", unicode"admin 改名称");

        _step("[Step 1] admin calls setName('New Name')");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit NameChanged("Apple Inc.", "New Name");
        token.setName("New Name");
        assertEq(token.name(), "New Name");
        _step("  PASS: name updated, NameChanged emitted");

        _logPass();
    }

    // ── META-02 ──
    function test_META02_AdminChangeSymbol() public {
        _logCase("META-02", unicode"admin 改符号");

        _step("[Step 1] admin calls setSymbol('NEW')");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit SymbolChanged("AAPL", "NEW");
        token.setSymbol("NEW");
        assertEq(token.symbol(), "NEW");
        _step("  PASS: symbol updated, SymbolChanged emitted");

        _logPass();
    }

    // ── META-03 ──
    function test_META03_AdminChangeIdentifier() public {
        _logCase("META-03", unicode"admin 改标识符");

        _step("[Step 1] admin calls setIdentifier('NEWID')");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit IdentifierChanged("US0378331005", "NEWID");
        token.setIdentifier("NEWID");
        assertEq(token.identifier(), "NEWID");
        _step("  PASS: identifier updated, IdentifierChanged emitted");

        _logPass();
    }

    // ── META-04 ──
    function test_META04_EmptyNameReverts() public {
        _logCase("META-04", unicode"空名称回滚");

        _step("[Step 1] admin calls setName('')");
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.EmptyString.selector);
        token.setName("");
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── META-05 ──
    function test_META05_EmptySymbolReverts() public {
        _logCase("META-05", unicode"空符号回滚");

        _step("[Step 1] admin calls setSymbol('')");
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.EmptyString.selector);
        token.setSymbol("");
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── META-06 ──
    function test_META06_EmptyIdentifierReverts() public {
        _logCase("META-06", unicode"空标识符回滚");

        _step("[Step 1] admin calls setIdentifier('')");
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.EmptyString.selector);
        token.setIdentifier("");
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── META-07 ──
    function test_META07_NonAdminCannotChangeName() public {
        _logCase("META-07", unicode"非 admin 不能改名称");

        _step("[Step 1] stranger tries setName");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE_HASH));
        token.setName("Hacked");
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── META-08 ──
    function test_META08_IssuerCannotChangeName() public {
        _logCase("META-08", unicode"issuer 不能改名称");

        _step("[Step 1] issuer tries setName");
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, DEFAULT_ADMIN_ROLE_HASH));
        token.setName("Hacked");
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── META-09 ──
    function test_META09_OperatorCannotChangeName() public {
        _logCase("META-09", unicode"operator 不能改名称");

        _step("[Step 1] operator tries setName");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, DEFAULT_ADMIN_ROLE_HASH));
        token.setName("Hacked");
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }
}
