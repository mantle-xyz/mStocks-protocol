// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {PrivatizationRegistry} from "../../src/privatization/PrivatizationRegistry.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {MockUSD} from "../../test/mocks/MockUSD.sol";

contract QAPrivatization is BaseQAScript {
    // ── from .env (deployed contracts) ──
    PrivatizationRegistry internal registry;
    ScaledToken internal prvOldToken;
    address internal registryOps;
    uint256 internal registryOpsPk;

    // ── temp resources (created per run) ──
    ScaledToken internal tOld;
    ScaledToken internal tNew;
    ScaledToken internal tCvr;
    MockUSD internal tUsdc;
    uint256 internal pid;

    bytes32 internal OPS_ROLE;
    bytes32 internal BURN_ROLE;

    // ── PRV-16 state (split across setup/verify) ──
    uint256 internal prv16Pid;
    ScaledToken internal prv16Old;

    bool internal _prvEnvLoaded;
    bool internal _tempDeployed;

    function _initEnv() internal {
        _loadEnv();
        if (_prvEnvLoaded) return;
        _prvEnvLoaded = true;
        _loadPrvEnv();
    }

    function _initTemp() internal {
        _initEnv();
        if (_tempDeployed) return;
        _tempDeployed = true;
        _deployTempStack();
    }

    function run() external {
        _initEnv();

        test_PRV01();
        test_PRV02();
        test_PRV03();
        _initTemp();
        test_PRV04();
        test_PRV05();
        test_PRV06();
        test_PRV07();
        test_PRV08();
        test_PRV09();
        test_PRV10();
        test_PRV11();
        test_PRV12();
        test_PRV13();
        test_PRV14();
        test_PRV15();
        test_PRV16_setup();
        test_PRV17();
        test_PRV18();
        test_PRV19();
        test_PRV20();
        test_PRV21();
        test_PRV22();
    }

    // ═══════════════════════════════════════════════
    //      Environment
    // ═══════════════════════════════════════════════

    function _loadPrvEnv() internal {
        registry = PrivatizationRegistry(vm.envAddress("REGISTRY_ADDR"));
        prvOldToken = ScaledToken(vm.envAddress("OLD_TOKEN_ADDR"));
        registryOpsPk = vm.envUint("REGISTRY_OPS_PK");
        registryOps = vm.addr(registryOpsPk);
        OPS_ROLE = registry.OPS_ROLE();
        BURN_ROLE = prvOldToken.BURN_ROLE();
    }

    // ═══════════════════════════════════════════════
    //      Temp stack for lifecycle tests
    // ═══════════════════════════════════════════════

    function _deployTempStack() internal {
        address[] memory ops = new address[](1);
        ops[0] = walletOps;

        // createToken is OPS_ROLE-gated on factory → walletOps signs
        vm.startBroadcast(walletOpsPk);
        tOld = ScaledToken(factory.createToken("Test Old", _uniqueSymbol("TOLD"), _uniqueSymbol("TMP"), admin, new address[](0), new address[](0), ops));
        tNew = ScaledToken(factory.createToken("Test New", _uniqueSymbol("TNEW"), _uniqueSymbol("TMP"), admin, new address[](0), new address[](0), ops));
        tCvr = ScaledToken(factory.createToken("Test CVR", _uniqueSymbol("TCVR"), _uniqueSymbol("TMP"), admin, new address[](0), new address[](0), ops));
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

    /// @dev Create a test program with 3 legs, fund + activate it.
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
    //      Verification Tests (PRV-01 ~ PRV-03)
    // ═══════════════════════════════════════════════

    function test_PRV01() public {
        _initEnv();
        _logCase("QA-PRV-01", unicode"验证 PrivatizationRegistry 部署");

        _assertEq(address(registry) != address(0), true, "registry deployed");
        _assertEq(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin), true, "admin has DEFAULT_ADMIN_ROLE");
        _step("  PASS: registry deployed, admin role correct");
        _logPass();
    }

    function test_PRV02() public {
        _initEnv();
        _logCase("QA-PRV-02", unicode"验证 OPS_ROLE + BURN_ROLE 已授");

        _assertEq(registry.hasRole(OPS_ROLE, registryOps), true, "registryOps has OPS_ROLE");
        _assertEq(prvOldToken.hasRole(BURN_ROLE, address(registry)), true, "registry has BURN_ROLE on oldToken");
        _step("  PASS: OPS_ROLE and BURN_ROLE wired correctly");
        _logPass();
    }

    function test_PRV03() public {
        _initEnv();
        _logCase("QA-PRV-03", unicode"验证 oldToken mintAllowed==false");

        _assertEq(prvOldToken.mintAllowed(), false, "oldToken mintAllowed");
        _step("  PASS: oldToken supply frozen");
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Lifecycle Tests (PRV-04 ~ PRV-22)
    // ═══════════════════════════════════════════════

    function test_PRV04() public {
        _initTemp();
        _logCase("QA-PRV-04", unicode"createProgram 多腿篮子");

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](3);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 300e6);
        legs[1] = PrivatizationRegistry.Leg(address(tNew), 200 ether);
        legs[2] = PrivatizationRegistry.Leg(address(tCvr), 100 ether);

        vm.broadcast(registryOpsPk);
        uint256 id = registry.createProgram(address(tOld), legs);

        (address storedOldToken,,,, uint8 state) = registry.programs(id);
        _assertEq(storedOldToken, address(tOld), "oldToken stored");
        _assertEq(uint256(state), uint256(PrivatizationRegistry.State.Created), "state==Created");
        _assertEq(registry.legsCount(id), 3, "legsCount");
        _step("  PASS: program created with 3 legs");
        _logPass();
    }

    function test_PRV05() public {
        _initTemp();
        _logCase("QA-PRV-05", unicode"fund 各腿 + reserved 累加");

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 500e6);
        vm.broadcast(registryOpsPk);
        uint256 id = registry.createProgram(address(tOld), legs);

        _fundLeg(id, address(tUsdc), 200e6);
        _assertEq(registry.reserved(id, address(tUsdc)), 200e6, "reserved after first fund");

        _fundLeg(id, address(tUsdc), 300e6);
        _assertEq(registry.reserved(id, address(tUsdc)), 500e6, "reserved after second fund");
        _step("  PASS: reserved accumulates correctly");
        _logPass();
    }

    function test_PRV06() public {
        _initTemp();
        _logCase("QA-PRV-06", unicode"configureProgram 激活");

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 100e6);
        vm.broadcast(registryOpsPk);
        uint256 id = registry.createProgram(address(tOld), legs);

        uint64 start = uint64(block.timestamp);
        uint64 deadline = uint64(block.timestamp + 7 days);
        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: start,
            deadline: deadline,
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.broadcast(registryOpsPk);
        registry.configureProgram(id, cfg);

        (,uint64 storedStart, uint64 storedDeadline,, uint8 state) = registry.programs(id);
        _assertEq(uint256(state), uint256(PrivatizationRegistry.State.Active), "state==Active");
        _assertEq(uint256(storedStart), uint256(start), "startTime");
        _assertEq(uint256(storedDeadline), uint256(deadline), "deadline");
        _step("  PASS: program configured and active");
        _logPass();
    }

    function test_PRV07() public {
        _initTemp();
        _logCase("QA-PRV-07", unicode"主流程 claim");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 200 ether, 100 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 100 ether);

        uint256 usdcBefore = tUsdc.balanceOf(userA);
        uint256 newBefore = tNew.balanceOf(userA);
        uint256 cvrBefore = tCvr.balanceOf(userA);

        vm.startBroadcast(userAPk);
        tOld.approve(address(registry), 100 ether);
        registry.claim(id, 100 ether);
        vm.stopBroadcast();

        _assertEq(tOld.balanceOf(userA), 0, "old burned");
        _assertDiff(usdcBefore, tUsdc.balanceOf(userA), 300e6, "usdc received");
        _assertDiff(newBefore, tNew.balanceOf(userA), 200 ether, "new received");
        _assertDiff(cvrBefore, tCvr.balanceOf(userA), 100 ether, "cvr received");
        _step("  PASS: claim + basket distribution correct");
        _logPass();
    }

    function test_PRV08() public {
        _initTemp();
        _logCase("QA-PRV-08", unicode"多持有人 60/40 比例分配");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 200 ether, 100 ether);

        vm.startBroadcast(hotWalletPk);
        tOld.transfer(userA, 60 ether);
        tOld.transfer(userB, 40 ether);
        vm.stopBroadcast();

        uint256 usdcA0 = tUsdc.balanceOf(userA);
        uint256 usdcB0 = tUsdc.balanceOf(userB);
        uint256 newA0 = tNew.balanceOf(userA);
        uint256 newB0 = tNew.balanceOf(userB);
        uint256 supplyBefore = tOld.totalSupply();

        vm.startBroadcast(userAPk);
        tOld.approve(address(registry), 60 ether);
        registry.claim(id, 60 ether);
        vm.stopBroadcast();

        vm.startBroadcast(userBPk);
        tOld.approve(address(registry), 40 ether);
        registry.claim(id, 40 ether);
        vm.stopBroadcast();

        _assertDiff(usdcA0, tUsdc.balanceOf(userA), 180e6, "userA 60% USDC");
        _assertDiff(usdcB0, tUsdc.balanceOf(userB), 120e6, "userB 40% USDC");
        _assertDiff(newA0, tNew.balanceOf(userA), 120 ether, "userA 60% NEW");
        _assertDiff(newB0, tNew.balanceOf(userB), 80 ether, "userB 40% NEW");
        _assertEq(supplyBefore - tOld.totalSupply(), 100 ether, "all old burned");
        _step("  PASS: 60/40 pro-rata distribution correct");
        _logPass();
    }

    function test_PRV09() public {
        _initTemp();
        _logCase("QA-PRV-09", unicode"分批 claim 等价");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 100 ether, 50 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 100 ether);

        uint256 usdcBefore = tUsdc.balanceOf(userA);
        uint256 supplyBefore = tOld.totalSupply();

        vm.startBroadcast(userAPk);
        tOld.approve(address(registry), 100 ether);
        registry.claim(id, 30 ether);
        registry.claim(id, 70 ether);
        vm.stopBroadcast();

        _assertDiff(usdcBefore, tUsdc.balanceOf(userA), 300e6, "batch claim total == single claim total");
        _assertEq(supplyBefore - tOld.totalSupply(), 100 ether, "all burned");
        _step("  PASS: 30+70 == 100 (no rounding loss at clean boundaries)");
        _logPass();
    }

    function test_PRV10() public {
        _initTemp();
        _logCase("QA-PRV-10", unicode"dust 1 wei → NothingToDeliver");

        _unfreezeToken(tOld);
        vm.broadcast(walletOpsPk);
        vault.mint(address(tOld), hotWallet, 1);

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 1);
        vm.broadcast(registryOpsPk);
        uint256 id = registry.createProgram(address(tOld), legs);

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: 1e18,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.broadcast(registryOpsPk);
        registry.configureProgram(id, cfg);

        _fundLeg(id, address(tUsdc), 1);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 1);

        vm.broadcast(userAPk);
        tOld.approve(address(registry), 1);

        _expectRevertFrom(
            userA,
            address(registry),
            abi.encodeWithSelector(PrivatizationRegistry.claim.selector, id, uint256(1)),
            PrivatizationRegistry.NothingToDeliver.selector
        );
        _step("  PASS: NothingToDeliver for dust");
        _logPass();
    }

    function test_PRV11() public {
        _initTemp();
        _logCase("QA-PRV-11", unicode"CVR 二次兑付");

        // Program A: OLD → basket (USDC + NEW + CVR)
        uint256 idA = _createActiveFundedProgram(100 ether, 300e6, 50 ether, 100 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 100 ether);

        uint256 cvrBeforeA = tCvr.balanceOf(userA);
        vm.startBroadcast(userAPk);
        tOld.approve(address(registry), 100 ether);
        registry.claim(idA, 100 ether);
        vm.stopBroadcast();

        _assertDiff(cvrBeforeA, tCvr.balanceOf(userA), 100 ether, "userA received CVR from programA");

        // Program B: CVR → USDC (second redemption)
        ScaledToken cvrAsOld = tCvr;
        bytes32 cvrBurnRole = cvrAsOld.BURN_ROLE();
        vm.broadcast(adminPk);
        cvrAsOld.grantRole(cvrBurnRole, address(registry));

        PrivatizationRegistry.Leg[] memory legs2 = new PrivatizationRegistry.Leg[](1);
        legs2[0] = PrivatizationRegistry.Leg(address(tUsdc), 500e6);
        vm.broadcast(registryOpsPk);
        uint256 idB = registry.createProgram(address(cvrAsOld), legs2);

        PrivatizationRegistry.Program memory cfg2 = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.broadcast(registryOpsPk);
        registry.configureProgram(idB, cfg2);

        _fundLeg(idB, address(tUsdc), 500e6);

        uint256 usdcBefore = tUsdc.balanceOf(userA);
        uint256 cvrBeforeB = cvrAsOld.balanceOf(userA);
        vm.startBroadcast(userAPk);
        cvrAsOld.approve(address(registry), 100 ether);
        registry.claim(idB, 100 ether);
        vm.stopBroadcast();

        _assertDiff(usdcBefore, tUsdc.balanceOf(userA), 500e6, "userA received USDC from CVR redemption");
        _assertEq(cvrAsOld.balanceOf(userA), cvrBeforeB - 100 ether, "CVR burned");
        _step("  PASS: CVR double redemption successful");
        _logPass();
    }

    function test_PRV12() public {
        _initTemp();
        _logCase("QA-PRV-12", unicode"备付不足 → InsufficientReserved");

        _unfreezeToken(tOld);
        vm.broadcast(walletOpsPk);
        vault.mint(address(tOld), hotWallet, 100 ether);

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 300e6);
        vm.broadcast(registryOpsPk);
        uint256 id = registry.createProgram(address(tOld), legs);

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.broadcast(registryOpsPk);
        registry.configureProgram(id, cfg);

        // Fund only 100e6 of 300e6 required
        _fundLeg(id, address(tUsdc), 100e6);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 100 ether);

        vm.broadcast(userAPk);
        tOld.approve(address(registry), 100 ether);

        _expectRevertFrom(
            userA,
            address(registry),
            abi.encodeWithSelector(PrivatizationRegistry.claim.selector, id, uint256(100 ether)),
            PrivatizationRegistry.InsufficientReserved.selector
        );
        _step("  PASS: InsufficientReserved");
        _logPass();
    }

    function test_PRV13() public {
        _initTemp();
        _logCase("QA-PRV-13", unicode"合规封禁 claim 回滚");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 200 ether, 100 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 100 ether);

        // Block userA on tNew (reward leg)
        address[] memory arr = new address[](1);
        arr[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.blockUsers(address(tNew), arr);

        vm.broadcast(userAPk);
        tOld.approve(address(registry), 100 ether);

        uint256 oldBefore = tOld.balanceOf(userA);
        uint256 usdcBefore = tUsdc.balanceOf(userA);

        _expectRevertFrom(
            userA,
            address(registry),
            abi.encodeWithSelector(PrivatizationRegistry.claim.selector, id, uint256(100 ether)),
            ComplianceRegistry.UserBlocked.selector
        );

        _assertEq(tOld.balanceOf(userA), oldBefore, "old still with userA");
        _assertEq(tUsdc.balanceOf(userA), usdcBefore, "no USDC leaked");

        // Cleanup
        vm.broadcast(complianceOpsPk);
        compliance.unblockUsers(address(tNew), arr);
        _step("  PASS: atomic rollback, old still with holder");
        _logPass();
    }

    function test_PRV14() public {
        _initTemp();
        _logCase("QA-PRV-14", unicode"解封后重试成功");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 200 ether, 100 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 100 ether);

        // Block then unblock
        address[] memory arr = new address[](1);
        arr[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.blockUsers(address(tNew), arr);
        vm.broadcast(complianceOpsPk);
        compliance.unblockUsers(address(tNew), arr);

        vm.startBroadcast(userAPk);
        tOld.approve(address(registry), 100 ether);
        registry.claim(id, 100 ether);
        vm.stopBroadcast();

        _assertEq(tOld.balanceOf(userA), 0, "old burned");
        _assertGt(tUsdc.balanceOf(userA), 0, "usdc received");
        _step("  PASS: claim succeeds after unblock");
        _logPass();
    }

    function test_PRV15() public {
        _initTemp();
        _logCase("QA-PRV-15", unicode"startTime 之前 claim → ClaimNotStarted");

        _unfreezeToken(tOld);
        vm.broadcast(walletOpsPk);
        vault.mint(address(tOld), hotWallet, 100 ether);

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 300e6);
        vm.broadcast(registryOpsPk);
        uint256 id = registry.createProgram(address(tOld), legs);

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp + 3600),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.broadcast(registryOpsPk);
        registry.configureProgram(id, cfg);

        _fundLeg(id, address(tUsdc), 300e6);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 10 ether);

        vm.broadcast(userAPk);
        tOld.approve(address(registry), 10 ether);

        _expectRevertFrom(
            userA,
            address(registry),
            abi.encodeWithSelector(PrivatizationRegistry.claim.selector, id, uint256(10 ether)),
            PrivatizationRegistry.ClaimNotStarted.selector
        );
        _step("  PASS: ClaimNotStarted");
        _logPass();
    }

    // PRV-16 splits into setup + verify for manual time-wait
    function test_PRV16_setup() public {
        _initTemp();
        _logCase("QA-PRV-16", unicode"deadline 后 claim + sweep (setup: deadline=60s)");

        _unfreezeToken(tOld);
        vm.broadcast(walletOpsPk);
        vault.mint(address(tOld), hotWallet, 100 ether);

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 300e6);
        vm.broadcast(registryOpsPk);
        prv16Pid = registry.createProgram(address(tOld), legs);
        prv16Old = tOld;

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 60),
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.broadcast(registryOpsPk);
        registry.configureProgram(prv16Pid, cfg);

        _fundLeg(prv16Pid, address(tUsdc), 300e6);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 10 ether);

        _step(string.concat("  setup done. programId = ", vm.toString(prv16Pid)));
        _step("  deadline = block.timestamp + 60s. Wait 70s+ then call test_PRV16_verify()");
        _logPass();
    }

    function test_PRV16_verify() public {
        _initEnv();
        _logCase("QA-PRV-16", unicode"deadline 后 claim + sweep (verify)");

        // PRV-16 verify needs the programId from setup
        // Since state doesn't persist across separate forge script calls,
        // read from the latest programCount (0-indexed, so last id = count - 1)
        uint256 verifyPid = registry.programCount() - 1;
        (address verifyOldToken,,,, uint8 state) = registry.programs(verifyPid);
        require(state == uint8(PrivatizationRegistry.State.Active), "PRV-16: program not Active, wrong pid?");

        ScaledToken verifyOld = ScaledToken(verifyOldToken);

        _step("[Step 1] userA tries claim after deadline");
        vm.broadcast(userAPk);
        verifyOld.approve(address(registry), 10 ether);
        _expectRevertFrom(
            userA,
            address(registry),
            abi.encodeWithSelector(PrivatizationRegistry.claim.selector, verifyPid, uint256(10 ether)),
            PrivatizationRegistry.ClaimClosed.selector
        );
        _step("  ClaimClosed verified");

        _step("[Step 2] OPS sweeps unclaimed");
        vm.broadcast(registryOpsPk);
        registry.sweepUnclaimed(verifyPid, admin);

        (,,,, uint8 stateAfter) = registry.programs(verifyPid);
        _assertEq(uint256(stateAfter), uint256(PrivatizationRegistry.State.Closed), "state==Closed");
        _step("  PASS: sweep successful, state==Closed");
        _logPass();
    }

    function test_PRV17() public {
        _initTemp();
        _logCase("QA-PRV-17", unicode"configureProgram 零值保持");

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 100e6);
        vm.broadcast(registryOpsPk);
        uint256 id = registry.createProgram(address(tOld), legs);

        uint64 originalStart = uint64(block.timestamp);
        uint64 originalDeadline = uint64(block.timestamp + 7 days);
        PrivatizationRegistry.Program memory cfg1 = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: originalStart,
            deadline: originalDeadline,
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.broadcast(registryOpsPk);
        registry.configureProgram(id, cfg1);

        // Patch only deadline, keep others zero (preserve)
        uint64 newDeadline = uint64(block.timestamp + 14 days);
        PrivatizationRegistry.Program memory cfg2 = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: 0,
            deadline: newDeadline,
            oldSupplySnapshot: 0,
            state: 0
        });
        vm.broadcast(registryOpsPk);
        registry.configureProgram(id, cfg2);

        (, uint64 storedStart, uint64 storedDeadline,, uint8 state) = registry.programs(id);
        _assertEq(uint256(storedStart), uint256(originalStart), "startTime preserved");
        _assertEq(uint256(storedDeadline), uint256(newDeadline), "deadline updated");
        _assertEq(uint256(state), uint256(PrivatizationRegistry.State.Active), "state preserved");
        _step("  PASS: zero-value fields preserved, only deadline updated");
        _logPass();
    }

    function test_PRV18() public {
        _initTemp();
        _logCase("QA-PRV-18", unicode"空腿 → NoLegs");

        PrivatizationRegistry.Leg[] memory emptyLegs = new PrivatizationRegistry.Leg[](0);
        _expectRevertFrom(
            registryOps,
            address(registry),
            abi.encodeWithSelector(PrivatizationRegistry.createProgram.selector, address(tOld), emptyLegs),
            PrivatizationRegistry.NoLegs.selector
        );
        _step("  PASS: NoLegs");
        _logPass();
    }

    function test_PRV19() public {
        _initTemp();
        _logCase("QA-PRV-19", unicode"多次 fund 累加");

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 300e6);
        vm.broadcast(registryOpsPk);
        uint256 id = registry.createProgram(address(tOld), legs);

        _fundLeg(id, address(tUsdc), 100e6);
        _assertEq(registry.reserved(id, address(tUsdc)), 100e6, "after fund 100");

        _fundLeg(id, address(tUsdc), 200e6);
        _assertEq(registry.reserved(id, address(tUsdc)), 300e6, "after fund 200 more");
        _step("  PASS: reserved == 300e6");
        _logPass();
    }

    function test_PRV20() public {
        _initTemp();
        _logCase("QA-PRV-20", unicode"admin 不能 createProgram");

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(tUsdc), 100e6);

        _expectRevertFrom(
            admin,
            address(registry),
            abi.encodeWithSelector(PrivatizationRegistry.createProgram.selector, address(tOld), legs),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: admin cannot createProgram");
        _logPass();
    }

    function test_PRV21() public {
        _initTemp();
        _logCase("QA-PRV-21", unicode"自授权保护 → SelfGrantNotAllowed");

        _expectRevertFrom(
            admin,
            address(registry),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, OPS_ROLE, admin),
            PrivatizationRegistry.SelfGrantNotAllowed.selector
        );
        _step("  PASS: SelfGrantNotAllowed");
        _logPass();
    }

    function test_PRV22() public {
        _initTemp();
        _logCase("QA-PRV-22", unicode"previewClaim 准确性");

        uint256 id = _createActiveFundedProgram(100 ether, 300e6, 200 ether, 100 ether);

        vm.broadcast(hotWalletPk);
        tOld.transfer(userA, 50 ether);

        uint256[] memory preview = registry.previewClaim(id, 50 ether);
        _assertEq(preview.length, 3, "preview length");

        uint256 usdcBefore = tUsdc.balanceOf(userA);
        uint256 newBefore = tNew.balanceOf(userA);
        uint256 cvrBefore = tCvr.balanceOf(userA);

        vm.startBroadcast(userAPk);
        tOld.approve(address(registry), 50 ether);
        registry.claim(id, 50 ether);
        vm.stopBroadcast();

        _assertEq(tUsdc.balanceOf(userA) - usdcBefore, preview[0], "USDC matches preview");
        _assertEq(tNew.balanceOf(userA) - newBefore, preview[1], "NEW matches preview");
        _assertEq(tCvr.balanceOf(userA) - cvrBefore, preview[2], "CVR matches preview");
        _step("  PASS: actual claim matches previewClaim exactly");
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
