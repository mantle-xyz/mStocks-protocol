// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract FuzzQA is BaseQA {
    // ═══════════════════════════════════════════════
    //      1. 乘数算术 Fuzz
    // ═══════════════════════════════════════════════

    function _activateMultiplier(uint256 m) internal {
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(m, effectiveAt);
        vm.warp(effectiveAt);
    }

    function testFuzz_RoundTripPrecision(uint256 rawAmount, uint256 multiplier) public {
        _logCase("FUZZ-MUL-01", unicode"乘数往返精度");
        multiplier = bound(multiplier, 1e9, 1e27);
        rawAmount = bound(rawAmount, 0, type(uint128).max);
        _activateMultiplier(multiplier);

        uint256 ui = token.toUIAmount(rawAmount);
        uint256 roundTrip = token.fromUIAmount(ui);
        assertLe(roundTrip, rawAmount);
        uint256 maxError = 1e18 / multiplier + 1;
        assertLe(rawAmount - roundTrip, maxError);
        _logPass();
    }

    function testFuzz_ToUIAmountMonotonic(uint256 a, uint256 b, uint256 multiplier) public {
        _logCase("FUZZ-MUL-02", unicode"toUIAmount 单调性");
        multiplier = bound(multiplier, 1e9, 1e27);
        a = bound(a, 0, type(uint256).max / multiplier);
        b = bound(b, a, type(uint256).max / multiplier);
        _activateMultiplier(multiplier);

        assertLe(token.toUIAmount(a), token.toUIAmount(b));
        _logPass();
    }

    function testFuzz_FromUIAmountMonotonic(uint256 a, uint256 b, uint256 multiplier) public {
        _logCase("FUZZ-MUL-03", unicode"fromUIAmount 单调性");
        multiplier = bound(multiplier, 1e9, 1e27);
        uint256 maxUI = multiplier >= 1e18
            ? type(uint256).max
            : type(uint256).max / 1e18 * multiplier;
        a = bound(a, 0, maxUI);
        b = bound(b, a, maxUI);
        _activateMultiplier(multiplier);

        assertLe(token.fromUIAmount(a), token.fromUIAmount(b));
        _logPass();
    }

    function testFuzz_ZeroInputAlwaysZero(uint256 multiplier) public {
        _logCase("FUZZ-MUL-04", unicode"零输入恒零");
        multiplier = bound(multiplier, 1e9, 1e27);
        _activateMultiplier(multiplier);

        assertEq(token.toUIAmount(0), 0);
        assertEq(token.fromUIAmount(0), 0);
        _logPass();
    }

    function testFuzz_MultiplierBelowMinRejects(uint256 multiplier) public {
        _logCase("FUZZ-MUL-05", unicode"乘数下限拒绝");
        multiplier = bound(multiplier, 0, 1e9 - 1);
        uint256 effectiveAt = block.timestamp + 1 hours;

        vm.prank(operator);
        vm.expectRevert("SecuritiesToken: multiplier below minimum (1e-9x)");
        token.setUIMultiplier(multiplier, effectiveAt);
        _logPass();
    }

    function testFuzz_MultiplierAboveMaxRejects(uint256 multiplier) public {
        _logCase("FUZZ-MUL-06", unicode"乘数上限拒绝");
        multiplier = bound(multiplier, 1e27 + 1, type(uint256).max);
        uint256 effectiveAt = block.timestamp + 1 hours;

        vm.prank(operator);
        vm.expectRevert("SecuritiesToken: multiplier above maximum (1e9x)");
        token.setUIMultiplier(multiplier, effectiveAt);
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      2. Compliance 批量操作 Fuzz
    // ═══════════════════════════════════════════════

    function _generateAddresses(uint256 count, uint256 seed) internal pure returns (address[] memory) {
        address[] memory addrs = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
            if (a == address(0)) a = address(uint160(1));
            addrs[i] = a;
        }
        return addrs;
    }

    function testFuzz_BlocklistAddRemove(uint8 count, uint256 seed) public {
        _logCase("FUZZ-CMP-01", unicode"黑名单增删");
        count = uint8(bound(count, 1, 20));
        address[] memory addrs = _generateAddresses(count, seed);

        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            assertTrue(compliance.blockedAddresses(address(token), addrs[i]));
        }

        vm.prank(complianceOps);
        compliance.removeFromBlocklist(address(token), addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            assertFalse(compliance.blockedAddresses(address(token), addrs[i]));
        }
        _logPass();
    }

    function testFuzz_BlocklistAndSanctionsDualListed(uint8 count, uint256 seed) public {
        _logCase("FUZZ-CMP-02", unicode"黑名单+制裁双重");
        count = uint8(bound(count, 1, 20));
        address[] memory addrs = _generateAddresses(count, seed);

        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);
        vm.prank(complianceOps);
        compliance.addToSanctionsList(addrs);

        // blocklist checked first → UserBlocked
        for (uint256 i = 0; i < addrs.length; ++i) {
            vm.expectRevert(Compliance.UserBlocked.selector);
            compliance.checkIsCompliant(address(token), addrs[i]);
        }

        // remove from blocklist → still sanctioned → UserSanctioned
        vm.prank(complianceOps);
        compliance.removeFromBlocklist(address(token), addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            vm.expectRevert(Compliance.UserSanctioned.selector);
            compliance.checkIsCompliant(address(token), addrs[i]);
        }

        // remove from sanctions → compliant
        vm.prank(complianceOps);
        compliance.removeFromSanctionsList(addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            compliance.checkIsCompliant(address(token), addrs[i]);
        }
        _logPass();
    }

    function testFuzz_SanctionsEpochReset(uint8 count, uint256 seed) public {
        _logCase("FUZZ-CMP-03", unicode"制裁 epoch 重置");
        count = uint8(bound(count, 1, 20));
        address[] memory addrs = _generateAddresses(count, seed);

        vm.prank(complianceOps);
        compliance.addToSanctionsList(addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            assertTrue(compliance.sanctionedAddresses(addrs[i]));
        }

        vm.prank(complianceOps);
        compliance.resetSanctionedAddresses();
        for (uint256 i = 0; i < addrs.length; ++i) {
            assertFalse(compliance.sanctionedAddresses(addrs[i]));
        }
        _logPass();
    }

    function testFuzz_SanctionsSetReplace(uint8 countA, uint8 countB, uint256 seed) public {
        _logCase("FUZZ-CMP-04", unicode"制裁列表替换");
        countA = uint8(bound(countA, 1, 20));
        countB = uint8(bound(countB, 1, 20));
        address[] memory listA = _generateAddresses(countA, seed);
        address[] memory listB = _generateAddresses(countB, uint256(keccak256(abi.encode(seed))));

        vm.prank(complianceOps);
        compliance.setSanctionedAddresses(listA);
        for (uint256 i = 0; i < listA.length; ++i) {
            assertTrue(compliance.sanctionedAddresses(listA[i]));
        }

        vm.prank(complianceOps);
        compliance.setSanctionedAddresses(listB);
        for (uint256 i = 0; i < listA.length; ++i) {
            assertFalse(compliance.sanctionedAddresses(listA[i]));
        }
        for (uint256 i = 0; i < listB.length; ++i) {
            assertTrue(compliance.sanctionedAddresses(listB[i]));
        }
        _logPass();
    }

    function testFuzz_SanctionsSetOverlap(uint8 countOnly, uint8 countShared, uint256 seed) public {
        _logCase("FUZZ-CMP-05", unicode"制裁列表重叠替换");
        countOnly = uint8(bound(countOnly, 1, 10));
        countShared = uint8(bound(countShared, 1, 10));

        address[] memory onlyA = _generateAddresses(countOnly, seed);
        address[] memory shared = _generateAddresses(countShared, uint256(keccak256(abi.encode(seed, "shared"))));

        // listA = onlyA + shared
        address[] memory listA = new address[](countOnly + countShared);
        for (uint256 i = 0; i < countOnly; ++i) listA[i] = onlyA[i];
        for (uint256 i = 0; i < countShared; ++i) listA[countOnly + i] = shared[i];

        // listB = shared (overlap portion only)
        vm.prank(complianceOps);
        compliance.setSanctionedAddresses(listA);

        vm.prank(complianceOps);
        compliance.setSanctionedAddresses(shared);

        // onlyA addresses should be cleared
        for (uint256 i = 0; i < onlyA.length; ++i) {
            assertFalse(compliance.sanctionedAddresses(onlyA[i]));
        }
        // shared addresses should still be sanctioned
        for (uint256 i = 0; i < shared.length; ++i) {
            assertTrue(compliance.sanctionedAddresses(shared[i]));
        }
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      3. 供应量守恒 Fuzz
    // ═══════════════════════════════════════════════

    function testFuzz_TransferConservesTotalSupply(uint256 mintAmt, uint256 txAmt) public {
        _logCase("FUZZ-SUP-01", unicode"transfer 供应量守恒");
        mintAmt = bound(mintAmt, 1, 1e30);
        txAmt = bound(txAmt, 0, mintAmt);

        _issuerMint(mintAmt);
        vm.prank(issuer);
        token.transfer(userA, txAmt);

        assertEq(token.totalSupply(), mintAmt);
        assertEq(token.balanceOf(issuer) + token.balanceOf(userA), mintAmt);
        _logPass();
    }

    function testFuzz_TransferFromConservesTotalSupply(uint256 mintAmt, uint256 txAmt) public {
        _logCase("FUZZ-SUP-02", unicode"transferFrom 供应量守恒");
        mintAmt = bound(mintAmt, 1, 1e30);
        txAmt = bound(txAmt, 0, mintAmt);

        _issuerMint(mintAmt);
        vm.prank(issuer);
        token.transfer(userA, mintAmt);

        vm.prank(userA);
        token.approve(userB, txAmt);
        vm.prank(userB);
        token.transferFrom(userA, userB, txAmt);

        assertEq(token.totalSupply(), mintAmt);
        assertEq(token.balanceOf(userA) + token.balanceOf(userB), mintAmt);
        _logPass();
    }

    function testFuzz_MintBurnSupplyAccounting(uint256 mintAmt, uint256 burnAmt) public {
        _logCase("FUZZ-SUP-03", unicode"mint/burn 供应量记账");
        mintAmt = bound(mintAmt, 1, 1e30);
        burnAmt = bound(burnAmt, 0, mintAmt);

        _issuerMint(mintAmt);
        vm.prank(issuer);
        token.burn(burnAmt);

        assertEq(token.totalSupply(), mintAmt - burnAmt);
        assertEq(token.balanceOf(issuer), mintAmt - burnAmt);
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      4. 权限矩阵 Fuzz
    // ═══════════════════════════════════════════════

    function testFuzz_UnauthorizedMintReverts(address caller) public {
        _logCase("FUZZ-PERM-01", unicode"未授权 mint 拒绝");
        vm.assume(caller != issuer && caller != address(wallet));
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.mint(1e18);
        _logPass();
    }

    function testFuzz_UnauthorizedSetMultiplierReverts(address caller) public {
        _logCase("FUZZ-PERM-02", unicode"未授权 setMultiplier 拒绝");
        vm.assume(caller != operator);
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _logPass();
    }

    function testFuzz_UnauthorizedAdminFunctionReverts(address caller) public {
        _logCase("FUZZ-PERM-03", unicode"未授权 admin 函数拒绝");
        vm.assume(caller != admin);
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, DEFAULT_ADMIN_ROLE_HASH)
        );
        token.setName("Hacked");
        _logPass();
    }
}
