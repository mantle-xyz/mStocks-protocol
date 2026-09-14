// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract QARole is BaseQAScript {
    function run() external {
        _loadEnv();

        test_ROLE01();
        test_ROLE02();
        test_ROLE03();
        test_ROLE04();
        test_ROLE05();
        test_ROLE06();
        test_ROLE07();
        test_ROLE08();
        test_ROLE09();
        test_ROLE10();
        test_ROLE11();
        test_ROLE12();
        test_ROLE13();
        test_ROLE14();
        test_ROLE15();
    }

    // ── QA-ROLE-01: grant ISSUER_ROLE to contract ──
    function test_ROLE01() public {
        _logCase("QA-ROLE-01", unicode"grant ISSUER_ROLE to contract");

        _step("[Step 1] deploy a new TokenIssuer as issuer candidate");
        vm.broadcast(factoryOpsPk);
        string memory sym = _uniqueSymbol("RL");
        address tokenBAddr = factory.createToken("Role Corp", sym, "ROLE001", admin, new address[](0), new address[](0), new address[](0));
        ScaledToken tokenB = ScaledToken(tokenBAddr);

        _step("[Step 2] admin grants ISSUER_ROLE to wallet on tokenB");
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        _assertEq(tokenB.hasRole(ISSUER_ROLE, address(vault)), true, "wallet has ISSUER_ROLE");
        _step("  PASS: grantRole succeeded (contract address)");

        _logPass();
    }

    // ── QA-ROLE-02: grant OPS_ROLE → setUIMultiplier 生效 ──
    function test_ROLE02() public {
        _logCase("QA-ROLE-02", unicode"grant OPS_ROLE -> setUIMultiplier 生效");

        _step("[Step 1] deploy tokenB, grant OPS_ROLE to userA");
        vm.broadcast(factoryOpsPk);
        string memory sym = _uniqueSymbol("OP");
        address tokenBAddr = factory.createToken("Ops Corp", sym, "OPS001", admin, new address[](0), new address[](0), new address[](0));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_MULTIPLIER_ROLE, userA);
        _assertEq(tokenB.hasRole(TOKEN_MULTIPLIER_ROLE, userA), true, "userA has OPS_ROLE");

        _step("[Step 2] userA calls setUIMultiplier on tokenB");
        vm.broadcast(userAPk);
        tokenB.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _assertEq(tokenB.newUIMultiplier(), 2e18, "newUIMultiplier");
        _step("  PASS: setUIMultiplier succeeded");

        _step("[Step 3] cleanup: revoke OPS_ROLE from userA");
        vm.broadcast(adminPk);
        tokenB.revokeRole(TOKEN_MULTIPLIER_ROLE, userA);
        _assertEq(tokenB.hasRole(TOKEN_MULTIPLIER_ROLE, userA), false, "userA OPS_ROLE revoked");
        _step("  PASS: OPS_ROLE revoked");

        _logPass();
    }

    // ── QA-ROLE-03: revokeRole 后立刻失效 ──
    function test_ROLE03() public {
        _logCase("QA-ROLE-03", unicode"revokeRole 后立刻失效");

        _step("[Step 1] deploy tokenB, grant ISSUER_ROLE to wallet, then revoke");
        vm.broadcast(factoryOpsPk);
        string memory sym = _uniqueSymbol("RV");
        address tokenBAddr = factory.createToken("Rev Corp", sym, "REV001", admin, new address[](0), new address[](0), new address[](0));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(vault));
        _assertEq(tokenB.hasRole(ISSUER_ROLE, address(vault)), true, "wallet has ISSUER_ROLE");

        vm.broadcast(adminPk);
        tokenB.revokeRole(ISSUER_ROLE, address(vault));
        _assertEq(tokenB.hasRole(ISSUER_ROLE, address(vault)), false, "wallet ISSUER_ROLE revoked");

        _step("[Step 2] walletOps tries to mint on tokenB via wallet (ISSUER revoked -> UnauthorizedRole)");
        _expectRevertFrom(
            walletOps,
            address(vault),
            abi.encodeWithSelector(TokenIssuer.mint.selector, tokenBAddr, hotWallet, 1e18),
            ScaledToken.UnauthorizedRole.selector
        );
        _step("  PASS: reverted UnauthorizedRole() after revoke");

        _logPass();
    }

    // ── QA-ROLE-04: 非 admin 不能 grantRole ──
    function test_ROLE04() public {
        _logCase("QA-ROLE-04", unicode"非 admin 不能 grantRole");

        _step("[Step 1] precondition: userA has no DEFAULT_ADMIN_ROLE");
        _assertEq(token.hasRole(DEFAULT_ADMIN_ROLE_HASH, userA), false, "userA no admin");

        _step("[Step 2] userA tries grantRole");
        _expectRevertFrom(
            userA,
            address(token),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, TOKEN_MULTIPLIER_ROLE, userB),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: reverted AccessControlUnauthorizedAccount()");

        _logPass();
    }

    // ── QA-ROLE-05: token: admin 给自己授 ISSUER_ROLE ──
    function test_ROLE05() public {
        _logCase("QA-ROLE-05", unicode"token: admin 给自己授 ISSUER_ROLE");

        _step("[Step 1] precondition: admin has DEFAULT_ADMIN_ROLE");
        _requireRole(address(token), DEFAULT_ADMIN_ROLE_HASH, admin, "admin");

        _step("[Step 2] admin tries grantRole(ISSUER_ROLE, admin)");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, ISSUER_ROLE, admin),
            ScaledToken.SelfGrantNotAllowed.selector
        );
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── QA-ROLE-06: token: admin 给自己授 OPS_ROLE ──
    function test_ROLE06() public {
        _logCase("QA-ROLE-06", unicode"token: admin 给自己授 OPS_ROLE");

        _step("[Step 1] admin tries grantRole(OPS_ROLE, admin) on token");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, TOKEN_MULTIPLIER_ROLE, admin),
            ScaledToken.SelfGrantNotAllowed.selector
        );
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── QA-ROLE-07: compliance: admin 给自己授 OPS_ROLE ──
    function test_ROLE07() public {
        _logCase("QA-ROLE-07", unicode"compliance: admin 给自己授 OPS_ROLE");

        _step("[Step 1] admin tries grantRole(OPS_ROLE, admin) on compliance");
        _expectRevertFrom(
            admin,
            address(compliance),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, COMPLIANCE_OPS_ROLE, admin),
            ComplianceRegistry.SelfGrantNotAllowed.selector
        );
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── QA-ROLE-08: pauseManager: admin 给自己授 PAUSE_ROLE ──
    function test_ROLE08() public {
        _logCase("QA-ROLE-08", unicode"pauseManager: admin 给自己授 PAUSE_ROLE");

        _step("[Step 1] admin tries grantRole(PAUSE_ROLE, admin) on pauseManager");
        _expectRevertFrom(
            admin,
            address(pauseManager),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, PAUSE_MANAGER_PAUSE_ROLE, admin),
            PauseRegistry.SelfGrantNotAllowed.selector
        );
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── QA-ROLE-09: renounce 自己角色 ──
    function test_ROLE09() public {
        _logCase("QA-ROLE-09", unicode"renounce 自己角色(备用 token)");

        _step("[Step 1] deploy tokenB, grant userA as second admin");
        vm.broadcast(factoryOpsPk);
        address tokenBAddr = factory.createToken("Ren Corp", _uniqueSymbol("REN"), _uniqueSymbol("REN"), admin, new address[](0), new address[](0), new address[](0));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        _requireRole(tokenBAddr, DEFAULT_ADMIN_ROLE_HASH, admin, "admin on tokenB");
        vm.broadcast(adminPk);
        tokenB.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);

        _step("[Step 2] admin renounces DEFAULT_ADMIN_ROLE on tokenB (userA remains)");
        vm.broadcast(adminPk);
        tokenB.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _assertEq(tokenB.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin), false, "admin renounced");
        _assertEq(tokenB.hasRole(DEFAULT_ADMIN_ROLE_HASH, userA), true, "userA still admin");
        _step("  PASS: admin renounced, userA remains admin");

        _logPass();
    }

    // ── QA-ROLE-10: renounce 后不可治理 ──
    function test_ROLE10() public {
        _logCase("QA-ROLE-10", unicode"renounce 后不可治理");

        _step("[Step 1] deploy tokenB, grant userA as second admin, then admin renounces");
        vm.broadcast(factoryOpsPk);
        address tokenBAddr = factory.createToken("NoGov Corp", _uniqueSymbol("NOG"), _uniqueSymbol("NOG"), admin, new address[](0), new address[](0), new address[](0));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(DEFAULT_ADMIN_ROLE_HASH, userA);
        vm.broadcast(adminPk);
        tokenB.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _assertEq(tokenB.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin), false, "admin renounced");

        _step("[Step 2] admin tries grantRole on tokenB");
        _expectRevertFrom(
            admin,
            tokenBAddr,
            abi.encodeWithSelector(IAccessControl.grantRole.selector, ISSUER_ROLE, address(vault)),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: reverted AccessControlUnauthorizedAccount()");

        _logPass();
    }

    // ── QA-ROLE-11: ISSUER_ROLE 给 EOA 回滚 ──
    function test_ROLE11() public {
        _logCase("QA-ROLE-11", unicode"ISSUER_ROLE 给 EOA 回滚");

        _step("[Step 1] admin tries grantRole(ISSUER_ROLE, userA) on token");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, ISSUER_ROLE, userA),
            ScaledToken.IssuerNotContract.selector
        );
        _step("  PASS: reverted IssuerNotContract()");

        _logPass();
    }

    // ── QA-ROLE-12: Factory 部署时 EOA issuer 回滚 ──
    function test_ROLE12() public {
        _logCase("QA-ROLE-12", unicode"Factory 部署时 EOA issuer 回滚");

        _step("[Step 1] factoryOps deploys token via Factory with EOA issuer");
        address[] memory issuers = new address[](1);
        issuers[0] = userA;
        _expectRevertFrom(
            factoryOps,
            address(factory),
            abi.encodeWithSelector(
                factory.createToken.selector,
                "Bad Corp", "BAD", "BAD001", admin, issuers, new address[](0), new address[](0)
            ),
            ScaledToken.IssuerNotContract.selector
        );
        _step("  PASS: reverted IssuerNotContract()");

        _logPass();
    }

    // ── QA-ROLE-13: OPS_ROLE 给 EOA 仍允许 ──
    function test_ROLE13() public {
        _logCase("QA-ROLE-13", unicode"OPS_ROLE 给 EOA 仍允许");

        _step("[Step 1] deploy tokenB, factoryOps grants OPS_ROLE to userA (EOA)");
        vm.broadcast(factoryOpsPk);
        address tokenBAddr = factory.createToken("EOA Corp", "EOAB", "EOA001", admin, new address[](0), new address[](0), new address[](0));
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_MULTIPLIER_ROLE, userA);
        _assertEq(tokenB.hasRole(TOKEN_MULTIPLIER_ROLE, userA), true, "userA has OPS_ROLE");
        _step("  PASS: OPS_ROLE granted to EOA");

        _step("[Step 2] cleanup: revoke OPS_ROLE from userA");
        vm.broadcast(adminPk);
        tokenB.revokeRole(TOKEN_MULTIPLIER_ROLE, userA);
        _step("  PASS: revoked");

        _logPass();
    }

    // ── QA-ROLE-14: TokenIssuer: admin 给自己授角色 ──
    function test_ROLE14() public {
        _logCase("QA-ROLE-14", unicode"TokenIssuer: admin 给自己授角色");

        _step("[Step 1] admin tries grantRole(OPS_ROLE, admin) on wallet");
        _expectRevertFrom(
            admin,
            address(vault),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, WALLET_OPS_ROLE, admin),
            TokenIssuer.SelfGrantNotAllowed.selector
        );
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── QA-ROLE-15: TokenIssuer: admin 可授角色给他人 ──
    function test_ROLE15() public {
        _logCase("QA-ROLE-15", unicode"TokenIssuer: admin 可授角色给他人");

        _step("[Step 1] admin grants OPS_ROLE to userA on wallet");
        vm.broadcast(adminPk);
        vault.grantRole(WALLET_OPS_ROLE, userA);
        _assertEq(vault.hasRole(WALLET_OPS_ROLE, userA), true, "userA has OPS_ROLE");
        _step("  PASS: grantRole succeeded");

        _step("[Step 2] cleanup: revoke OPS_ROLE from userA");
        vm.broadcast(adminPk);
        vault.revokeRole(WALLET_OPS_ROLE, userA);
        _assertEq(vault.hasRole(WALLET_OPS_ROLE, userA), false, "userA OPS_ROLE revoked");
        _step("  PASS: revoked");

        _logPass();
    }
}
