// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ScaledTokenBeaconDeployer} from "../../src/scaledToken/ScaledTokenBeaconDeployer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {PrivatizationRegistry} from "../../src/privatization/PrivatizationRegistry.sol";
import {MockUSD} from "../mocks/MockUSD.sol";

contract PrivatizationQA is Test {
    string constant MODULE = unicode"PrivatizationRegistry";
    uint64 constant WEEK = 7 days;

    // ── logging ──
    string internal _caseId;
    string internal _caseName;

    function _logCase(string memory id, string memory name) internal {
        _caseId = id;
        _caseName = name;
        console2.log("========================================");
        console2.log(string.concat("testcase id: ", id));
        console2.log(string.concat("testcase name: ", name));
        console2.log("========================================");
    }

    function _step(string memory msg_) internal pure {
        console2.log(msg_);
    }

    function _logPass() internal pure {
        console2.log("----------------------------------------");
        console2.log("test result: passed");
    }

    // ── protocol stack ──
    ComplianceRegistry internal compliance;
    PauseRegistry internal pauseManager;
    ScaledTokenFactory internal factory;
    PrivatizationRegistry internal registry;
    MockUSD internal usdc;

    ScaledToken internal oldToken;
    ScaledToken internal newToken;
    ScaledToken internal cvr;

    // ── accounts ──
    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal ops = makeAddr("ops");
    address internal complianceOps = makeAddr("complianceOps");
    address internal tokenOps = makeAddr("tokenOps");
    address internal custody = makeAddr("custody");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal stranger = makeAddr("stranger");

    bytes32 internal BURN_ROLE;
    bytes32 internal OPS_ROLE;

    function setUp() public virtual {
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = _deployFactory(address(compliance), address(pauseManager), admin, proxyAdmin, 24 hours);
        factory.grantRole(factory.OPS_ROLE(), address(this));
        usdc = new MockUSD();
        address[] memory initOps = new address[](1);
        initOps[0] = ops;
        registry = PrivatizationRegistry(
            address(
                new ERC1967Proxy(
                    address(new PrivatizationRegistry()),
                    abi.encodeCall(PrivatizationRegistry.initialize, (admin, initOps))
                )
            )
        );
        vm.stopPrank();

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        address[] memory none = new address[](0);
        oldToken = ScaledToken(factory.createToken("Old Co", "OLD", "US0000000001", admin, issuers, none, none));
        newToken = ScaledToken(factory.createToken("New Co", "NEW", "US0000000002", admin, issuers, none, none));
        cvr = ScaledToken(factory.createToken("Deal CVR", "CVR", "US0000000003", admin, issuers, none, none));

        vm.startPrank(admin);
        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        vm.stopPrank();

        BURN_ROLE = oldToken.BURN_ROLE();
        OPS_ROLE = registry.OPS_ROLE();
    }

    // ── helpers ──

    function _deployFactory(
        address _compliance, address _pauseManager, address _owner, address _proxyAdmin, uint256 _notice
    ) internal returns (ScaledTokenFactory) {
        ScaledTokenFactory impl = new ScaledTokenFactory(new ScaledTokenBeaconDeployer());
        return ScaledTokenFactory(payable(address(new TransparentUpgradeableProxy(
            address(impl), _proxyAdmin,
            abi.encodeWithSelector(ScaledTokenFactory.initialize.selector, _compliance, _pauseManager, _owner, _proxyAdmin, _notice)
        ))));
    }

    function _seed(ScaledToken t, address to, uint256 amount) internal {
        t.mint(amount);
        t.transfer(to, amount);
    }

    function _fund(uint256 programId, ScaledToken t, uint256 amount) internal {
        t.mint(amount);
        t.transfer(ops, amount);
        vm.startPrank(ops);
        t.approve(address(registry), amount);
        registry.fund(programId, address(t), amount);
        vm.stopPrank();
    }

    function _fundUsd(uint256 programId, uint256 amount) internal {
        usdc.mint(ops, amount);
        vm.startPrank(ops);
        usdc.approve(address(registry), amount);
        registry.fund(programId, address(usdc), amount);
        vm.stopPrank();
    }

    function _freeze(ScaledToken t) internal {
        bytes32 opsRole = t.OPS_ROLE();
        vm.startPrank(admin);
        t.grantRole(BURN_ROLE, address(registry));
        t.grantRole(opsRole, tokenOps);
        vm.stopPrank();
        vm.prank(tokenOps);
        t.setMintAllowed(false);
    }

    function _configure(uint256 programId, uint64 startTime, uint64 deadline) internal {
        (address oldTok,,,,) = registry.programs(programId);
        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: startTime,
            deadline: deadline,
            oldSupplySnapshot: ScaledToken(oldTok).totalSupply(),
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.prank(ops);
        registry.configureProgram(programId, cfg);
    }

    function _activate(uint256 programId, ScaledToken old) internal {
        _freeze(old);
        _configure(programId, uint64(block.timestamp), uint64(block.timestamp + WEEK));
    }

    function _legs3() internal view returns (PrivatizationRegistry.Leg[] memory legs) {
        legs = new PrivatizationRegistry.Leg[](3);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 300e6);
        legs[1] = PrivatizationRegistry.Leg(address(newToken), 200 ether);
        legs[2] = PrivatizationRegistry.Leg(address(cvr), 100 ether);
    }

    function _blockOnNew(address who) internal {
        address[] memory arr = new address[](1);
        arr[0] = who;
        vm.prank(complianceOps);
        compliance.blockUsers(address(newToken), arr);
    }

    function _createProgram() internal returns (uint256) {
        vm.prank(ops);
        return registry.createProgram(address(oldToken), _legs3());
    }

    function _fundAll(uint256 pid) internal {
        _fundUsd(pid, 300e6);
        _fund(pid, newToken, 200 ether);
        _fund(pid, cvr, 100 ether);
    }

    // ═══════════════════════════════════════════════
    //                    TESTS
    // ═══════════════════════════════════════════════

    // ── PRV-01 ──
    function test_PRV01_FullLifecycleCreateToSweep() public {
        _logCase("PRV-01", unicode"主流程全生命周期");

        _step("[Step 1] seed userA with 100e18 oldToken");
        _seed(oldToken, userA, 100 ether);

        _step("[Step 2] createProgram");
        uint256 pid = _createProgram();
        (,,,,uint8 state) = registry.programs(pid);
        assertEq(state, uint8(PrivatizationRegistry.State.Created));

        _step("[Step 3] freeze + configure (activate)");
        _activate(pid, oldToken);
        (,,,,state) = registry.programs(pid);
        assertEq(state, uint8(PrivatizationRegistry.State.Active));

        _step("[Step 4] fund all legs");
        _fundAll(pid);

        _step("[Step 5] userA claims 100e18");
        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(pid, 100 ether);
        vm.stopPrank();
        assertEq(usdc.balanceOf(userA), 300e6);
        assertEq(newToken.balanceOf(userA), 200 ether);
        assertEq(cvr.balanceOf(userA), 100 ether);
        assertEq(oldToken.totalSupply(), 0);

        _step("[Step 6] warp past deadline, sweep");
        vm.warp(block.timestamp + WEEK + 1);
        vm.prank(ops);
        registry.sweepUnclaimed(pid, custody);
        (,,,,state) = registry.programs(pid);
        assertEq(state, uint8(PrivatizationRegistry.State.Closed));
        _step("  PASS: full lifecycle completed");

        _logPass();
    }

    // ── PRV-02 ──
    function test_PRV02_ProRata60_40Split() public {
        _logCase("PRV-02", unicode"多持有人 60/40 比例分配");

        _seed(oldToken, userA, 60 ether);
        _seed(oldToken, userB, 40 ether);
        uint256 pid = _createProgram();
        _activate(pid, oldToken);
        _fundAll(pid);

        _step("[Step 1] userA claims 60e18 (60%)");
        vm.startPrank(userA);
        oldToken.approve(address(registry), 60 ether);
        registry.claim(pid, 60 ether);
        vm.stopPrank();
        assertEq(usdc.balanceOf(userA), 180e6);
        assertEq(newToken.balanceOf(userA), 120 ether);
        assertEq(cvr.balanceOf(userA), 60 ether);

        _step("[Step 2] userB claims 40e18 (40%)");
        vm.startPrank(userB);
        oldToken.approve(address(registry), 40 ether);
        registry.claim(pid, 40 ether);
        vm.stopPrank();
        assertEq(usdc.balanceOf(userB), 120e6);
        assertEq(newToken.balanceOf(userB), 80 ether);
        assertEq(cvr.balanceOf(userB), 40 ether);

        _step("[Step 3] verify no over-distribution");
        assertEq(registry.reserved(pid, address(usdc)), 0);
        assertEq(registry.reserved(pid, address(newToken)), 0);
        assertEq(registry.reserved(pid, address(cvr)), 0);
        assertEq(oldToken.totalSupply(), 0);
        _step("  PASS: 60/40 split correct, reserves zeroed");

        _logPass();
    }

    // ── PRV-03 ──
    function test_PRV03_ProgramIsolation() public {
        _logCase("PRV-03", unicode"program 间资金隔离");

        _seed(oldToken, userA, 100 ether);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 500e6);

        vm.prank(ops);
        uint256 p0 = registry.createProgram(address(oldToken), legs);
        vm.prank(ops);
        uint256 p1 = registry.createProgram(address(newToken), legs);
        _activate(p0, oldToken);

        _fundUsd(p0, 500e6);
        _fundUsd(p1, 999e6);

        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(p0, 100 ether);
        vm.stopPrank();

        assertEq(usdc.balanceOf(userA), 500e6);
        assertEq(registry.reserved(p0, address(usdc)), 0);
        assertEq(registry.reserved(p1, address(usdc)), 999e6, "sibling untouched");
        _step("  PASS: programs isolated");

        _logPass();
    }

    // ── PRV-04 ──
    function test_PRV04_InsufficientReservedRevert() public {
        _logCase("PRV-04", unicode"备付不足 revert");

        _seed(oldToken, userA, 100 ether);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 500e6);
        vm.prank(ops);
        uint256 pid = registry.createProgram(address(oldToken), legs);
        _activate(pid, oldToken);
        _fundUsd(pid, 100e6);

        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.InsufficientReserved.selector);
        registry.claim(pid, 100 ether);
        vm.stopPrank();
        _step("  PASS: InsufficientReserved");

        _logPass();
    }

    // ── PRV-05 ──
    function test_PRV05_ComplianceBlockedClaimRevert() public {
        _logCase("PRV-05", unicode"合规封禁 claim revert");

        _seed(oldToken, userB, 100 ether);
        uint256 pid = _createProgram();
        _activate(pid, oldToken);
        _fundAll(pid);
        _blockOnNew(userB);

        vm.startPrank(userB);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        registry.claim(pid, 100 ether);
        vm.stopPrank();
        assertEq(oldToken.balanceOf(userB), 100 ether, "old not taken on failed claim");
        _step("  PASS: compliance block rolls back entire claim");

        _logPass();
    }

    // ── PRV-06 ──
    function test_PRV06_ClaimBeforeStartReverts() public {
        _logCase("PRV-06", unicode"startTime 前 claim revert");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();
        _freeze(oldToken);
        _configure(pid, uint64(block.timestamp + 1 days), uint64(block.timestamp + WEEK));
        _fundAll(pid);

        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.ClaimNotStarted.selector);
        registry.claim(pid, 100 ether);
        vm.stopPrank();
        _step("  PASS: ClaimNotStarted");

        _logPass();
    }

    // ── PRV-07 ──
    function test_PRV07_ClaimAfterDeadlineReverts() public {
        _logCase("PRV-07", unicode"deadline 后 claim revert + sweep");

        _seed(oldToken, userA, 100 ether);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 500e6);
        vm.prank(ops);
        uint256 pid = registry.createProgram(address(oldToken), legs);
        _freeze(oldToken);
        _configure(pid, uint64(block.timestamp), uint64(block.timestamp + 1 days));
        _fundUsd(pid, 500e6);

        vm.expectRevert(PrivatizationRegistry.ClaimStillOpen.selector);
        vm.prank(ops);
        registry.sweepUnclaimed(pid, custody);

        vm.warp(block.timestamp + 2 days);
        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.ClaimClosed.selector);
        registry.claim(pid, 100 ether);
        vm.stopPrank();

        vm.prank(ops);
        registry.sweepUnclaimed(pid, custody);
        assertEq(usdc.balanceOf(custody), 500e6);
        assertEq(registry.reserved(pid, address(usdc)), 0);
        _step("  PASS: ClaimClosed + sweep successful");

        _logPass();
    }

    // ── PRV-08 ──
    function test_PRV08_DustLegNothingToDeliver() public {
        _logCase("PRV-08", unicode"dust leg NothingToDeliver");

        _seed(oldToken, userA, 1);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 1);
        vm.prank(ops);
        uint256 pid = registry.createProgram(address(oldToken), legs);

        _freeze(oldToken);
        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + WEEK),
            oldSupplySnapshot: 1e18,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.prank(ops);
        registry.configureProgram(pid, cfg);

        usdc.mint(ops, 1);
        vm.startPrank(ops);
        usdc.approve(address(registry), 1);
        registry.fund(pid, address(usdc), 1);
        vm.stopPrank();

        vm.startPrank(userA);
        oldToken.approve(address(registry), 1);
        vm.expectRevert(PrivatizationRegistry.NothingToDeliver.selector);
        registry.claim(pid, 1);
        vm.stopPrank();
        _step("  PASS: NothingToDeliver for dust");

        _logPass();
    }

    // ── PRV-09 ──
    function test_PRV09_BatchClaimEquivalence() public {
        _logCase("PRV-09", unicode"分批 claim 等价");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();
        _activate(pid, oldToken);
        _fundAll(pid);

        uint256 snap = vm.snapshot();

        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(pid, 30 ether);
        registry.claim(pid, 70 ether);
        vm.stopPrank();
        uint256 splitUsdc = usdc.balanceOf(userA);
        uint256 splitNew = newToken.balanceOf(userA);
        uint256 splitCvr = cvr.balanceOf(userA);

        vm.revertTo(snap);

        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(pid, 100 ether);
        vm.stopPrank();
        uint256 fullUsdc = usdc.balanceOf(userA);
        uint256 fullNew = newToken.balanceOf(userA);
        uint256 fullCvr = cvr.balanceOf(userA);

        assertApproxEqAbs(splitUsdc, fullUsdc, 3);
        assertApproxEqAbs(splitNew, fullNew, 3);
        assertApproxEqAbs(splitCvr, fullCvr, 3);
        assertLe(splitUsdc, fullUsdc);
        assertLe(splitNew, fullNew);
        assertLe(splitCvr, fullCvr);
        _step("  PASS: split claim <= full claim (rounding)");

        _logPass();
    }

    // ── PRV-10 ──
    function test_PRV10_ParallelPrograms() public {
        _logCase("PRV-10", unicode"多 program 并行");

        ScaledToken oldToken2 = ScaledToken(
            factory.createToken("Old Co 2", "OLD2", "US0000000010", admin, _self(), new address[](0), new address[](0))
        );
        _seed(oldToken, userA, 100 ether);
        _seed(oldToken2, userB, 50 ether);

        uint256 pid1 = _createProgram();
        PrivatizationRegistry.Leg[] memory legs2 = new PrivatizationRegistry.Leg[](1);
        legs2[0] = PrivatizationRegistry.Leg(address(usdc), 1000e6);
        vm.prank(ops);
        uint256 pid2 = registry.createProgram(address(oldToken2), legs2);

        _activate(pid1, oldToken);
        _fundAll(pid1);

        _freeze(oldToken2);
        _configure(pid2, uint64(block.timestamp), uint64(block.timestamp + WEEK));
        _fundUsd(pid2, 1000e6);

        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(pid1, 100 ether);
        vm.stopPrank();

        vm.startPrank(userB);
        oldToken2.approve(address(registry), 50 ether);
        registry.claim(pid2, 50 ether);
        vm.stopPrank();

        assertEq(usdc.balanceOf(userA), 300e6);
        assertEq(usdc.balanceOf(userB), 1000e6);
        _step("  PASS: parallel programs independent");

        _logPass();
    }

    // ── PRV-11 ──
    function test_PRV11_MultipleFundSameLeg() public {
        _logCase("PRV-11", unicode"多次 fund 同一腿");

        _seed(oldToken, userA, 100 ether);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 500e6);
        vm.prank(ops);
        uint256 pid = registry.createProgram(address(oldToken), legs);
        _activate(pid, oldToken);

        _fundUsd(pid, 200e6);
        _fundUsd(pid, 300e6);
        assertEq(registry.reserved(pid, address(usdc)), 500e6);
        _step("  PASS: multiple fund accumulates");

        _logPass();
    }

    // ── PRV-12 ──
    function test_PRV12_ConfigurePatchSemantics() public {
        _logCase("PRV-12", unicode"configureProgram 零值保留");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();
        _freeze(oldToken);

        uint64 start = uint64(block.timestamp);
        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: start,
            deadline: uint64(block.timestamp + WEEK),
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.prank(ops);
        registry.configureProgram(pid, cfg);

        uint64 newDeadline = uint64(block.timestamp + 2 * WEEK);
        PrivatizationRegistry.Program memory patch = PrivatizationRegistry.Program({
            oldToken: address(0), startTime: 0, deadline: newDeadline, oldSupplySnapshot: 0, state: 0
        });
        vm.prank(ops);
        registry.configureProgram(pid, patch);

        (address oldTok, uint64 st, uint64 dl, uint256 snap, uint8 state) = registry.programs(pid);
        assertEq(oldTok, address(oldToken));
        assertEq(st, start);
        assertEq(dl, newDeadline);
        assertEq(snap, 100 ether);
        assertEq(state, uint8(PrivatizationRegistry.State.Active));
        _step("  PASS: zero fields kept, non-zero overwritten");

        _logPass();
    }

    // ── PRV-13 ──
    function test_PRV13_FullClaimZerosReserved() public {
        _logCase("PRV-13", unicode"全量 claim 后 reserved 归零");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();
        _activate(pid, oldToken);
        _fundAll(pid);

        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(pid, 100 ether);
        vm.stopPrank();

        assertEq(registry.reserved(pid, address(usdc)), 0);
        assertEq(registry.reserved(pid, address(newToken)), 0);
        assertEq(registry.reserved(pid, address(cvr)), 0);
        _step("  PASS: all reserves zeroed");

        _logPass();
    }

    // ── PRV-14 ──
    function test_PRV14_CreateProgramOpsOnly() public {
        _logCase("PRV-14", unicode"createProgram 仅 OPS");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, OPS_ROLE)
        );
        registry.createProgram(address(oldToken), _legs3());

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPS_ROLE)
        );
        registry.createProgram(address(oldToken), _legs3());
        _step("  PASS: admin and stranger rejected");

        _logPass();
    }

    // ── PRV-15 ──
    function test_PRV15_FundOpsOnly() public {
        _logCase("PRV-15", unicode"fund 仅 OPS");

        uint256 pid = _createProgram();
        usdc.mint(admin, 100e6);

        vm.startPrank(admin);
        usdc.approve(address(registry), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, OPS_ROLE)
        );
        registry.fund(pid, address(usdc), 100e6);
        vm.stopPrank();
        _step("  PASS: admin cannot fund");

        _logPass();
    }

    // ── PRV-16 ──
    function test_PRV16_SweepOpsOnly() public {
        _logCase("PRV-16", unicode"sweep 仅 OPS");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();
        _activate(pid, oldToken);
        _fundAll(pid);
        vm.warp(block.timestamp + WEEK + 1);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, OPS_ROLE)
        );
        registry.sweepUnclaimed(pid, custody);
        _step("  PASS: admin cannot sweep");

        _logPass();
    }

    // ── PRV-17 ──
    function test_PRV17_SelfGrantProtection() public {
        _logCase("PRV-17", unicode"自授权保护");

        vm.prank(admin);
        vm.expectRevert(PrivatizationRegistry.SelfGrantNotAllowed.selector);
        registry.grantRole(OPS_ROLE, admin);
        _step("  PASS: SelfGrantNotAllowed");

        _logPass();
    }

    // ── PRV-18 ──
    function test_PRV18_RenounceLastAdminGuard() public {
        _logCase("PRV-18", unicode"renounce 最后 admin 守卫");

        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(PrivatizationRegistry.CannotRenounceLastAdmin.selector);
        registry.renounceRole(adminRole, admin);
        _step("  PASS: CannotRenounceLastAdmin");

        _logPass();
    }

    // ── PRV-19 ──
    function test_PRV19_FundAfterSweepReverts() public {
        _logCase("PRV-19", unicode"sweep 后 fund revert");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();
        _activate(pid, oldToken);
        _fundAll(pid);
        vm.warp(block.timestamp + WEEK + 1);
        vm.prank(ops);
        registry.sweepUnclaimed(pid, custody);

        usdc.mint(ops, 100e6);
        vm.startPrank(ops);
        usdc.approve(address(registry), 100e6);
        vm.expectRevert(PrivatizationRegistry.ClaimClosed.selector);
        registry.fund(pid, address(usdc), 100e6);
        vm.stopPrank();
        _step("  PASS: fund after sweep reverts ClaimClosed");

        _logPass();
    }

    // ── PRV-20 ──
    function test_PRV20_FundZeroAddress() public {
        _logCase("PRV-20", unicode"fund(address(0)) revert");

        uint256 pid = _createProgram();
        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.ZeroAddress.selector);
        registry.fund(pid, address(0), 100);
        _step("  PASS: ZeroAddress");

        _logPass();
    }

    // ── PRV-21 ──
    function test_PRV21_FundZeroAmount() public {
        _logCase("PRV-21", unicode"fund(0) revert");

        uint256 pid = _createProgram();
        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.ZeroAmount.selector);
        registry.fund(pid, address(usdc), 0);
        _step("  PASS: ZeroAmount");

        _logPass();
    }

    // ── PRV-22 ──
    function test_PRV22_SweepBeforeDeadline() public {
        _logCase("PRV-22", unicode"sweep before deadline revert");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();
        _activate(pid, oldToken);
        _fundAll(pid);

        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.ClaimStillOpen.selector);
        registry.sweepUnclaimed(pid, custody);
        _step("  PASS: ClaimStillOpen");

        _logPass();
    }

    // ── PRV-23 ──
    function test_PRV23_SweepZeroAddress() public {
        _logCase("PRV-23", unicode"sweepUnclaimed(address(0)) revert");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();
        _activate(pid, oldToken);
        _fundAll(pid);
        vm.warp(block.timestamp + WEEK + 1);

        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.ZeroAddress.selector);
        registry.sweepUnclaimed(pid, address(0));
        _step("  PASS: ZeroAddress");

        _logPass();
    }

    // ── PRV-24 ──
    function test_PRV24_ConfigureNonexistentProgram() public {
        _logCase("PRV-24", unicode"configureProgram 不存在 program revert");

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + WEEK),
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.UnknownProgram.selector);
        registry.configureProgram(999, cfg);
        _step("  PASS: UnknownProgram");

        _logPass();
    }

    // ── PRV-25 ──
    function test_PRV25_CreateProgramBadLeg() public {
        _logCase("PRV-25", unicode"createProgram BadLeg revert");

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 0);

        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.BadLeg.selector);
        registry.createProgram(address(oldToken), legs);
        _step("  PASS: BadLeg (total=0)");

        _logPass();
    }

    // ── PRV-26 ──
    function test_PRV26_CreateProgramZeroOldToken() public {
        _logCase("PRV-26", unicode"createProgram ZeroAddress revert");

        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.ZeroAddress.selector);
        registry.createProgram(address(0), _legs3());
        _step("  PASS: ZeroAddress");

        _logPass();
    }

    // ── PRV-27 ──
    function test_PRV27_ClaimZeroAmount() public {
        _logCase("PRV-27", unicode"claim(id, 0) ZeroAmount revert");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();
        _activate(pid, oldToken);
        _fundAll(pid);

        vm.prank(userA);
        vm.expectRevert(PrivatizationRegistry.ZeroAmount.selector);
        registry.claim(pid, 0);
        _step("  PASS: ZeroAmount");

        _logPass();
    }

    // ── PRV-28 ──
    function test_PRV28_ClaimOnCreatedNotActive() public {
        _logCase("PRV-28", unicode"claim on Created program NotActive revert");

        _seed(oldToken, userA, 100 ether);
        uint256 pid = _createProgram();

        vm.startPrank(userA);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.NotActive.selector);
        registry.claim(pid, 100 ether);
        vm.stopPrank();
        _step("  PASS: NotActive");

        _logPass();
    }

    // ── PRV-29 ──
    function test_PRV29_InitializeZeroAddress() public {
        _logCase("PRV-29", unicode"initialize(address(0)) revert");

        PrivatizationRegistry impl = new PrivatizationRegistry();
        address[] memory emptyOps = new address[](0);
        vm.expectRevert(PrivatizationRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(PrivatizationRegistry.initialize, (address(0), emptyOps)));
        _step("  PASS: ZeroAddress");

        _logPass();
    }

    // ── PRV-25b (BadLeg token=0) ──
    function test_PRV25b_CreateProgramBadLegZeroToken() public {
        _logCase("PRV-25b", unicode"createProgram BadLeg(token=0) revert");

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(0), 100e6);

        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.BadLeg.selector);
        registry.createProgram(address(oldToken), legs);
        _step("  PASS: BadLeg (token=address(0))");

        _logPass();
    }

    // ── PRV-18b (NoLegs) ──
    function test_PRV18b_CreateProgramNoLegs() public {
        _logCase("PRV-18b", unicode"createProgram NoLegs revert");

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](0);
        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.NoLegs.selector);
        registry.createProgram(address(oldToken), legs);
        _step("  PASS: NoLegs");

        _logPass();
    }

    // ── helper: address(this) as array ──
    function _self() internal view returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = address(this);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INIT-01 ~ INIT-06: initialize(admin, address[] ops) 新签名覆盖
    // 对应 PR #43: 在 initialize 里通过内部 _grantRole 授予 OPS_ROLE,
    // 绕过 public grantRole 的 SelfGrantNotAllowed 检查
    // ─────────────────────────────────────────────────────────────────────────

    function _freshReg(address[] memory initOps) internal returns (PrivatizationRegistry r) {
        r = PrivatizationRegistry(
            address(
                new ERC1967Proxy(
                    address(new PrivatizationRegistry()),
                    abi.encodeCall(PrivatizationRegistry.initialize, (admin, initOps))
                )
            )
        );
    }

    function _oneLeg() internal view returns (PrivatizationRegistry.Leg[] memory legs) {
        legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 300e6);
    }

    function test_PRVINIT01_EmptyOpsArray() public {
        _logCase("PRV-INIT-01", unicode"initialize(admin, []) 空 ops 数组允许");

        address[] memory none = new address[](0);
        PrivatizationRegistry r = _freshReg(none);

        bytes32 opsRole = r.OPS_ROLE();
        bytes32 adminRole = r.DEFAULT_ADMIN_ROLE();
        assertTrue(r.hasRole(adminRole, admin), "admin missing DEFAULT_ADMIN_ROLE");
        assertEq(r.getRoleMemberCount(opsRole), 0, "OPS_ROLE count must be 0");

        // 后续 grantRole 仍可用
        vm.prank(admin);
        r.grantRole(opsRole, ops);
        assertTrue(r.hasRole(opsRole, ops), "post-init grantRole failed");

        _logPass();
    }

    function test_PRVINIT02_MultipleOps() public {
        _logCase("PRV-INIT-02", unicode"initialize 多个 ops 全部授权");

        address op1 = makeAddr("initOp1");
        address op2 = makeAddr("initOp2");
        address op3 = makeAddr("initOp3");
        address[] memory initOps = new address[](3);
        initOps[0] = op1;
        initOps[1] = op2;
        initOps[2] = op3;
        PrivatizationRegistry r = _freshReg(initOps);

        bytes32 opsRole = r.OPS_ROLE();
        assertTrue(r.hasRole(opsRole, op1), "op1 missing OPS_ROLE");
        assertTrue(r.hasRole(opsRole, op2), "op2 missing OPS_ROLE");
        assertTrue(r.hasRole(opsRole, op3), "op3 missing OPS_ROLE");
        assertEq(r.getRoleMemberCount(opsRole), 3, "count != 3");

        _logPass();
    }

    function test_PRVINIT03_ZeroAddressInOpsReverts() public {
        _logCase("PRV-INIT-03", unicode"initialize ops 含 address(0) revert ZeroAddress");

        address[] memory bad = new address[](3);
        bad[0] = makeAddr("initOp1");
        bad[1] = address(0);
        bad[2] = makeAddr("initOp2");

        PrivatizationRegistry impl = new PrivatizationRegistry();
        vm.expectRevert(PrivatizationRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(PrivatizationRegistry.initialize, (admin, bad)));

        _logPass();
    }

    function test_PRVINIT04_DuplicateOpsIdempotent() public {
        _logCase("PRV-INIT-04", unicode"initialize ops 重复元素幂等,count 不重复计数");

        address op1 = makeAddr("initOp1");
        address[] memory dup = new address[](3);
        dup[0] = op1;
        dup[1] = op1;
        dup[2] = op1;
        PrivatizationRegistry r = _freshReg(dup);

        assertTrue(r.hasRole(r.OPS_ROLE(), op1), "op1 missing OPS_ROLE");
        assertEq(r.getRoleMemberCount(r.OPS_ROLE()), 1, "duplicate must not double-count");

        _logPass();
    }

    function test_PRVINIT05_SelfGrantBypassedAtInit() public {
        _logCase("PRV-INIT-05", unicode"init 内 _grantRole 绕过 SelfGrantNotAllowed");

        // 场景: admin 出现在 ops 数组里. init 期 _grantRole 允许; 但同一 admin 后续
        // 走 public grantRole 给自己会 revert SelfGrantNotAllowed. 这两点合起来证明
        // init 走了内部路径.
        address[] memory selfOps = new address[](1);
        selfOps[0] = admin;
        PrivatizationRegistry r = _freshReg(selfOps);

        bytes32 opsRole = r.OPS_ROLE();
        bytes32 adminRole = r.DEFAULT_ADMIN_ROLE();
        assertTrue(r.hasRole(opsRole, admin), "admin missing OPS_ROLE granted at init");

        // 对照: public grantRole 同一账户给自己 -> SelfGrantNotAllowed
        address stranger2 = makeAddr("newAdmin");
        vm.prank(admin);
        r.grantRole(adminRole, stranger2);
        vm.prank(stranger2);
        vm.expectRevert(PrivatizationRegistry.SelfGrantNotAllowed.selector);
        r.grantRole(opsRole, stranger2);

        _logPass();
    }

    function test_PRVINIT06_InitOpsCanCallOpsFunction() public {
        _logCase("PRV-INIT-06", unicode"init 授权的 ops 立刻能调 OPS-only 函数");

        address op1 = makeAddr("initOp1");
        address[] memory initOps = new address[](1);
        initOps[0] = op1;
        PrivatizationRegistry r = _freshReg(initOps);

        bytes32 opsRole = r.OPS_ROLE();
        PrivatizationRegistry.Leg[] memory legs1 = _oneLeg();
        PrivatizationRegistry.Leg[] memory legs2 = _oneLeg();

        // OPS-only 函数: createProgram. 不 revert 即证明 role check 通过.
        vm.prank(op1);
        uint256 pid = r.createProgram(address(oldToken), legs1);
        assertEq(pid, 0, "first pid should be 0");

        // 对照: stranger 无 OPS_ROLE -> revert
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, opsRole);
        vm.prank(stranger);
        vm.expectRevert(expected);
        r.createProgram(address(oldToken), legs2);

        _logPass();
    }
}
