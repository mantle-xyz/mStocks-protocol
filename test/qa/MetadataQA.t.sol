// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract MetadataQA is BaseQA {
    string constant MODULE = unicode"元数据管理";

    event NameUpdated(string oldName, string newName);
    event SymbolUpdated(string oldSymbol, string newSymbol);
    event AssetCodeUpdated(string oldCode, string newCode);

    // ── META-01 ──
    function test_META01_AdminChangeName() public {
        _logCase("META-01", unicode"admin 改名称");

        _step("[Step 1] admin calls updateName('New Name')");
        vm.prank(tokenOps);
        vm.expectEmit(false, false, false, true);
        emit NameUpdated("Apple Inc.", "New Name");
        token.updateName("New Name");
        assertEq(token.name(), "New Name");
        _step("  PASS: name updated, NameUpdated emitted");

        _logPass();
    }

    // ── META-02 ──
    function test_META02_AdminChangeSymbol() public {
        _logCase("META-02", unicode"admin 改符号");

        _step("[Step 1] admin calls updateSymbol('NEW')");
        vm.prank(tokenOps);
        vm.expectEmit(false, false, false, true);
        emit SymbolUpdated("AAPL", "NEW");
        token.updateSymbol("NEW");
        assertEq(token.symbol(), "NEW");
        _step("  PASS: symbol updated, SymbolUpdated emitted");

        _logPass();
    }

    // ── META-03 ──
    function test_META03_AdminChangeIdentifier() public {
        _logCase("META-03", unicode"admin 改标识符");

        _step("[Step 1] admin calls updateAssetCode('NEWID')");
        vm.prank(tokenOps);
        vm.expectEmit(false, false, false, true);
        emit AssetCodeUpdated("US0378331005", "NEWID");
        token.updateAssetCode("NEWID");
        assertEq(token.assetCode(), "NEWID");
        _step("  PASS: identifier updated, AssetCodeUpdated emitted");

        _logPass();
    }

    // ── META-04 ──
    function test_META04_EmptyNameReverts() public {
        _logCase("META-04", unicode"空名称回滚");

        _step("[Step 1] tokenOps calls updateName('')");
        vm.prank(tokenOps);
        vm.expectRevert(ScaledToken.EmptyString.selector);
        token.updateName("");
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── META-05 ──
    function test_META05_EmptySymbolReverts() public {
        _logCase("META-05", unicode"空符号回滚");

        _step("[Step 1] tokenOps calls updateSymbol('')");
        vm.prank(tokenOps);
        vm.expectRevert(ScaledToken.InvalidSymbol.selector);
        token.updateSymbol("");
        _step("  PASS: reverted InvalidSymbol()");

        _logPass();
    }

    // ── META-06 ──
    function test_META06_EmptyIdentifierReverts() public {
        _logCase("META-06", unicode"空标识符回滚");

        _step("[Step 1] tokenOps calls updateAssetCode('')");
        vm.prank(tokenOps);
        vm.expectRevert(ScaledToken.InvalidAssetCode.selector);
        token.updateAssetCode("");
        _step("  PASS: reverted InvalidAssetCode()");

        _logPass();
    }

    // ── META-07 ──
    function test_META07_NonAdminCannotChangeName() public {
        _logCase("META-07", unicode"非 admin 不能改名称");

        _step("[Step 1] stranger tries updateName");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, TOKEN_OPS_ROLE));
        token.updateName("Hacked");
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── META-08 ──
    function test_META08_IssuerCannotChangeName() public {
        _logCase("META-08", unicode"issuer 不能改名称");

        _step("[Step 1] issuer tries updateName");
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer, TOKEN_OPS_ROLE));
        token.updateName("Hacked");
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── META-09 ──
    function test_META09_OperatorCannotChangeName() public {
        _logCase("META-09", unicode"operator 不能改名称");

        _step("[Step 1] operator tries updateName");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, TOKEN_OPS_ROLE));
        token.updateName("Hacked");
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Symbol / AssetCode 格式校验
    // ═══════════════════════════════════════════════

    // ── META-10 ──
    function test_META10_InvalidSymbolSpecialChars() public {
        _logCase("META-10", unicode"symbol 含特殊字符回滚");

        _step("[Step 1] updateSymbol('AAPL!')");
        vm.prank(tokenOps);
        vm.expectRevert(ScaledToken.InvalidSymbol.selector);
        token.updateSymbol("AAPL!");
        _step("  PASS: reverted InvalidSymbol()");

        _logPass();
    }

    // ── META-11 ──
    function test_META11_InvalidSymbolSpace() public {
        _logCase("META-11", unicode"symbol 含空格回滚");

        _step("[Step 1] updateSymbol('AA PL')");
        vm.prank(tokenOps);
        vm.expectRevert(ScaledToken.InvalidSymbol.selector);
        token.updateSymbol("AA PL");
        _step("  PASS: reverted InvalidSymbol()");

        _logPass();
    }

    // ── META-12 ──
    function test_META12_InvalidAssetCodeSpecialChars() public {
        _logCase("META-12", unicode"assetCode 含特殊字符回滚");

        _step("[Step 1] updateAssetCode('ID!@#')");
        vm.prank(tokenOps);
        vm.expectRevert(ScaledToken.InvalidAssetCode.selector);
        token.updateAssetCode("ID!@#");
        _step("  PASS: reverted InvalidAssetCode()");

        _logPass();
    }

    // ── META-13 ──
    function test_META13_SymbolTooLong() public {
        _logCase("META-13", unicode"symbol 超 32 字符回滚");

        _step("[Step 1] updateSymbol with 33-char string");
        vm.prank(tokenOps);
        vm.expectRevert(ScaledToken.InvalidSymbol.selector);
        token.updateSymbol("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567");
        _step("  PASS: reverted InvalidSymbol()");

        _logPass();
    }

    // ── META-14 ──
    function test_META14_AssetCodeTooLong() public {
        _logCase("META-14", unicode"assetCode 超 32 字符回滚");

        _step("[Step 1] updateAssetCode with 33-char string");
        vm.prank(tokenOps);
        vm.expectRevert(ScaledToken.InvalidAssetCode.selector);
        token.updateAssetCode("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567");
        _step("  PASS: reverted InvalidAssetCode()");

        _logPass();
    }

    // ── META-15 ──
    function test_META15_ValidSymbolVariants() public {
        _logCase("META-15", unicode"合法 symbol 变体");

        _step("[Step 1] updateSymbol with various valid formats");
        vm.startPrank(tokenOps);
        token.updateSymbol("BTC-USD");
        assertEq(token.symbol(), "BTC-USD");
        _step("  BTC-USD accepted");
        token.updateSymbol("abc123");
        assertEq(token.symbol(), "abc123");
        _step("  abc123 accepted");
        token.updateSymbol("A");
        assertEq(token.symbol(), "A");
        _step("  single char accepted");
        vm.stopPrank();
        _step("  PASS: all valid variants accepted");

        _logPass();
    }
}
