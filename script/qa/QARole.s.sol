// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {SecuritiesTokenFactory} from "../../src/securitiesToken/SecuritiesTokenFactory.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {PauseManager} from "../../src/pauseManager/PauseManager.sol";
import {OperatorWallet} from "../../src/OperatorWallet/OperatorWallet.sol";
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

        _step("[Step 1] deploy a new OperatorWallet as issuer candidate");
        vm.broadcast(adminPk);
        string memory sym = _uniqueSymbol("RL");
        address tokenBAddr = factory.deployToken("Role Corp", sym, "ROLE001", admin, new address[](0), new address[](0));
        SecuritiesToken tokenB = SecuritiesToken(tokenBAddr);

        _step("[Step 2] admin grants ISSUER_ROLE to wallet on tokenB");
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(wallet));
        _assertEq(tokenB.hasRole(ISSUER_ROLE, address(wallet)), true, "wallet has ISSUER_ROLE");
        _step("  PASS: grantRole succeeded (contract address)");

        _logPass();
    }

    // ── QA-ROLE-02: grant OPS_ROLE → setUIMultiplier 生效 ──
    function test_ROLE02() public {
        _logCase("QA-ROLE-02", unicode"grant OPS_ROLE -> setUIMultiplier 生效");

        _step("[Step 1] deploy tokenB, grant OPS_ROLE to userA");
        vm.broadcast(adminPk);
        string memory sym = _uniqueSymbol("OP");
        address tokenBAddr = factory.deployToken("Ops Corp", sym, "OPS001", admin, new address[](0), new address[](0));
        SecuritiesToken tokenB = SecuritiesToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_OPS_ROLE, userA);
        _assertEq(tokenB.hasRole(TOKEN_OPS_ROLE, userA), true, "userA has OPS_ROLE");

        _step("[Step 2] userA calls setUIMultiplier on tokenB");
        vm.broadcast(userAPk);
        tokenB.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _assertEq(tokenB.newUIMultiplier(), 2e18, "newUIMultiplier");
        _step("  PASS: setUIMultiplier succeeded");

        _step("[Step 3] cleanup: revoke OPS_ROLE from userA");
        vm.broadcast(adminPk);
        tokenB.revokeRole(TOKEN_OPS_ROLE, userA);
        _assertEq(tokenB.hasRole(TOKEN_OPS_ROLE, userA), false, "userA OPS_ROLE revoked");
        _step("  PASS: OPS_ROLE revoked");

        _logPass();
    }

    // ── QA-ROLE-03: revokeRole 后立刻失效 ──
    function test_ROLE03() public {
        _logCase("QA-ROLE-03", unicode"revokeRole 后立刻失效");

        _step("[Step 1] deploy tokenB, grant ISSUER_ROLE to wallet, then revoke");
        vm.broadcast(adminPk);
        string memory sym = _uniqueSymbol("RV");
        address tokenBAddr = factory.deployToken("Rev Corp", sym, "REV001", admin, new address[](0), new address[](0));
        SecuritiesToken tokenB = SecuritiesToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(wallet));
        _assertEq(tokenB.hasRole(ISSUER_ROLE, address(wallet)), true, "wallet has ISSUER_ROLE");

        vm.broadcast(adminPk);
        tokenB.revokeRole(ISSUER_ROLE, address(wallet));
        _assertEq(tokenB.hasRole(ISSUER_ROLE, address(wallet)), false, "wallet ISSUER_ROLE revoked");

        _step("[Step 2] walletOps tries to mint on tokenB via wallet (ISSUER revoked -> MissingIssuerRole)");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(OperatorWallet.mint.selector, tokenBAddr, hotWallet, 1e18),
            OperatorWallet.MissingIssuerRole.selector
        );
        _step("  PASS: reverted MissingIssuerRole() after revoke");

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
            abi.encodeWithSelector(IAccessControl.grantRole.selector, TOKEN_OPS_ROLE, userB),
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
            SecuritiesToken.SelfGrantNotAllowed.selector
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
            abi.encodeWithSelector(IAccessControl.grantRole.selector, TOKEN_OPS_ROLE, admin),
            SecuritiesToken.SelfGrantNotAllowed.selector
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
            Compliance.SelfGrantNotAllowed.selector
        );
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── QA-ROLE-08: pauseManager: admin 给自己授 OPS_ROLE ──
    function test_ROLE08() public {
        _logCase("QA-ROLE-08", unicode"pauseManager: admin 给自己授 OPS_ROLE");

        _step("[Step 1] admin tries grantRole(OPS_ROLE, admin) on pauseManager");
        _expectRevertFrom(
            admin,
            address(pauseManager),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, PAUSE_MANAGER_OPS_ROLE, admin),
            PauseManager.SelfGrantNotAllowed.selector
        );
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── QA-ROLE-09: renounce 自己角色 ──
    function test_ROLE09() public {
        _logCase("QA-ROLE-09", unicode"renounce 自己角色(备用 token)");

        _step("[Step 1] deploy tokenB with admin as DEFAULT_ADMIN_ROLE");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.deployToken("Ren Corp", "RENB", "REN001", admin, new address[](0), new address[](0));
        SecuritiesToken tokenB = SecuritiesToken(tokenBAddr);
        _requireRole(tokenBAddr, DEFAULT_ADMIN_ROLE_HASH, admin, "admin on tokenB");

        _step("[Step 2] admin renounces DEFAULT_ADMIN_ROLE on tokenB");
        vm.broadcast(adminPk);
        tokenB.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _assertEq(tokenB.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin), false, "admin renounced");
        _step("  PASS: admin no longer has DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── QA-ROLE-10: renounce 后不可治理 ──
    function test_ROLE10() public {
        _logCase("QA-ROLE-10", unicode"renounce 后不可治理");

        _step("[Step 1] deploy tokenB, admin renounces");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.deployToken("NoGov Corp", "NOGV", "NOG001", admin, new address[](0), new address[](0));
        SecuritiesToken tokenB = SecuritiesToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.renounceRole(DEFAULT_ADMIN_ROLE_HASH, admin);
        _assertEq(tokenB.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin), false, "admin renounced");

        _step("[Step 2] admin tries grantRole on tokenB");
        _expectRevertFrom(
            admin,
            tokenBAddr,
            abi.encodeWithSelector(IAccessControl.grantRole.selector, ISSUER_ROLE, address(wallet)),
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
            SecuritiesToken.IssuerMustBeContract.selector
        );
        _step("  PASS: reverted IssuerMustBeContract()");

        _logPass();
    }

    // ── QA-ROLE-12: Factory 部署时 EOA issuer 回滚 ──
    function test_ROLE12() public {
        _logCase("QA-ROLE-12", unicode"Factory 部署时 EOA issuer 回滚");

        _step("[Step 1] admin deploys token via Factory with EOA issuer");
        address[] memory issuers = new address[](1);
        issuers[0] = userA;
        _expectRevertFrom(
            admin,
            address(factory),
            abi.encodeWithSelector(
                factory.deployToken.selector,
                "Bad Corp", "BAD", "BAD001", admin, issuers, new address[](0)
            ),
            SecuritiesToken.IssuerMustBeContract.selector
        );
        _step("  PASS: reverted IssuerMustBeContract()");

        _logPass();
    }

    // ── QA-ROLE-13: OPS_ROLE 给 EOA 仍允许 ──
    function test_ROLE13() public {
        _logCase("QA-ROLE-13", unicode"OPS_ROLE 给 EOA 仍允许");

        _step("[Step 1] deploy tokenB, admin grants OPS_ROLE to userA (EOA)");
        vm.broadcast(adminPk);
        address tokenBAddr = factory.deployToken("EOA Corp", "EOAB", "EOA001", admin, new address[](0), new address[](0));
        SecuritiesToken tokenB = SecuritiesToken(tokenBAddr);
        vm.broadcast(adminPk);
        tokenB.grantRole(TOKEN_OPS_ROLE, userA);
        _assertEq(tokenB.hasRole(TOKEN_OPS_ROLE, userA), true, "userA has OPS_ROLE");
        _step("  PASS: OPS_ROLE granted to EOA");

        _step("[Step 2] cleanup: revoke OPS_ROLE from userA");
        vm.broadcast(adminPk);
        tokenB.revokeRole(TOKEN_OPS_ROLE, userA);
        _step("  PASS: revoked");

        _logPass();
    }

    // ── QA-ROLE-14: OperatorWallet: admin 给自己授角色 ──
    function test_ROLE14() public {
        _logCase("QA-ROLE-14", unicode"OperatorWallet: admin 给自己授角色");

        _step("[Step 1] admin tries grantRole(OPS_ROLE, admin) on wallet");
        _expectRevertFrom(
            admin,
            address(wallet),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, WALLET_OPS_ROLE, admin),
            OperatorWallet.SelfGrantNotAllowed.selector
        );
        _step("  PASS: reverted SelfGrantNotAllowed()");

        _logPass();
    }

    // ── QA-ROLE-15: OperatorWallet: admin 可授角色给他人 ──
    function test_ROLE15() public {
        _logCase("QA-ROLE-15", unicode"OperatorWallet: admin 可授角色给他人");

        _step("[Step 1] admin grants OPS_ROLE to userA on wallet");
        vm.broadcast(adminPk);
        wallet.grantRole(WALLET_OPS_ROLE, userA);
        _assertEq(wallet.hasRole(WALLET_OPS_ROLE, userA), true, "userA has OPS_ROLE");
        _step("  PASS: grantRole succeeded");

        _step("[Step 2] cleanup: revoke OPS_ROLE from userA");
        vm.broadcast(adminPk);
        wallet.revokeRole(WALLET_OPS_ROLE, userA);
        _assertEq(wallet.hasRole(WALLET_OPS_ROLE, userA), false, "userA OPS_ROLE revoked");
        _step("  PASS: revoked");

        _logPass();
    }
}
