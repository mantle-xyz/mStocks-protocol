// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";

contract QAInfo is BaseQAScript {
    function run() external {
        _loadEnv();

        test_INFO01();
        test_INFO02();
    }

    // ── QA-INFO-01: 状态读取 ──
    function test_INFO01() public {
        _logCase("QA-INFO-01", unicode"状态读取");

        _step("[Step 1] query name / symbol / identifier / decimals");
        _assertEq(token.name(), "Apple Inc.", "name");
        _step("  PASS: name == 'Apple Inc.'");

        _assertEq(token.symbol(), "AAPL", "symbol");
        _step("  PASS: symbol == 'AAPL'");

        _assertEq(token.identifier(), "US0378331005", "identifier");
        _step("  PASS: identifier == 'US0378331005'");

        _assertEq(token.decimals(), 18, "decimals");
        _step("  PASS: decimals == 18");

        _step("[Step 2] query uiMultiplier / mintEnabled / burnEnabled");
        _assertEq(token.uiMultiplier(), 1e18, "uiMultiplier");
        _step("  PASS: uiMultiplier == 1e18");

        _assertEq(token.mintEnabled(), true, "mintEnabled");
        _step("  PASS: mintEnabled == true");

        _assertEq(token.burnEnabled(), true, "burnEnabled");
        _step("  PASS: burnEnabled == true");

        _step("[Step 3] query compliance / pauseManager addresses");
        _assertEq(address(token.compliance()), address(compliance), "compliance");
        _step("  PASS: compliance matches");

        _assertEq(address(token.pauseManager()), address(pauseManager), "pauseManager");
        _step("  PASS: pauseManager matches");

        _logPass();
    }

    // ── QA-INFO-02: 角色成员查询 ──
    function test_INFO02() public {
        _logCase("QA-INFO-02", unicode"角色成员查询");

        _step("[Step 1] DEFAULT_ADMIN_ROLE member count and member");
        uint256 adminCount = token.getRoleMemberCount(DEFAULT_ADMIN_ROLE_HASH);
        require(adminCount >= 1, "admin count must >= 1");
        _step(string.concat("  PASS: DEFAULT_ADMIN_ROLE count = ", vm.toString(adminCount)));

        address adminMember = token.getRoleMember(DEFAULT_ADMIN_ROLE_HASH, 0);
        _assertEq(adminMember, admin, "admin member[0]");
        _step(string.concat("  PASS: admin member[0] = ", vm.toString(admin)));

        _step("[Step 2] ISSUER_ROLE member - should be OperatorWallet");
        uint256 issuerCount = token.getRoleMemberCount(ISSUER_ROLE);
        require(issuerCount >= 1, "issuer count must >= 1");
        _step(string.concat("  PASS: ISSUER_ROLE count = ", vm.toString(issuerCount)));

        address issuerMember = token.getRoleMember(ISSUER_ROLE, 0);
        _assertEq(issuerMember, address(wallet), "issuer member[0]");
        _step(string.concat("  PASS: issuer member[0] = OperatorWallet"));

        _step("[Step 3] OPS_ROLE member");
        uint256 opsCount = token.getRoleMemberCount(TOKEN_OPS_ROLE);
        require(opsCount >= 1, "ops count must >= 1");
        _step(string.concat("  PASS: OPS_ROLE count = ", vm.toString(opsCount)));

        _logPass();
    }
}
