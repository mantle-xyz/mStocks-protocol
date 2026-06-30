// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {OperatorWallet} from "../../src/OperatorWallet/OperatorWallet.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SecuritiesTokenFactory} from "../../src/securitiesToken/SecuritiesTokenFactory.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract InitQA is BaseQA {
    string constant MODULE = unicode"SecuritiesToken — 初始化";

    // ── ST-INIT-01 ──
    function test_STINIT01_InitialStateCorrect() public {
        _logCase("ST-INIT-01", unicode"工厂部署后初始状态正确");

        _step("[Step 1] query name / symbol / identifier / decimals / totalSupply / uiMultiplier / mintEnabled / burnEnabled");
        assertEq(token.name(), "Apple Inc.");
        _step("  PASS: name == Apple Inc.");
        assertEq(token.symbol(), "AAPL");
        _step("  PASS: symbol == AAPL");
        assertEq(token.identifier(), "US0378331005");
        _step("  PASS: identifier == US0378331005");
        assertEq(token.decimals(), 18);
        _step("  PASS: decimals == 18");
        assertEq(token.totalSupply(), 0);
        _step("  PASS: totalSupply == 0");
        assertEq(token.uiMultiplier(), 1e18);
        _step("  PASS: uiMultiplier == 1e18");
        assertTrue(token.mintEnabled());
        _step("  PASS: mintEnabled == true");
        assertTrue(token.burnEnabled());
        _step("  PASS: burnEnabled == true");

        _logPass();
    }

    // ── ST-INIT-02 ──
    function test_STINIT02_RolesCorrect() public {
        _logCase("ST-INIT-02", unicode"角色分配正确");

        _step("[Step 1] query hasRole for admin, issuer, operator");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE");
        assertTrue(token.hasRole(ISSUER_ROLE, issuer));
        _step("  PASS: issuer has ISSUER_ROLE");
        assertTrue(token.hasRole(OPS_ROLE, operator));
        _step("  PASS: operator has OPS_ROLE");

        _logPass();
    }

    // ── ST-INIT-03 ──
    function test_STINIT03_CannotReinitialize() public {
        _logCase("ST-INIT-03", unicode"不能重复初始化");

        _step("[Step 1] call token.initialize(...) again");
        address[] memory empty = new address[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize("X", "X", "X", address(compliance), address(pauseManager), admin, empty, empty);
        _step("  PASS: reverted (Initializable: contract is already initialized)");

        _logPass();
    }

    // ── ST-INIT-04 ──
    function test_STINIT04_EmptyNameReverts() public {
        _logCase("ST-INIT-04", unicode"空名称回滚");

        _step("[Step 1] deployToken with name = empty string");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(SecuritiesTokenFactory.EmptyString.selector);
        factory.deployToken("", "NEWT", "ID001", admin, empty, empty);
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── ST-INIT-05 ──
    function test_STINIT05_EmptySymbolReverts() public {
        _logCase("ST-INIT-05", unicode"空符号回滚");

        _step("[Step 1] deployToken with symbol = empty string");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(SecuritiesTokenFactory.EmptyString.selector);
        factory.deployToken("Name", "", "ID001", admin, empty, empty);
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── ST-INIT-06 ──
    function test_STINIT06_EmptyIdentifierReverts() public {
        _logCase("ST-INIT-06", unicode"空标识符回滚");

        _step("[Step 1] deployToken with identifier = empty string");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(SecuritiesTokenFactory.EmptyString.selector);
        factory.deployToken("Name", "NEWT", "", admin, empty, empty);
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── ST-INIT-07 ──
    function test_STINIT07_ZeroAddressIssuerReverts() public {
        _logCase("ST-INIT-07", unicode"issuers 含零地址回滚");

        _step("[Step 1] deployToken with issuers = [address(0)]");
        address[] memory issuers = new address[](1);
        issuers[0] = address(0);
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.ZeroAddress.selector);
        factory.deployToken("Name", "NEWT", "ID001", admin, issuers, empty);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── ST-INIT-08 ──
    function test_STINIT08_ZeroAddressOperatorReverts() public {
        _logCase("ST-INIT-08", unicode"operators 含零地址回滚");

        _step("[Step 1] deployToken with operators = [address(0)]");
        address[] memory operators_ = new address[](1);
        operators_[0] = address(0);
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.ZeroAddress.selector);
        factory.deployToken("Name", "NEWT", "ID001", admin, empty, operators_);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── ST-INIT-09 ──
    function test_STINIT09_MultiIssuerMultiOperator() public {
        _logCase("ST-INIT-09", unicode"多 issuer 多 operator");

        _step("[Step 1] deploy with issuers=[A,B], operators=[C,D] (issuers must be contracts)");
        address issuerA = address(new OperatorWallet());
        address issuerB = address(new OperatorWallet());
        address opC = makeAddr("opC");
        address opD = makeAddr("opD");

        address[] memory issuers = new address[](2);
        issuers[0] = issuerA;
        issuers[1] = issuerB;
        address[] memory operators_ = new address[](2);
        operators_[0] = opC;
        operators_[1] = opD;

        vm.prank(admin);
        address proxy = factory.deployToken("Multi", "MULT", "ID002", admin, issuers, operators_);
        SecuritiesToken t = SecuritiesToken(proxy);

        assertTrue(t.hasRole(t.ISSUER_ROLE(), issuerA));
        _step("  PASS: issuerA has ISSUER_ROLE");
        assertTrue(t.hasRole(t.ISSUER_ROLE(), issuerB));
        _step("  PASS: issuerB has ISSUER_ROLE");
        assertTrue(t.hasRole(t.OPS_ROLE(), opC));
        _step("  PASS: opC has OPS_ROLE");
        assertTrue(t.hasRole(t.OPS_ROLE(), opD));
        _step("  PASS: opD has OPS_ROLE");

        _logPass();
    }

    // ── ST-INIT-10 ──
    function test_STINIT10_IssuerRoleToEOAReverts() public {
        _logCase("ST-INIT-10", unicode"ISSUER_ROLE 给 EOA 回滚");

        _step("[Step 1] admin grants ISSUER_ROLE to an EOA address");
        address eoaAddr = makeAddr("someEOA");
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.IssuerMustBeContract.selector);
        token.grantRole(ISSUER_ROLE, eoaAddr);
        _step("  PASS: reverted IssuerMustBeContract()");

        _logPass();
    }

    // ── ST-INIT-11 ──
    function test_STINIT11_FactoryDeployEOAIssuerReverts() public {
        _logCase("ST-INIT-11", unicode"Factory 部署时 EOA issuer 回滚");

        _step("[Step 1] deployToken with issuers=[eoa]");
        address eoaAddr = makeAddr("eoaIssuer");
        address[] memory issuers = new address[](1);
        issuers[0] = eoaAddr;
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.IssuerMustBeContract.selector);
        factory.deployToken("EOATest", "EOAT", "ID003", admin, issuers, empty);
        _step(unicode"  PASS: reverted IssuerMustBeContract() — Factory init path also enforced");

        _logPass();
    }

    // ── ST-INIT-12 ──
    function test_STINIT12_OpsRoleToEOAAllowed() public {
        _logCase("ST-INIT-12", unicode"OPS_ROLE 给 EOA 仍允许");

        _step("[Step 1] admin grants OPS_ROLE to an EOA address");
        address eoaAddr = makeAddr("eoaOps");
        vm.prank(admin);
        token.grantRole(OPS_ROLE, eoaAddr);
        assertTrue(token.hasRole(OPS_ROLE, eoaAddr));
        _step(unicode"  PASS: OPS_ROLE granted to EOA successfully — IssuerMustBeContract only restricts ISSUER_ROLE");

        _logPass();
    }
}
