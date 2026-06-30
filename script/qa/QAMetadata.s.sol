// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract QAMetadata is BaseQAScript {
    function run() external {
        _loadEnv();

        test_META01();
        test_META02();
        test_META03();
    }

    // ── QA-META-01: 元数据变更 ──
    function test_META01() public {
        _logCase("QA-META-01", unicode"元数据变更");

        _step("[Step 1] deploy tokenB for metadata test");
        vm.broadcast(adminPk);
        string memory sym = _uniqueSymbol("MT");
        address tokenBAddr = factory.deployToken("Meta Corp", sym, "META001", admin, new address[](0), new address[](0));
        SecuritiesToken tokenB = SecuritiesToken(tokenBAddr);

        _step("[Step 2] admin sets name");
        vm.broadcast(adminPk);
        tokenB.setName("New Name");
        _assertEq(tokenB.name(), "New Name", "name");
        _step("  PASS: name == 'New Name'");

        _step("[Step 3] admin sets symbol");
        vm.broadcast(adminPk);
        tokenB.setSymbol("NEWM");
        _assertEq(tokenB.symbol(), "NEWM", "symbol");
        _step("  PASS: symbol == 'NEWM'");

        _step("[Step 4] admin sets identifier");
        vm.broadcast(adminPk);
        tokenB.setIdentifier("NEW999");
        _assertEq(tokenB.identifier(), "NEW999", "identifier");
        _step("  PASS: identifier == 'NEW999'");

        _logPass();
    }

    // ── QA-META-02: 空串回滚 ──
    function test_META02() public {
        _logCase("QA-META-02", unicode"空串回滚");

        _step("[Step 1] admin tries setName('')");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(token.setName.selector, ""),
            SecuritiesToken.EmptyString.selector
        );
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── QA-META-03: 非 admin 不能改 ──
    function test_META03() public {
        _logCase("QA-META-03", unicode"非 admin 不能改");

        _step("[Step 1] precondition: userA has no DEFAULT_ADMIN_ROLE");
        _assertEq(token.hasRole(DEFAULT_ADMIN_ROLE_HASH, userA), false, "userA no admin");

        _step("[Step 2] userA tries setName");
        _expectRevertFrom(
            userA,
            address(token),
            abi.encodeWithSelector(token.setName.selector, "Hacked"),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: reverted AccessControlUnauthorizedAccount()");

        _logPass();
    }
}
