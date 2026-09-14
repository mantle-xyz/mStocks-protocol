// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract QANewFeatures is BaseQAScript {
    function run() external {
        _loadEnv();

        // CannotRenounceLastAdmin — negative (5 contracts)
        test_RENOUNCE01();
        test_RENOUNCE02();
        test_RENOUNCE03();
        test_RENOUNCE04();
        test_RENOUNCE05();
        // CannotRenounceLastAdmin — positive (5 contracts)
        test_RENOUNCE06();
        test_RENOUNCE07();
        test_RENOUNCE08();
        test_RENOUNCE09();
        test_RENOUNCE10();

        // PauseRegistry noop guard (5 cases)
        test_PMIDEM01();
        test_PMIDEM02();
        test_PMIDEM03();
        test_PMIDEM04();
        test_PMIDEM05();

        // Compliance: admin cannot manage sanctions/blocklist (4 cases)
        test_CLADMIN01();
        test_CLADMIN02();
        test_CLADMIN03();
        test_CLADMIN04();

        // Compliance: unsanctionUsers edge cases (4 cases)
        test_UNSANC01();
        test_UNSANC02();
        test_UNSANC03();
        test_UNSANC04();

        // Compliance: checkIsCompliant (3 cases)
        test_CLCHK01();
        test_CLCHK02();
        test_CLCHK03();

        // Metadata format validation (5 cases)
        test_METAFMT01();
        test_METAFMT02();
        test_METAFMT03();
        test_METAFMT04();
        test_METAFMT05();

        // Factory createToken format validation (2 cases)
        test_FTFMT01();
        test_FTFMT02();

        // Factory symbol/assetCode uniqueness (2 cases)
        test_FTSYM01();
        test_FTASSET01();

        // TokenIssuer withdraw native ETH revert (1 case)
        test_WITHDRAW01();
    }

    // ═══════════════════════════════════════════════
    //      Internal helpers
    // ═══════════════════════════════════════════════

    function _requireSoleAdmin(address target, string memory label) internal view {
        (bool ok, bytes memory ret) = target.staticcall(
            abi.encodeWithSignature("getRoleMemberCount(bytes32)", DEFAULT_ADMIN_ROLE_HASH)
        );
        require(ok && abi.decode(ret, (uint256)) == 1, string.concat(label, ": must be exactly 1 admin"));
    }

    function _requireNotGloballyPaused() internal view {
        require(!pauseManager.globalPaused(), "precondition: must not be globally paused");
    }

    function _uniqueAssetCode(string memory prefix) internal returns (string memory) {
        return _uniqueSymbol(prefix);
    }

    // ═══════════════════════════════════════════════
    //      CannotRenounceLastAdmin — 5 contracts
    // ═══════════════════════════════════════════════

    // ── QA-RENOUNCE-01: ScaledToken ──
    function test_RENOUNCE01() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-01", unicode"ScaledToken 最后 admin 不能 renounce");

        _step("[Step 1] precondition: ensure admin is the ONLY DEFAULT_ADMIN_ROLE on token");
        _requireRole(address(token), DEFAULT_ADMIN_ROLE_HASH, admin, "admin on token");
        // cleanup: revoke any extra admins left by deployment handover
        uint256 adminCount = token.getRoleMemberCount(DEFAULT_ADMIN_ROLE_HASH);
        if (adminCount > 1) {
            address[] memory toRevoke = new address[](adminCount);
            uint256 revokeLen;
            for (uint256 i = 0; i < adminCount; i++) {
                address member = token.getRoleMember(DEFAULT_ADMIN_ROLE_HASH, i);
                if (member != admin) {
                    toRevoke[revokeLen++] = member;
                }
            }
            for (uint256 j = 0; j < revokeLen; j++) {
                vm.broadcast(adminPk);
                token.revokeRole(DEFAULT_ADMIN_ROLE_HASH, toRevoke[j]);
            }
        }
        _requireSoleAdmin(address(token), "token");

        _step("[Step 2] admin tries renounceRole");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(token.renounceRole.selector, DEFAULT_ADMIN_ROLE_HASH, admin),
            ScaledToken.CannotRenounceLastAdmin.selector
        );
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── QA-RENOUNCE-02: ComplianceRegistry ──
    function test_RENOUNCE02() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-02", unicode"ComplianceRegistry 最后 admin 不能 renounce");

        _step("[Step 1] precondition: admin is the ONLY DEFAULT_ADMIN_ROLE on compliance");
        _requireRole(address(compliance), DEFAULT_ADMIN_ROLE_HASH, admin, "admin on compliance");
        _requireSoleAdmin(address(compliance), "compliance");

        _step("[Step 2] admin tries renounceRole");
        _expectRevertFrom(
            admin,
            address(compliance),
            abi.encodeWithSelector(compliance.renounceRole.selector, DEFAULT_ADMIN_ROLE_HASH, admin),
            ComplianceRegistry.CannotRenounceLastAdmin.selector
        );
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── QA-RENOUNCE-03: PauseRegistry ──
    function test_RENOUNCE03() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-03", unicode"PauseRegistry 最后 admin 不能 renounce");

        _step("[Step 1] precondition: admin is the ONLY DEFAULT_ADMIN_ROLE on pauseManager");
        _requireRole(address(pauseManager), DEFAULT_ADMIN_ROLE_HASH, admin, "admin on pauseManager");
        _requireSoleAdmin(address(pauseManager), "pauseManager");

        _step("[Step 2] admin tries renounceRole");
        _expectRevertFrom(
            admin,
            address(pauseManager),
            abi.encodeWithSelector(pauseManager.renounceRole.selector, DEFAULT_ADMIN_ROLE_HASH, admin),
            PauseRegistry.CannotRenounceLastAdmin.selector
        );
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── QA-RENOUNCE-04: TokenIssuer ──
    function test_RENOUNCE04() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-04", unicode"TokenIssuer 最后 admin 不能 renounce");

        _step("[Step 1] precondition: admin is the ONLY DEFAULT_ADMIN_ROLE on vault");
        _requireRole(address(vault), DEFAULT_ADMIN_ROLE_HASH, admin, "admin on vault");
        _requireSoleAdmin(address(vault), "vault");

        _step("[Step 2] admin tries renounceRole");
        _expectRevertFrom(
            admin,
            address(vault),
            abi.encodeWithSelector(vault.renounceRole.selector, DEFAULT_ADMIN_ROLE_HASH, admin),
            TokenIssuer.CannotRenounceLastAdmin.selector
        );
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── QA-RENOUNCE-05: ScaledTokenFactory ──
    function test_RENOUNCE05() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-05", unicode"ScaledTokenFactory 最后 admin 不能 renounce");

        _step("[Step 1] precondition: admin is the ONLY DEFAULT_ADMIN_ROLE on factory");
        _requireRole(address(factory), DEFAULT_ADMIN_ROLE_HASH, admin, "admin on factory");
        _requireSoleAdmin(address(factory), "factory");

        _step("[Step 2] admin tries renounceRole");
        _expectRevertFrom(
            admin,
            address(factory),
            abi.encodeWithSelector(factory.renounceRole.selector, DEFAULT_ADMIN_ROLE_HASH, admin),
            ScaledTokenFactory.CannotRenounceLastAdmin.selector
        );
        _step("  PASS: reverted CannotRenounceLastAdmin()");

        _logPass();
    }

    // ── QA-RENOUNCE-06: ScaledToken 有 2 admin 时可 renounce ──
    function test_RENOUNCE06() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-06", unicode"ScaledToken 有 2 admin 时可 renounce");

        _step("[Step 1] grant userA DEFAULT_ADMIN_ROLE");
        vm.broadcast(adminPk);
        token.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        _assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE_HASH), 2, "2 admins");

        _step("[Step 2] admin renounces");
        vm.broadcast(adminPk);
        token.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _assertEq(token.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin), false, "admin renounced");
        _assertEq(token.getRoleMemberCount(DEFAULT_ADMIN_ROLE_HASH), 1, "1 admin left");
        _step("  PASS: renounce succeeded");

        _step("[Step 3] cleanup: restore admin");
        vm.broadcast(userAPk);
        token.grantRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        vm.broadcast(userAPk);
        token.renounceRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        _requireSoleAdmin(address(token), "token");
        _step("  cleanup: admin restored as sole admin");

        _logPass();
    }

    // ── QA-RENOUNCE-07: ComplianceRegistry 有 2 admin 时可 renounce ──
    function test_RENOUNCE07() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-07", unicode"ComplianceRegistry 有 2 admin 时可 renounce");

        _step("[Step 1] grant userA DEFAULT_ADMIN_ROLE");
        vm.broadcast(adminPk);
        compliance.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);

        _step("[Step 2] admin renounces");
        vm.broadcast(adminPk);
        compliance.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _assertEq(compliance.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin), false, "admin renounced");
        _step("  PASS: renounce succeeded");

        _step("[Step 3] cleanup: restore admin");
        vm.broadcast(userAPk);
        compliance.grantRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        vm.broadcast(userAPk);
        compliance.renounceRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        _requireSoleAdmin(address(compliance), "compliance");
        _step("  cleanup: admin restored as sole admin");

        _logPass();
    }

    // ── QA-RENOUNCE-08: PauseRegistry 有 2 admin 时可 renounce ──
    function test_RENOUNCE08() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-08", unicode"PauseRegistry 有 2 admin 时可 renounce");

        _step("[Step 1] grant userA DEFAULT_ADMIN_ROLE");
        vm.broadcast(adminPk);
        pauseManager.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);

        _step("[Step 2] admin renounces");
        vm.broadcast(adminPk);
        pauseManager.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _assertEq(pauseManager.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin), false, "admin renounced");
        _step("  PASS: renounce succeeded");

        _step("[Step 3] cleanup: restore admin");
        vm.broadcast(userAPk);
        pauseManager.grantRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        vm.broadcast(userAPk);
        pauseManager.renounceRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        _requireSoleAdmin(address(pauseManager), "pauseManager");
        _step("  cleanup: admin restored as sole admin");

        _logPass();
    }

    // ── QA-RENOUNCE-09: TokenIssuer 有 2 admin 时可 renounce ──
    function test_RENOUNCE09() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-09", unicode"TokenIssuer 有 2 admin 时可 renounce");

        _step("[Step 1] grant userA DEFAULT_ADMIN_ROLE");
        vm.broadcast(adminPk);
        vault.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);

        _step("[Step 2] admin renounces");
        vm.broadcast(adminPk);
        vault.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _assertEq(vault.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin), false, "admin renounced");
        _step("  PASS: renounce succeeded");

        _step("[Step 3] cleanup: restore admin");
        vm.broadcast(userAPk);
        vault.grantRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        vm.broadcast(userAPk);
        vault.renounceRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        _requireSoleAdmin(address(vault), "vault");
        _step("  cleanup: admin restored as sole admin");

        _logPass();
    }

    // ── QA-RENOUNCE-10: ScaledTokenFactory 有 2 admin 时可 renounce ──
    function test_RENOUNCE10() public {
        _loadEnv();
        _logCase("QA-RENOUNCE-10", unicode"ScaledTokenFactory 有 2 admin 时可 renounce");

        _step("[Step 1] grant userA DEFAULT_ADMIN_ROLE");
        vm.broadcast(adminPk);
        factory.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);

        _step("[Step 2] admin renounces");
        vm.broadcast(adminPk);
        factory.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _assertEq(factory.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin), false, "admin renounced");
        _step("  PASS: renounce succeeded");

        _step("[Step 3] cleanup: restore admin");
        vm.broadcast(userAPk);
        factory.grantRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        vm.broadcast(userAPk);
        factory.renounceRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        _requireSoleAdmin(address(factory), "factory");
        _step("  cleanup: admin restored as sole admin");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      PauseRegistry noop guard — 5 cases
    // ═══════════════════════════════════════════════

    // ── QA-PMIDEM-01: 重复 pauseToken ──
    function test_PMIDEM01() public {
        _loadEnv();
        _logCase("QA-PMIDEM-01", unicode"重复 pauseToken 回滚");

        _step("[Step 1] precondition: token not paused");
        _requireNotPaused();

        _step("[Step 2] pauseOps pauses token");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        _requirePaused();
        _step("  token is paused");

        _step("[Step 3] second pauseToken reverts");
        _expectRevertFrom(
            pauseOps,
            address(pauseManager),
            abi.encodeWithSelector(pauseManager.pauseToken.selector, address(token)),
            PauseRegistry.TokenAlreadyPaused.selector
        );
        _step("  PASS: reverted TokenAlreadyPaused()");

        _step("[Step 4] cleanup: unpause");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();
        _step("  cleanup verified: token not paused");

        _logPass();
    }

    // ── QA-PMIDEM-02: 重复 unpauseToken ──
    function test_PMIDEM02() public {
        _loadEnv();
        _logCase("QA-PMIDEM-02", unicode"重复 unpauseToken 回滚");

        _step("[Step 1] precondition: token not paused");
        _requireNotPaused();

        _step("[Step 2] pause then unpause");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();

        _step("[Step 3] second unpause reverts");
        _expectRevertFrom(
            pauseOps,
            address(pauseManager),
            abi.encodeWithSelector(pauseManager.unpauseToken.selector, address(token)),
            PauseRegistry.TokenNotPaused.selector
        );
        _step("  PASS: reverted TokenNotPaused()");

        _logPass();
    }

    // ── QA-PMIDEM-03: 从未暂停时解除回滚 ──
    function test_PMIDEM03() public {
        _loadEnv();
        _logCase("QA-PMIDEM-03", unicode"从未暂停时解除回滚");

        _step("[Step 1] precondition: token not paused");
        _requireNotPaused();

        _step("[Step 2] unpauseToken on non-paused token reverts");
        _expectRevertFrom(
            pauseOps,
            address(pauseManager),
            abi.encodeWithSelector(pauseManager.unpauseToken.selector, address(token)),
            PauseRegistry.TokenNotPaused.selector
        );
        _step("  PASS: reverted TokenNotPaused()");

        _logPass();
    }

    // ── QA-PMIDEM-04: 重复 pauseGlobally ──
    function test_PMIDEM04() public {
        _loadEnv();
        _logCase("QA-PMIDEM-04", unicode"重复 pauseGlobally 回滚");

        _step("[Step 1] precondition: not globally paused");
        _requireNotGloballyPaused();

        _step("[Step 2] pauseOps calls pauseGlobally");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseGlobally();
        _assertEq(pauseManager.globalPaused(), true, "globally paused");

        _step("[Step 3] second pauseGlobally reverts");
        _expectRevertFrom(
            pauseOps,
            address(pauseManager),
            abi.encodeWithSelector(pauseManager.pauseGlobally.selector),
            PauseRegistry.AlreadyGloballyPaused.selector
        );
        _step("  PASS: reverted AlreadyGloballyPaused()");

        _step("[Step 4] cleanup: unpauseGlobally");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseGlobally();
        _assertEq(pauseManager.globalPaused(), false, "globally unpaused");
        _step("  cleanup verified: not globally paused");

        _logPass();
    }

    // ── QA-PMIDEM-05: 重复 unpauseGlobally ──
    function test_PMIDEM05() public {
        _loadEnv();
        _logCase("QA-PMIDEM-05", unicode"重复 unpauseGlobally 回滚");

        _step("[Step 1] precondition: not globally paused");
        _requireNotGloballyPaused();

        _step("[Step 2] pauseGlobally then unpauseGlobally");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseGlobally();
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseGlobally();
        _assertEq(pauseManager.globalPaused(), false, "globally unpaused");

        _step("[Step 3] second unpauseGlobally reverts");
        _expectRevertFrom(
            pauseOps,
            address(pauseManager),
            abi.encodeWithSelector(pauseManager.unpauseGlobally.selector),
            PauseRegistry.NotGloballyPaused.selector
        );
        _step("  PASS: reverted NotGloballyPaused()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Compliance: admin 不能管理制裁/黑名单
    // ═══════════════════════════════════════════════

    // ── QA-CLADMIN-01: admin 不能 unsanctionUsers ──
    function test_CLADMIN01() public {
        _loadEnv();
        _logCase("QA-CLADMIN-01", unicode"admin 不能移除制裁");

        _step("[Step 1] precondition: admin has no OPS_ROLE on compliance");
        _assertEq(compliance.hasRole(COMPLIANCE_OPS_ROLE, admin), false, "admin no OPS_ROLE");

        _step("[Step 2] sanction userA");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.sanctionUsers(addrs);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");

        _step("[Step 3] admin tries unsanctionUsers");
        _expectRevertFrom(
            admin,
            address(compliance),
            abi.encodeWithSelector(compliance.unsanctionUsers.selector, addrs),
            ComplianceRegistry.MissingOpsRole.selector
        );
        _step("  PASS: reverted MissingOpsRole()");

        _step("[Step 4] cleanup: unsanction");
        vm.broadcast(complianceOpsPk);
        compliance.unsanctionUsers(addrs);
        _assertEq(compliance.isSanctioned(userA), false, "userA unsanctioned");
        _step("  cleanup verified");

        _logPass();
    }

    // ── QA-CLADMIN-02: admin 不能 unblockUsers ──
    function test_CLADMIN02() public {
        _loadEnv();
        _logCase("QA-CLADMIN-02", unicode"admin 不能移除黑名单");

        _step("[Step 1] precondition: admin has no OPS_ROLE on compliance");
        _assertEq(compliance.hasRole(COMPLIANCE_OPS_ROLE, admin), false, "admin no OPS_ROLE");

        _step("[Step 2] block userA");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.blockUsers(address(token), addrs);
        _assertEq(compliance.isBlocked(address(token), userA), true, "userA blocked");

        _step("[Step 3] admin tries unblockUsers");
        _expectRevertFrom(
            admin,
            address(compliance),
            abi.encodeWithSelector(compliance.unblockUsers.selector, address(token), addrs),
            ComplianceRegistry.MissingOpsRole.selector
        );
        _step("  PASS: reverted MissingOpsRole()");

        _step("[Step 4] cleanup: unblock");
        vm.broadcast(complianceOpsPk);
        compliance.unblockUsers(address(token), addrs);
        _assertEq(compliance.isBlocked(address(token), userA), false, "userA unblocked");
        _step("  cleanup verified");

        _logPass();
    }

    // ── QA-CLADMIN-03: admin 不能 clearSanctions ──
    function test_CLADMIN03() public {
        _loadEnv();
        _logCase("QA-CLADMIN-03", unicode"admin 不能 clearSanctions");

        _step("[Step 1] precondition: admin has no OPS_ROLE on compliance");
        _assertEq(compliance.hasRole(COMPLIANCE_OPS_ROLE, admin), false, "admin no OPS_ROLE");

        _step("[Step 2] admin tries clearSanctions");
        _expectRevertFrom(
            admin,
            address(compliance),
            abi.encodeWithSelector(compliance.clearSanctions.selector),
            ComplianceRegistry.MissingOpsRole.selector
        );
        _step("  PASS: reverted MissingOpsRole()");

        _logPass();
    }

    // ── QA-CLADMIN-04: admin 不能 replaceSanctions ──
    function test_CLADMIN04() public {
        _loadEnv();
        _logCase("QA-CLADMIN-04", unicode"admin 不能 replaceSanctions");

        _step("[Step 1] precondition: admin has no OPS_ROLE on compliance");
        _assertEq(compliance.hasRole(COMPLIANCE_OPS_ROLE, admin), false, "admin no OPS_ROLE");

        _step("[Step 2] admin tries replaceSanctions");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        _expectRevertFrom(
            admin,
            address(compliance),
            abi.encodeWithSelector(compliance.replaceSanctions.selector, addrs),
            ComplianceRegistry.MissingOpsRole.selector
        );
        _step("  PASS: reverted MissingOpsRole()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      unsanctionUsers 边界
    // ═══════════════════════════════════════════════

    // ── QA-UNSANC-01: 精确解除部分制裁 ──
    function test_UNSANC01() public {
        _loadEnv();
        _logCase("QA-UNSANC-01", unicode"精确解除部分制裁");

        _step("[Step 1] sanction A and B");
        address[] memory both = new address[](2);
        both[0] = userA;
        both[1] = userB;
        vm.broadcast(complianceOpsPk);
        compliance.sanctionUsers(both);
        _assertEq(compliance.isSanctioned(userA), true, "A sanctioned");
        _assertEq(compliance.isSanctioned(userB), true, "B sanctioned");

        _step("[Step 2] unsanctionUsers([A]) - only A");
        address[] memory onlyA = new address[](1);
        onlyA[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.unsanctionUsers(onlyA);
        _assertEq(compliance.isSanctioned(userA), false, "A unsanctioned");
        _assertEq(compliance.isSanctioned(userB), true, "B still sanctioned");
        _step("  PASS: A unsanctioned, B still sanctioned");

        _step("[Step 3] cleanup: unsanction B");
        address[] memory onlyB = new address[](1);
        onlyB[0] = userB;
        vm.broadcast(complianceOpsPk);
        compliance.unsanctionUsers(onlyB);
        _assertEq(compliance.isSanctioned(userB), false, "B unsanctioned");
        _step("  cleanup verified");

        _logPass();
    }

    // ── QA-UNSANC-02: 空数组 unsanctionUsers 回滚 ──
    function test_UNSANC02() public {
        _loadEnv();
        _logCase("QA-UNSANC-02", unicode"空数组 unsanctionUsers 回滚");

        _step("[Step 1] unsanctionUsers([])");
        address[] memory empty = new address[](0);
        _expectRevertFrom(
            complianceOps,
            address(compliance),
            abi.encodeWithSelector(compliance.unsanctionUsers.selector, empty),
            ComplianceRegistry.EmptyAddressList.selector
        );
        _step("  PASS: reverted EmptyAddressList()");

        _logPass();
    }

    // ── QA-UNSANC-03: zero address unsanctionUsers 回滚 ──
    function test_UNSANC03() public {
        _loadEnv();
        _logCase("QA-UNSANC-03", unicode"zero address unsanctionUsers 回滚");

        _step("[Step 1] unsanctionUsers([address(0)])");
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);
        _expectRevertFrom(
            complianceOps,
            address(compliance),
            abi.encodeWithSelector(compliance.unsanctionUsers.selector, addrs),
            ComplianceRegistry.ZeroAddress.selector
        );
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── QA-UNSANC-04: 空数组 replaceSanctions 回滚 ──
    function test_UNSANC04() public {
        _loadEnv();
        _logCase("QA-UNSANC-04", unicode"空数组 replaceSanctions 回滚");

        _step("[Step 1] replaceSanctions([])");
        address[] memory empty = new address[](0);
        _expectRevertFrom(
            complianceOps,
            address(compliance),
            abi.encodeWithSelector(compliance.replaceSanctions.selector, empty),
            ComplianceRegistry.EmptyAddressList.selector
        );
        _step("  PASS: reverted EmptyAddressList()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      checkIsCompliant 正向路径
    // ═══════════════════════════════════════════════

    // ── QA-CLCHK-01: 合规用户不回滚 ──
    function test_CLCHK01() public {
        _loadEnv();
        _logCase("QA-CLCHK-01", unicode"合规用户 checkIsCompliant 不回滚");

        _step("[Step 1] precondition: userA not blocked, not sanctioned");
        _assertEq(compliance.isSanctioned(userA), false, "userA not sanctioned");
        _assertEq(compliance.isBlocked(address(token), userA), false, "userA not blocked");

        _step("[Step 2] checkIsCompliant(token, userA) should not revert");
        compliance.checkIsCompliant(address(token), userA);
        _step("  PASS: no revert");

        _logPass();
    }

    // ── QA-CLCHK-02: 移除黑名单后 checkIsCompliant 通过 ──
    function test_CLCHK02() public {
        _loadEnv();
        _logCase("QA-CLCHK-02", unicode"移除黑名单后 checkIsCompliant 通过");

        _step("[Step 1] block userA");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.blockUsers(address(token), addrs);
        _assertEq(compliance.isBlocked(address(token), userA), true, "userA blocked");

        _step("[Step 2] unblock userA");
        vm.broadcast(complianceOpsPk);
        compliance.unblockUsers(address(token), addrs);
        _assertEq(compliance.isBlocked(address(token), userA), false, "userA unblocked");

        _step("[Step 3] checkIsCompliant should not revert");
        compliance.checkIsCompliant(address(token), userA);
        _step("  PASS: no revert after unblock");

        _logPass();
    }

    // ── QA-CLCHK-03: 移除制裁后 checkIsCompliant 通过 ──
    function test_CLCHK03() public {
        _loadEnv();
        _logCase("QA-CLCHK-03", unicode"移除制裁后 checkIsCompliant 通过");

        _step("[Step 1] sanction userA");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.sanctionUsers(addrs);
        _assertEq(compliance.isSanctioned(userA), true, "userA sanctioned");

        _step("[Step 2] unsanction userA");
        vm.broadcast(complianceOpsPk);
        compliance.unsanctionUsers(addrs);
        _assertEq(compliance.isSanctioned(userA), false, "userA unsanctioned");

        _step("[Step 3] checkIsCompliant should not revert");
        compliance.checkIsCompliant(address(token), userA);
        _step("  PASS: no revert after unsanction");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Metadata format validation — token 层面
    // ═══════════════════════════════════════════════

    // ── QA-METAFMT-01: symbol 含特殊字符回滚 ──
    function test_METAFMT01() public {
        _loadEnv();
        _logCase("QA-METAFMT-01", unicode"symbol 含特殊字符回滚");

        _step("[Step 1] tokenOps tries updateSymbol('AAPL!')");
        _expectRevertFrom(
            tokenOps,
            address(token),
            abi.encodeWithSelector(token.updateSymbol.selector, "AAPL!"),
            ScaledToken.InvalidSymbol.selector
        );
        _step("  PASS: reverted InvalidSymbol()");

        _logPass();
    }

    // ── QA-METAFMT-02: symbol 含空格回滚 ──
    function test_METAFMT02() public {
        _loadEnv();
        _logCase("QA-METAFMT-02", unicode"symbol 含空格回滚");

        _step("[Step 1] tokenOps tries updateSymbol('AA PL')");
        _expectRevertFrom(
            tokenOps,
            address(token),
            abi.encodeWithSelector(token.updateSymbol.selector, "AA PL"),
            ScaledToken.InvalidSymbol.selector
        );
        _step("  PASS: reverted InvalidSymbol()");

        _logPass();
    }

    // ── QA-METAFMT-03: assetCode 含特殊字符回滚 ──
    function test_METAFMT03() public {
        _loadEnv();
        _logCase("QA-METAFMT-03", unicode"assetCode 含特殊字符回滚");

        _step("[Step 1] tokenOps tries updateAssetCode('ID!@#')");
        _expectRevertFrom(
            tokenOps,
            address(token),
            abi.encodeWithSelector(token.updateAssetCode.selector, "ID!@#"),
            ScaledToken.InvalidAssetCode.selector
        );
        _step("  PASS: reverted InvalidAssetCode()");

        _logPass();
    }

    // ── QA-METAFMT-04: symbol 超 32 字符回滚 ──
    function test_METAFMT04() public {
        _loadEnv();
        _logCase("QA-METAFMT-04", unicode"symbol 超 32 字符回滚");

        _step("[Step 1] tokenOps tries updateSymbol with 33-char string");
        _expectRevertFrom(
            tokenOps,
            address(token),
            abi.encodeWithSelector(token.updateSymbol.selector, "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567"),
            ScaledToken.InvalidSymbol.selector
        );
        _step("  PASS: reverted InvalidSymbol()");

        _logPass();
    }

    // ── QA-METAFMT-05: assetCode 超 32 字符回滚 ──
    function test_METAFMT05() public {
        _loadEnv();
        _logCase("QA-METAFMT-05", unicode"assetCode 超 32 字符回滚");

        _step("[Step 1] tokenOps tries updateAssetCode with 33-char string");
        _expectRevertFrom(
            tokenOps,
            address(token),
            abi.encodeWithSelector(token.updateAssetCode.selector, "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567"),
            ScaledToken.InvalidAssetCode.selector
        );
        _step("  PASS: reverted InvalidAssetCode()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Factory createToken 格式校验
    // ═══════════════════════════════════════════════

    // ── QA-FTFMT-01: createToken symbol 非法字符 ──
    function test_FTFMT01() public {
        _loadEnv();
        _logCase("QA-FTFMT-01", unicode"createToken symbol 非法字符回滚");

        _step("[Step 1] factoryOps tries createToken with invalid symbol");
        _expectRevertFrom(
            factoryOps,
            address(factory),
            abi.encodeWithSelector(
                factory.createToken.selector,
                "Bad Symbol Corp",
                "BAD!SYM",
                "BADSYM01",
                admin,
                new address[](0),
                new address[](0),
                new address[](0)
            ),
            ScaledTokenFactory.InvalidSymbol.selector
        );
        _step("  PASS: reverted InvalidSymbol()");

        _logPass();
    }

    // ── QA-FTFMT-02: createToken assetCode 非法字符 ──
    function test_FTFMT02() public {
        _loadEnv();
        _logCase("QA-FTFMT-02", unicode"createToken assetCode 非法字符回滚");

        _step("[Step 1] factoryOps tries createToken with invalid assetCode");
        _expectRevertFrom(
            factoryOps,
            address(factory),
            abi.encodeWithSelector(
                factory.createToken.selector,
                "Bad Asset Corp",
                "BADSYM",
                "BAD!CODE",
                admin,
                new address[](0),
                new address[](0),
                new address[](0)
            ),
            ScaledTokenFactory.InvalidAssetCode.selector
        );
        _step("  PASS: reverted InvalidAssetCode()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Factory symbol/assetCode 唯一性
    // ═══════════════════════════════════════════════

    // ── QA-FTSYM-01: 重复 symbol 创建 token 回滚 ──
    function test_FTSYM01() public {
        _loadEnv();
        _logCase("QA-FTSYM-01", unicode"重复 symbol 创建 token 回滚");

        _step("[Step 1] deploy tokenB with unique symbol");
        vm.broadcast(factoryOpsPk);
        string memory sym = _uniqueSymbol("SYM");
        string memory code1 = _uniqueAssetCode("SC1");
        factory.createToken("Sym Corp", sym, code1, admin, new address[](0), new address[](0), new address[](0));
        _step(string.concat("  tokenB created: symbol=", sym));

        _step("[Step 2] try create another token with same symbol");
        string memory code2 = _uniqueAssetCode("SC2");
        _expectRevertFrom(
            factoryOps,
            address(factory),
            abi.encodeWithSelector(
                factory.createToken.selector,
                "Sym Corp 2",
                sym,
                code2,
                admin,
                new address[](0),
                new address[](0),
                new address[](0)
            ),
            ScaledTokenFactory.TokenSymbolAlreadyExists.selector
        );
        _step("  PASS: reverted TokenSymbolAlreadyExists()");

        _logPass();
    }

    // ── QA-FTASSET-01: 重复 assetCode 创建 token 回滚 ──
    function test_FTASSET01() public {
        _loadEnv();
        _logCase("QA-FTASSET-01", unicode"重复 assetCode 创建 token 回滚");

        _step("[Step 1] deploy tokenB with unique assetCode");
        vm.broadcast(factoryOpsPk);
        string memory sym1 = _uniqueSymbol("DUP");
        string memory code = _uniqueAssetCode("DC");
        factory.createToken("Dup Corp", sym1, code, admin, new address[](0), new address[](0), new address[](0));
        _step(string.concat("  tokenB created: symbol=", sym1, " assetCode=", code));

        _step("[Step 2] try create another token with same assetCode");
        string memory sym2 = _uniqueSymbol("DUP2");
        _expectRevertFrom(
            factoryOps,
            address(factory),
            abi.encodeWithSelector(
                factory.createToken.selector,
                "Dup Corp 2",
                sym2,
                code,
                admin,
                new address[](0),
                new address[](0),
                new address[](0)
            ),
            ScaledTokenFactory.AssetCodeAlreadyExists.selector
        );
        _step("  PASS: reverted AssetCodeAlreadyExists()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      TokenIssuer withdraw: 原生 ETH 回滚
    // ═══════════════════════════════════════════════

    // ── QA-WITHDRAW-01: withdraw(address(0)) 回滚 ──
    function test_WITHDRAW01() public {
        _loadEnv();
        _logCase("QA-WITHDRAW-01", unicode"withdraw 原生 ETH 回滚 ZeroAddress");

        _step("[Step 1] precondition: admin has DEFAULT_ADMIN_ROLE on vault");
        _requireRole(address(vault), DEFAULT_ADMIN_ROLE_HASH, admin, "admin on vault");

        _step("[Step 2] admin tries withdraw(address(0))");
        _expectRevertFrom(
            admin,
            address(vault),
            abi.encodeWithSelector(vault.withdraw.selector, address(0)),
            TokenIssuer.ZeroAddress.selector
        );
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }
}
