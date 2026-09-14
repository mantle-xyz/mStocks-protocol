// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {PrivatizationRegistry} from "../../src/privatization/PrivatizationRegistry.sol";
import {CustodyClaimRouter} from "../../src/privatization/CustodyClaimRouter.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {MockUSD} from "../../test/mocks/MockUSD.sol";

contract QACustodyClaimRouter is BaseQAScript {
    // ── from .env (deployed contracts) ──
    PrivatizationRegistry internal registry;
    CustodyClaimRouter internal router;
    address internal registryOps;
    uint256 internal registryOpsPk;
    address internal routerOps;
    uint256 internal routerOpsPk;
    address internal cexHw1;
    uint256 internal cexHw1Pk;
    address internal cexHw2;
    uint256 internal cexHw2Pk;

    // ── temp resources ──
    ScaledToken internal tOld;
    ScaledToken internal tNew;
    ScaledToken internal tCvr;
    MockUSD internal tUsdc;

    bytes32 internal OPS_ROLE;
    bytes32 internal ROUTER_OPS_ROLE;

    bool internal _rtrEnvLoaded;
    bool internal _tempDeployed;

    function _initEnv() internal {
        _loadEnv();
        if (_rtrEnvLoaded) return;
        _rtrEnvLoaded = true;
        _loadRtrEnv();
    }

    function _initTemp() internal {
        _initEnv();
        if (_tempDeployed) return;
        _tempDeployed = true;
        _deployTempStack();
    }

    function run() external {
        _initEnv();

        test_RTR01();
        test_RTR02();
        _initTemp();
        test_RTR03();
        test_RTR04();
        test_RTR05();
        test_RTR06();
        test_RTR07();
        test_RTR08();
        test_RTR09();
        test_RTR10();
        test_RTR11();
        test_RTR12();
        test_RTR13();
        test_RTR14();
    }

    // ═══════════════════════════════════════════════
    //      Environment
    // ═══════════════════════════════════════════════

    function _loadRtrEnv() internal {
        registry = PrivatizationRegistry(vm.envAddress("REGISTRY_ADDR"));
        router = CustodyClaimRouter(vm.envAddress("ROUTER_ADDR"));
        registryOpsPk = vm.envUint("REGISTRY_OPS_PK");
        registryOps = vm.addr(registryOpsPk);
        routerOpsPk = vm.envUint("ROUTER_OPS_PK");
        routerOps = vm.addr(routerOpsPk);
        cexHw1Pk = vm.envUint("CEX_HOT_WALLET1_PK");
        cexHw1 = vm.addr(cexHw1Pk);
        cexHw2Pk = vm.envUint("CEX_HOT_WALLET2_PK");
        cexHw2 = vm.addr(cexHw2Pk);

        OPS_ROLE = registry.OPS_ROLE();
        ROUTER_OPS_ROLE = router.OPS_ROLE();
    }

    // ═══════════════════════════════════════════════
    //      Temp stack
    // ═══════════════════════════════════════════════

    function _deployTempStack() internal {
        address[] memory ops = new address[](1);
        ops[0] = walletOps;

        // createToken is OPS_ROLE-gated on factory → walletOps signs
        vm.startBroadcast(walletOpsPk);
        tOld = ScaledToken(factory.createToken("RTR Old", _uniqueSymbol("ROLD"), _uniqueSymbol("RTR"), admin, new address[](0), new address[](0), ops));
        tNew = ScaledToken(factory.createToken("RTR New", _uniqueSymbol("RNEW"), _uniqueSymbol("RTR"), admin, new address[](0), new address[](0), ops));
        tCvr = ScaledToken(factory.createToken("RTR CVR", _uniqueSymbol("RCVR"), _uniqueSymbol("RTR"), admin, new address[](0), new address[](0), ops));
        vm.stopBroadcast();

        // grantRole + MockUSD deploy → admin signs (token admin = admin via 4th param)
        vm.startBroadcast(adminPk);
        tUsdc = new MockUSD();
        tOld.grantRole(tOld.ISSUER_ROLE(), address(vault));
        tNew.grantRole(tNew.ISSUER_ROLE(), address(vault));
        tCvr.grantRole(tCvr.ISSUER_ROLE(), address(vault));
        tOld.grantRole(tOld.BURN_ROLE(), address(registry));
        vm.stopBroadcast();
    }

    /// @dev Create a funded, active program with 3 legs using temp tokens.
    function _createActiveFundedProgram(uint256 oldSupply, uint256 usdcTotal, uint256 newTotal, uint256 cvrTotal)
        internal
        returns (uint256)
    {
        _unfreezeToken(tOld);
        vm.broadcast(walletOpsPk);
        vault.mint(address(tOld), hotWallet, oldSupply);

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](3);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), usdcTotal);
        legs[1] = PrivatizationRegistry.Leg(address(tNew), newTotal);
        legs[2] = PrivatizationRegistry.Leg(address(tCvr), cvrTotal);

        vm.broadcast(registryOpsPk);
        uint256 id = registry.createProgram(address(tOld), legs);

        _freezeToken(tOld);

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: oldSupply,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.broadcast(registryOpsPk);
        registry.configureProgram(id, cfg);

        _fundLeg(id, address(tUsdc), usdcTotal);
        _fundLeg(id, address(tNew), newTotal);
        _fundLeg(id, address(tCvr), cvrTotal);

        return id;
    }

    function _freezeToken(ScaledToken t) internal {
        bytes32 opsRole = t.OPS_ROLE();
        address tokenOps = t.getRoleMember(opsRole, 0);
        uint256 tokenOpsPk = _findPkFor(tokenOps);
        vm.broadcast(tokenOpsPk);
        t.setMintAllowed(false);
    }

    function _unfreezeToken(ScaledToken t) internal {
        if (!t.mintAllowed()) {
            bytes32 opsRole = t.OPS_ROLE();
            address tokenOps = t.getRoleMember(opsRole, 0);
            uint256 tokenOpsPk = _findPkFor(tokenOps);
            vm.broadcast(tokenOpsPk);
            t.setMintAllowed(true);
        }
    }

    function _fundLeg(uint256 programId_, address tok, uint256 amount) internal {
        if (tok == address(tUsdc)) {
            vm.broadcast(registryOpsPk);
            tUsdc.mint(registryOps, amount);
        } else {
            vm.broadcast(walletOpsPk);
            vault.mint(tok, registryOps, amount);
        }
        vm.startBroadcast(registryOpsPk);
        IERC20(tok).approve(address(registry), amount);
        registry.fund(programId_, tok, amount);
        vm.stopBroadcast();
    }

    // ═══════════════════════════════════════════════
    //      Verification Tests (RTR-01 ~ RTR-02)
    // ═══════════════════════════════════════════════

    // ── RTR-01: router 部署验证 ──
    function test_RTR01() public {
        _initEnv();
        _logCase("QA-RTR-01", unicode"验证 router 已部署、registry 绑定正确");

        _assertEq(address(router) != address(0), true, "router deployed");
        _assertEq(address(router.registry()), address(registry), "router.registry == registry");
        _assertEq(router.hasRole(router.DEFAULT_ADMIN_ROLE(), admin), true, "admin has DEFAULT_ADMIN_ROLE");
        _step("  PASS: router deployed, registry binding correct");
        _logPass();
    }

    // ── RTR-02: OPS_ROLE + 热钱包已注册 ──
    function test_RTR02() public {
        _initEnv();
        _logCase("QA-RTR-02", unicode"验证 OPS_ROLE 已授、热钱包已注册");

        _assertEq(router.hasRole(ROUTER_OPS_ROLE, routerOps), true, "routerOps has OPS_ROLE");
        _assertEq(router.isHotWallet(cexHw1), true, "cexHw1 registered");
        _step("  PASS: OPS_ROLE and hot wallet registration verified");
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Lifecycle Tests (RTR-03 ~ RTR-14)
    // ═══════════════════════════════════════════════

    // ── RTR-03: 主流程 hw transfer → claimFor → 篮子到 hw ──
    function test_RTR03() public {
        _initTemp();
        _logCase("QA-RTR-03", unicode"主流程: hw transfer → claimFor → 篮子到 hw");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 200 ether, 100 ether);

        _step("[Step 1] hotWallet transfers OLD to cexHw1");
        vm.broadcast(hotWalletPk);
        tOld.transfer(cexHw1, 100 ether);

        _step("[Step 2] cexHw1 transfers OLD to router");
        vm.broadcast(cexHw1Pk);
        tOld.transfer(address(router), 100 ether);
        _assertEq(tOld.balanceOf(address(router)), 100 ether, "router holds OLD");

        _step("[Step 3] routerOps calls claimFor");
        uint256 usdcBefore = tUsdc.balanceOf(cexHw1);
        uint256 newBefore = tNew.balanceOf(cexHw1);
        uint256 cvrBefore = tCvr.balanceOf(cexHw1);
        vm.broadcast(routerOpsPk);
        router.claimFor(id, cexHw1, 100 ether);

        _step("[Step 4] verify basket delivered and router empty");
        _assertEq(tOld.totalSupply(), 0, "old burned");
        _assertDiff(usdcBefore, tUsdc.balanceOf(cexHw1), 300e6, "USDC to hw");
        _assertDiff(newBefore, tNew.balanceOf(cexHw1), 200 ether, "NEW to hw");
        _assertDiff(cvrBefore, tCvr.balanceOf(cexHw1), 100 ether, "CVR to hw");
        _assertEq(tOld.balanceOf(address(router)), 0, "router OLD empty");
        _assertEq(tUsdc.balanceOf(address(router)), 0, "router USDC empty");
        _step("  PASS: basket forwarded, router clean");
        _logPass();
    }

    // ── RTR-04: 未注册热钱包 → NotRegisteredHotWallet ──
    function test_RTR04() public {
        _initTemp();
        _logCase("QA-RTR-04", unicode"未注册热钱包 → NotRegisteredHotWallet");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 100 ether, 50 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 100 ether);
        vm.broadcast(userAPk);
        tOld.transfer(address(router), 100 ether);

        _expectRevertFrom(
            routerOps,
            address(router),
            abi.encodeWithSelector(CustodyClaimRouter.claimFor.selector, id, userA, uint256(100 ether)),
            CustodyClaimRouter.NotRegisteredHotWallet.selector
        );
        _step("  PASS: NotRegisteredHotWallet");
        _logPass();
    }

    // ── RTR-05: 非 OPS → AccessControlUnauthorizedAccount ──
    function test_RTR05() public {
        _initTemp();
        _logCase("QA-RTR-05", unicode"非 OPS → AccessControlUnauthorizedAccount");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 100 ether, 50 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(cexHw1, 100 ether);
        vm.broadcast(cexHw1Pk);
        tOld.transfer(address(router), 100 ether);

        _expectRevertFrom(
            userA,
            address(router),
            abi.encodeWithSelector(CustodyClaimRouter.claimFor.selector, id, cexHw1, uint256(100 ether)),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: AccessControlUnauthorizedAccount");
        _logPass();
    }

    // ── RTR-06: amount 超 router 余额 → revert ──
    function test_RTR06() public {
        _initTemp();
        _logCase("QA-RTR-06", unicode"amount 超 router 余额 → revert");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 100 ether, 50 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(cexHw1, 10 ether);
        vm.broadcast(cexHw1Pk);
        tOld.transfer(address(router), 10 ether);

        // router only holds 10 ether, claiming 20 reverts (ERC20InsufficientBalance inside registry)
        _step("[Step 2] routerOps tries claimFor with 20 ether (only 10 in router)");
        vm.prank(routerOps);
        (bool ok,) = address(router).call(
            abi.encodeWithSelector(CustodyClaimRouter.claimFor.selector, id, cexHw1, uint256(20 ether))
        );
        _assertEq(ok, false, "claimFor with excess amount reverts");
        _step("  PASS: revert on insufficient router balance");
        _logPass();
    }

    // ── RTR-07: 注册仅 admin → AccessControlUnauthorizedAccount ──
    function test_RTR07() public {
        _initTemp();
        _logCase("QA-RTR-07", unicode"注册仅 admin → AccessControlUnauthorizedAccount");

        _expectRevertFrom(
            routerOps,
            address(router),
            abi.encodeWithSelector(CustodyClaimRouter.registerHotWallet.selector, userB),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: OPS cannot register hot wallets");
        _logPass();
    }

    // ── RTR-08: 注销后不可 claimFor → NotRegisteredHotWallet ──
    function test_RTR08() public {
        _initTemp();
        _logCase("QA-RTR-08", unicode"注销后不可 claimFor → NotRegisteredHotWallet");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 100 ether, 50 ether);

        // Register cexHw2 then deregister it
        vm.broadcast(adminPk);
        router.registerHotWallet(cexHw2);
        _assertEq(router.isHotWallet(cexHw2), true, "cexHw2 registered");

        vm.broadcast(adminPk);
        router.deregisterHotWallet(cexHw2);
        _assertEq(router.isHotWallet(cexHw2), false, "cexHw2 deregistered");

        vm.broadcast(hotWalletPk);
        tOld.transfer(cexHw2, 10 ether);
        vm.broadcast(cexHw2Pk);
        tOld.transfer(address(router), 10 ether);

        _expectRevertFrom(
            routerOps,
            address(router),
            abi.encodeWithSelector(CustodyClaimRouter.claimFor.selector, id, cexHw2, uint256(10 ether)),
            CustodyClaimRouter.NotRegisteredHotWallet.selector
        );
        _step("  PASS: NotRegisteredHotWallet after deregister");
        _logPass();
    }

    // ── RTR-09: rescue 回收 ──
    function test_RTR09() public {
        _initTemp();
        _logCase("QA-RTR-09", unicode"rescue 回收");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 100 ether, 50 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(cexHw1, 100 ether);
        vm.broadcast(cexHw1Pk);
        tOld.transfer(address(router), 100 ether);

        uint256 adminOldBefore = tOld.balanceOf(admin);
        uint256 routerOldBefore = tOld.balanceOf(address(router));
        vm.broadcast(adminPk);
        router.rescue(address(tOld), admin, 100 ether);

        _assertDiff(adminOldBefore, tOld.balanceOf(admin), 100 ether, "admin received OLD");
        _assertEq(tOld.balanceOf(address(router)), routerOldBefore - 100 ether, "router decreased by 100");
        _step("  PASS: rescue successful");
        _logPass();
    }

    // ── RTR-10: rescue 非 admin → AccessControlUnauthorizedAccount ──
    function test_RTR10() public {
        _initTemp();
        _logCase("QA-RTR-10", unicode"rescue 非 admin → AccessControlUnauthorizedAccount");

        _expectRevertFrom(
            routerOps,
            address(router),
            abi.encodeWithSelector(CustodyClaimRouter.rescue.selector, address(tOld), routerOps, uint256(1)),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: OPS cannot rescue");
        _logPass();
    }

    // ── RTR-11: 批量注册热钱包 ──
    function test_RTR11() public {
        _initTemp();
        _logCase("QA-RTR-11", unicode"批量注册热钱包 registerHotWallets");

        address batchHw1 = vm.addr(0xba01);
        address batchHw2 = vm.addr(0xba02);
        address batchHw3 = vm.addr(0xba03);

        address[] memory wallets = new address[](3);
        wallets[0] = batchHw1;
        wallets[1] = batchHw2;
        wallets[2] = batchHw3;

        vm.broadcast(adminPk);
        router.registerHotWallets(wallets);

        _assertEq(router.isHotWallet(batchHw1), true, "batchHw1 registered");
        _assertEq(router.isHotWallet(batchHw2), true, "batchHw2 registered");
        _assertEq(router.isHotWallet(batchHw3), true, "batchHw3 registered");
        _step("  PASS: all 3 batch-registered");
        _logPass();
    }

    // ── RTR-12: 多热钱包分别 claimFor ──
    function test_RTR12() public {
        _initTemp();
        _logCase("QA-RTR-12", unicode"多热钱包分别 claimFor");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 200 ether, 100 ether);

        // Register cexHw2
        vm.broadcast(adminPk);
        router.registerHotWallet(cexHw2);

        // Distribute OLD: cexHw1=60, cexHw2=40
        vm.startBroadcast(hotWalletPk);
        tOld.transfer(cexHw1, 60 ether);
        tOld.transfer(cexHw2, 40 ether);
        vm.stopBroadcast();

        // Both transfer to router
        vm.broadcast(cexHw1Pk);
        tOld.transfer(address(router), 60 ether);
        vm.broadcast(cexHw2Pk);
        tOld.transfer(address(router), 40 ether);

        // OPS claims for each
        uint256 supplyBefore = tOld.totalSupply();
        uint256 hw1UsdcBefore = tUsdc.balanceOf(cexHw1);
        uint256 hw1NewBefore = tNew.balanceOf(cexHw1);
        vm.broadcast(routerOpsPk);
        router.claimFor(id, cexHw1, 60 ether);

        uint256 hw2UsdcBefore = tUsdc.balanceOf(cexHw2);
        uint256 hw2NewBefore = tNew.balanceOf(cexHw2);
        vm.broadcast(routerOpsPk);
        router.claimFor(id, cexHw2, 40 ether);

        _assertDiff(hw1UsdcBefore, tUsdc.balanceOf(cexHw1), 180e6, "hw1 60% USDC");
        _assertDiff(hw2UsdcBefore, tUsdc.balanceOf(cexHw2), 120e6, "hw2 40% USDC");
        _assertDiff(hw1NewBefore, tNew.balanceOf(cexHw1), 120 ether, "hw1 60% NEW");
        _assertDiff(hw2NewBefore, tNew.balanceOf(cexHw2), 80 ether, "hw2 40% NEW");
        _assertEq(supplyBefore - tOld.totalSupply(), 100 ether, "100 old burned");
        _step("  PASS: each hw got correct pro-rata basket");
        _logPass();
    }

    // ── RTR-13: 合规封禁原子回滚 ──
    function test_RTR13() public {
        _initTemp();
        _logCase("QA-RTR-13", unicode"合规封禁热钱包原子回滚");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 200 ether, 100 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(cexHw1, 100 ether);

        // Block cexHw1 on tNew (reward leg)
        address[] memory arr = new address[](1);
        arr[0] = cexHw1;
        vm.broadcast(complianceOpsPk);
        compliance.blockUsers(address(tNew), arr);

        vm.broadcast(cexHw1Pk);
        tOld.transfer(address(router), 100 ether);

        uint256 routerOldBefore = tOld.balanceOf(address(router));
        uint256 hw1UsdcBefore = tUsdc.balanceOf(cexHw1);
        uint256 hw1NewBefore = tNew.balanceOf(cexHw1);

        // claimFor should revert atomically
        _expectRevertFrom(
            routerOps,
            address(router),
            abi.encodeWithSelector(CustodyClaimRouter.claimFor.selector, id, cexHw1, uint256(100 ether)),
            ComplianceRegistry.UserBlocked.selector
        );

        _assertEq(tOld.balanceOf(address(router)), routerOldBefore, "old still in router");
        _assertEq(tUsdc.balanceOf(cexHw1), hw1UsdcBefore, "no USDC leaked");
        _assertEq(tNew.balanceOf(cexHw1), hw1NewBefore, "no NEW leaked");

        // Cleanup: unblock
        vm.broadcast(complianceOpsPk);
        compliance.unblockUsers(address(tNew), arr);
        _step("  PASS: atomic rollback, old still in router");
        _logPass();
    }

    // ── RTR-14: 自授权保护 → SelfGrantNotAllowed ──
    function test_RTR14() public {
        _initTemp();
        _logCase("QA-RTR-14", unicode"自授权保护 → SelfGrantNotAllowed");

        _expectRevertFrom(
            admin,
            address(router),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, ROUTER_OPS_ROLE, admin),
            CustodyClaimRouter.SelfGrantNotAllowed.selector
        );
        _step("  PASS: SelfGrantNotAllowed");
        _logPass();
    }

    // ── helper ──
    function _findPkFor(address target) internal view returns (uint256) {
        if (target == admin) return adminPk;
        if (target == complianceOps) return complianceOpsPk;
        if (target == pauseOps) return pauseOpsPk;
        if (target == walletOps) return walletOpsPk;
        if (target == hotWallet) return hotWalletPk;
        if (target == userA) return userAPk;
        if (target == userB) return userBPk;
        revert("_findPkFor: unknown address");
    }
}
