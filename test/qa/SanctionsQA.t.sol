// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";

contract SanctionsQA is BaseQA {
    string constant MODULE = unicode"制裁名单";

    SecuritiesToken internal tokenB;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        address[] memory empty = new address[](0);
        tokenB = SecuritiesToken(factory.deployToken("Google", "GOOG", "US02079K3059", admin, empty, empty));
        vm.stopPrank();
    }

    function _sanction(address user) internal {
        address[] memory addrs = new address[](1);
        addrs[0] = user;
        vm.prank(complianceOps);
        compliance.addToSanctionsList(addrs);
    }

    function _unsanction(address user) internal {
        address[] memory addrs = new address[](1);
        addrs[0] = user;
        vm.prank(complianceOps);
        compliance.removeFromSanctionsList(addrs);
    }

    // ── ST-SAN-01 ──
    function test_STSAN01_SanctionedTransferReverts() public {
        _logCase("ST-SAN-01", unicode"制裁后转账回滚");

        _step("[Step 1] sanction userA");
        _sanction(userA);

        _step("[Step 2] issuer tries to transfer to userA");
        _issuerMint(100e18);
        vm.prank(issuer);
        vm.expectRevert(Compliance.UserSanctioned.selector);
        token.transfer(userA, 50e18);
        _step("  PASS: reverted UserSanctioned()");

        _logPass();
    }

    // ── ST-SAN-02 ──
    function test_STSAN02_UnsanctionRestores() public {
        _logCase("ST-SAN-02", unicode"解除制裁后恢复");

        _step("[Step 1] sanction then unsanction userA");
        _sanction(userA);
        _unsanction(userA);

        _step("[Step 2] issuer transfers to userA");
        _issuerMint(100e18);
        vm.prank(issuer);
        token.transfer(userA, 50e18);
        assertEq(token.balanceOf(userA), 50e18);
        _step("  PASS: transfer succeeded after unsanction");

        _logPass();
    }

    // ── ST-SAN-03 ──
    function test_STSAN03_EpochReset() public {
        _logCase("ST-SAN-03", unicode"epoch 重置");

        _step("[Step 1] sanction userA and userB");
        _sanction(userA);
        _sanction(userB);

        _step("[Step 2] resetSanctionedAddresses");
        vm.prank(complianceOps);
        compliance.resetSanctionedAddresses();

        assertFalse(compliance.sanctionedAddresses(userA));
        _step("  PASS: userA no longer sanctioned");
        assertFalse(compliance.sanctionedAddresses(userB));
        _step("  PASS: userB no longer sanctioned");

        _logPass();
    }

    // ── ST-SAN-04 ──
    function test_STSAN04_SetReplaces() public {
        _logCase("ST-SAN-04", unicode"整体替换");

        _step("[Step 1] sanction userA");
        _sanction(userA);

        _step("[Step 2] setSanctionedAddresses([userB, stranger])");
        address[] memory newList = new address[](2);
        newList[0] = userB;
        newList[1] = stranger;
        vm.prank(complianceOps);
        compliance.setSanctionedAddresses(newList);

        assertFalse(compliance.sanctionedAddresses(userA));
        _step("  PASS: userA restored");
        assertTrue(compliance.sanctionedAddresses(userB));
        _step("  PASS: userB now sanctioned");
        assertTrue(compliance.sanctionedAddresses(stranger));
        _step("  PASS: stranger now sanctioned");

        _logPass();
    }

    // ── ST-SAN-05 ──
    function test_STSAN05_SanctionsAreGlobal() public {
        _logCase("ST-SAN-05", unicode"制裁全局性");

        _step("[Step 1] sanction userA");
        _sanction(userA);

        _step("[Step 2] checkIsCompliant on both token and tokenB");
        vm.expectRevert(Compliance.UserSanctioned.selector);
        compliance.checkIsCompliant(address(token), userA);
        _step(unicode"  PASS: token — reverted UserSanctioned()");

        vm.expectRevert(Compliance.UserSanctioned.selector);
        compliance.checkIsCompliant(address(tokenB), userA);
        _step(unicode"  PASS: tokenB — reverted UserSanctioned()");

        _logPass();
    }

    // ── ST-SAN-06 ──
    function test_STSAN06_BlocklistTakesPriority() public {
        _logCase("ST-SAN-06", unicode"黑名单优先");

        _step("[Step 1] block and sanction userA on token");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);
        _sanction(userA);

        _step("[Step 2] checkIsCompliant should revert UserBlocked (checked first)");
        vm.expectRevert(Compliance.UserBlocked.selector);
        compliance.checkIsCompliant(address(token), userA);
        _step("  PASS: reverted UserBlocked() (blocklist checked before sanctions)");

        _logPass();
    }

    // ── ST-SAN-07 ──
    function test_STSAN07_ResetThenAddIndependent() public {
        _logCase("ST-SAN-07", unicode"重置后新增独立");

        _step("[Step 1] sanction userA and userB, then reset");
        _sanction(userA);
        _sanction(userB);
        vm.prank(complianceOps);
        compliance.resetSanctionedAddresses();

        _step("[Step 2] sanction only userA");
        _sanction(userA);

        assertTrue(compliance.sanctionedAddresses(userA));
        _step("  PASS: userA sanctioned");
        assertFalse(compliance.sanctionedAddresses(userB));
        _step("  PASS: userB not sanctioned");

        _logPass();
    }
}
