// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WarrantRegistry} from "../../src/privatization/WarrantRegistry.sol";
import {MockUSD} from "../mocks/MockUSD.sol";
import {MockComplianceGuardedToken, MockUnguardedToken} from "../mocks/MockComplianceGuardedToken.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ScaledTokenBeaconDeployer} from "../../src/scaledToken/ScaledTokenBeaconDeployer.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {IComplianceRegistry} from "../../src/complianceRegistry/IComplianceRegistry.sol";

/// @notice QA test suite for WarrantRegistry — 75 tests covering lifecycle, state machine,
///         configuration lock (including v5.0 lock-at-Active rules), claim/fund/sweep boundaries,
///         permissions, events, multi-program isolation, leverage, and cross-module
///         (compliance + pause + ComplianceUnavailable) interactions.
///         Maps to warrant-test-plan.md §5 (WR-01 ~ WR-75).
contract WarrantRegistryQA is Test {
    string constant MODULE = unicode"WarrantRegistry";

    // ── logging ──────────────────────────────────────────────────────────────
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

    // ── core state ───────────────────────────────────────────────────────────
    WarrantRegistry internal reg;
    MockUSD internal usd;

    address internal admin = makeAddr("admin");
    address internal ops = makeAddr("ops");
    address internal custody = makeAddr("custody");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");
    address internal dave = makeAddr("dave");
    address internal stranger = makeAddr("stranger");

    bytes32 internal OPS_ROLE;

    // ── default compliance (needed for all claims) ────────────────────────────
    ComplianceRegistry internal compliance;
    MockComplianceGuardedToken internal defaultToken;

    // ── cross-module state (lazy) ────────────────────────────────────────────
    PauseRegistry internal pauseManager;
    ScaledTokenFactory internal factory;
    ScaledToken internal settleToken;
    MockComplianceGuardedToken internal complianceGuardedToken;
    address internal complianceOps = makeAddr("complianceOps");
    address internal pauseOps = makeAddr("pauseOps");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    bool internal _crossModuleReady;

    // ── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        usd = new MockUSD();
        compliance = new ComplianceRegistry(admin);
        defaultToken = new MockComplianceGuardedToken(IComplianceRegistry(address(compliance)));
        address[] memory initOps = new address[](1);
        initOps[0] = ops;
        reg = WarrantRegistry(
            address(
                new ERC1967Proxy(
                    address(new WarrantRegistry()),
                    abi.encodeCall(WarrantRegistry.initialize, (admin, initOps))
                )
            )
        );
        OPS_ROLE = reg.OPS_ROLE();
    }

    // ── merkle helpers ───────────────────────────────────────────────────────

    function _leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    // 2-leaf tree: alice 60%, bob 40%
    function _root2() internal view returns (bytes32) {
        return _hashPair(_leaf(0, alice, 0.6e18), _leaf(1, bob, 0.4e18));
    }

    function _proofAlice() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = _leaf(1, bob, 0.4e18);
    }

    function _proofBob() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = _leaf(0, alice, 0.6e18);
    }

    // 4-leaf tree: alice 40%, bob 30%, charlie 20%, dave 10%
    function _root4() internal view returns (bytes32) {
        bytes32 ab = _hashPair(_leaf(0, alice, 0.4e18), _leaf(1, bob, 0.3e18));
        bytes32 cd = _hashPair(_leaf(2, charlie, 0.2e18), _leaf(3, dave, 0.1e18));
        return _hashPair(ab, cd);
    }

    function _proof4(uint256 index) internal view returns (bytes32[] memory p) {
        bytes32 leafA = _leaf(0, alice, 0.4e18);
        bytes32 leafB = _leaf(1, bob, 0.3e18);
        bytes32 leafC = _leaf(2, charlie, 0.2e18);
        bytes32 leafD = _leaf(3, dave, 0.1e18);
        bytes32 ab = _hashPair(leafA, leafB);
        bytes32 cd = _hashPair(leafC, leafD);

        p = new bytes32[](2);
        if (index == 0) {
            p[0] = leafB;
            p[1] = cd;
        } else if (index == 1) {
            p[0] = leafA;
            p[1] = cd;
        } else if (index == 2) {
            p[0] = leafD;
            p[1] = ab;
        } else {
            p[0] = leafC;
            p[1] = ab;
        }
    }

    // ── setup helpers ────────────────────────────────────────────────────────

    function _emptyPatch(uint8 state) internal pure returns (WarrantRegistry.Program memory) {
        return WarrantRegistry.Program({
            token: address(0),
            merkleRoot: bytes32(0),
            settlementToken: address(0),
            settleTotal: 0,
            startTime: 0,
            deadline: 0,
            state: state
        });
    }

    /// v5.0 flow: createProgram → configureProgram(params, NOT Active) → fund → configureProgram(state=Active)
    function _createAndActivate(bytes32 root, uint256 settleTotal, uint256 fundAmount, uint64 window)
        internal
        returns (uint256 id)
    {
        vm.startPrank(ops);
        id = reg.createProgram(address(_tokenForProgram()), address(usd));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: root,
                settlementToken: address(0),
                settleTotal: settleTotal,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + window,
                state: 0
            })
        );
        vm.stopPrank();

        if (fundAmount > 0) _fund(id, fundAmount);

        vm.prank(ops);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));
    }

    /// Convenience: settleTotal == fundAmount (fully funded)
    function _createAndActivate(bytes32 root, uint256 settleTotal, uint64 window)
        internal
        returns (uint256 id)
    {
        return _createAndActivate(root, settleTotal, settleTotal, window);
    }

    /// Create + configure but do NOT fund or activate. Stays in Created state.
    function _createAndConfigure(bytes32 root, uint256 settleTotal, uint64 window)
        internal
        returns (uint256 id)
    {
        vm.startPrank(ops);
        id = reg.createProgram(address(_tokenForProgram()), address(usd));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: root,
                settlementToken: address(0),
                settleTotal: settleTotal,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + window,
                state: 0
            })
        );
        vm.stopPrank();
    }

    function _fund(uint256 id, uint256 amount) internal {
        usd.mint(ops, amount);
        vm.startPrank(ops);
        usd.approve(address(reg), amount);
        reg.fund(id, amount);
        vm.stopPrank();
    }

    function _tokenForProgram() internal view returns (address) {
        if (_crossModuleReady) return address(complianceGuardedToken);
        return address(defaultToken);
    }

    function _setUpCrossModule() internal {
        if (_crossModuleReady) return;
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);

        ScaledTokenFactory impl = new ScaledTokenFactory(new ScaledTokenBeaconDeployer());
        bytes memory initData = abi.encodeWithSelector(
            ScaledTokenFactory.initialize.selector,
            address(compliance),
            address(pauseManager),
            admin,
            proxyAdmin,
            uint256(1 hours)
        );
        factory = ScaledTokenFactory(
            payable(address(new TransparentUpgradeableProxy(address(impl), proxyAdmin, initData)))
        );

        factory.grantRole(factory.OPS_ROLE(), address(this));
        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        pauseManager.grantRole(pauseManager.PAUSE_ROLE(), pauseOps);
        pauseManager.grantRole(pauseManager.UNPAUSE_ROLE(), pauseOps);
        vm.stopPrank();

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        address[] memory none = new address[](0);
        settleToken = ScaledToken(
            factory.createToken("Settle Token", "STOK", "US9999999999", admin, issuers, none, none)
        );
        complianceGuardedToken = new MockComplianceGuardedToken(IComplianceRegistry(address(compliance)));
        _crossModuleReady = true;
    }

    /// Creates a cross-module program using a compliance-guarded token and ScaledToken settlement.
    function _createCrossModuleProgram() internal returns (uint256 id) {
        _setUpCrossModule();

        settleToken.mint(1_000_000 ether);
        settleToken.transfer(ops, 1_000_000 ether);

        vm.startPrank(ops);
        id = reg.createProgram(address(complianceGuardedToken), address(settleToken));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root2(),
                settlementToken: address(0),
                settleTotal: 500 ether,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp + 7 days),
                state: 0
            })
        );
        settleToken.approve(address(reg), 500 ether);
        reg.fund(id, 500 ether);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  A. Lifecycle — Forward Flow (WR-01 ~ WR-05)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR01_MainClaimFlow() public {
        _logCase("WR-01", unicode"主流程 claim");

        _step("[1] createProgram + configure + fund + activate");
        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        _step("[2] alice claim");
        uint256 preview = reg.previewClaim(id, 0.6e18);
        assertEq(preview, 300e6, "previewClaim == 300e6");

        vm.prank(alice);
        vm.expectEmit(true, false, true, true, address(reg));
        emit WarrantRegistry.Claimed(id, 0, alice, 0.6e18, 300e6);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        assertEq(usd.balanceOf(alice), 300e6, "alice received 300e6");
        assertEq(reg.warrant(id, alice), 0.6e18, "warrant recorded");
        assertTrue(reg.isClaimed(id, 0), "index 0 marked claimed");
        assertTrue(reg.claimStarted(id), "claimStarted set");
        assertEq(reg.settleReserve(id), 200e6, "reserve drawn down");

        _logPass();
    }

    function test_WR02_MultiHolderClaim() public {
        _logCase("WR-02", unicode"多持有人依次 claim");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        _step("[1] alice claims 60%");
        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(usd.balanceOf(alice), 300e6);

        _step("[2] bob claims 40%");
        vm.prank(bob);
        reg.claim(id, 1, bob, 0.4e18, _proofBob());
        assertEq(usd.balanceOf(bob), 200e6);

        _step("[3] verify reserve");
        assertEq(reg.settleReserve(id), 0, "reserve == 0 after full claim");

        _logPass();
    }

    function test_WR03_ThirdPartyRelayerClaim() public {
        _logCase("WR-03", unicode"第三方代 claim");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        assertEq(usd.balanceOf(alice), 300e6, "payout to alice");
        assertEq(usd.balanceOf(relayer), 0, "relayer gets nothing");
        assertEq(reg.warrant(id, alice), 0.6e18, "record on alice");
        assertEq(reg.warrant(id, relayer), 0, "no record on relayer");

        _logPass();
    }

    function test_WR04_PreviewClaimAccuracy() public {
        _logCase("WR-04", unicode"previewClaim 准确性 (4-leaf)");

        uint256 id = _createAndActivate(_root4(), 1000e6, 7 days);

        uint256[4] memory amounts = [uint256(0.4e18), 0.3e18, 0.2e18, 0.1e18];
        address[4] memory accounts = [alice, bob, charlie, dave];

        for (uint256 i; i < 4; i++) {
            uint256 expected = Math.mulDiv(amounts[i], 1000e6, 1e18);
            uint256 preview = reg.previewClaim(id, amounts[i]);
            assertEq(preview, expected, "preview matches formula");

            uint256 before = usd.balanceOf(accounts[i]);
            vm.prank(accounts[i]);
            reg.claim(id, i, accounts[i], amounts[i], _proof4(i));
            uint256 received = usd.balanceOf(accounts[i]) - before;
            assertEq(received, preview, "actual == preview");
        }

        _logPass();
    }

    function test_WR05_ReserveReconciliation() public {
        _logCase("WR-05", unicode"全部 claim 后 reserve 对账");

        uint256 id = _createAndActivate(_root4(), 1000e6, 7 days);

        uint256[4] memory amounts = [uint256(0.4e18), 0.3e18, 0.2e18, 0.1e18];
        address[4] memory accounts = [alice, bob, charlie, dave];
        uint256 totalOut;

        for (uint256 i; i < 4; i++) {
            uint256 before = usd.balanceOf(accounts[i]);
            vm.prank(accounts[i]);
            reg.claim(id, i, accounts[i], amounts[i], _proof4(i));
            totalOut += usd.balanceOf(accounts[i]) - before;
        }

        uint256 sweepable = reg.settleReserve(id);
        assertEq(totalOut + sweepable, 1000e6, "sum(out) + sweepable == fund");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  B. State Machine (WR-06 ~ WR-11)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR06_CreatedConfigureFundActive() public {
        _logCase("WR-06", unicode"Created → configure → fund → Active");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));
        (,,,,,, uint8 s1) = reg.programs(id);
        assertEq(s1, uint8(WarrantRegistry.State.Created));

        bytes32 root = _root2();
        uint64 start = uint64(block.timestamp);
        uint64 deadline = uint64(block.timestamp + 7 days);

        _step("[2] configureProgram (params, NOT Active)");
        vm.prank(ops);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: root,
                settlementToken: address(0),
                settleTotal: 500e6,
                startTime: start,
                deadline: deadline,
                state: 0
            })
        );
        (,,,,,, uint8 s2) = reg.programs(id);
        assertEq(s2, uint8(WarrantRegistry.State.Created), "still Created after configure");

        _step("[3] fund");
        _fund(id, 500e6);

        _step("[4] configureProgram(state=Active)");
        vm.prank(ops);
        vm.expectEmit(true, false, false, true, address(reg));
        emit WarrantRegistry.ProgramConfigured(id, root, address(usd), 500e6, start, deadline, 2);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));
        (,,,,,, uint8 s3) = reg.programs(id);
        assertEq(s3, uint8(WarrantRegistry.State.Active));

        _logPass();
    }

    function test_WR07_StateRegressionReverts() public {
        _logCase("WR-07", unicode"状态回退 Active → Created");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Created)));

        _logPass();
    }

    function test_WR08_JumpToClosedReverts() public {
        _logCase("WR-08", unicode"跳跃 Created → Closed");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.InvalidStateTransition.selector);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Closed)));

        _logPass();
    }

    function test_WR09_ReopenClosedReverts() public {
        _logCase("WR-09", unicode"Closed 后重开");

        uint256 id = _createAndActivate(_root2(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(ops);
        reg.sweepUnclaimed(id, custody);

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));

        _logPass();
    }

    function test_WR10_ClaimBeforeConfigureReverts() public {
        _logCase("WR-10", unicode"未 configure 就 claim");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotActive.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    function test_WR11_SweepCausesClosedAndSubsequentReverts() public {
        _logCase("WR-11", unicode"sweep → Closed + 后续 revert");

        uint256 id = _createAndActivate(_root2(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);

        vm.prank(ops);
        reg.sweepUnclaimed(id, custody);
        (,,,,,, uint8 s) = reg.programs(id);
        assertEq(s, uint8(WarrantRegistry.State.Closed));

        _step(unicode"claim after Closed → NotActive");
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotActive.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _step(unicode"re-sweep after Closed → NotActive");
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.NotActive.selector);
        reg.sweepUnclaimed(id, custody);

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  C. Configuration & Funding Lock (WR-12 ~ WR-23)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR12_SettleTotalLockedAfterFund() public {
        _logCase("WR-12", unicode"Created+funded → 改 settleTotal 被拒");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);
        _fund(id, 500e6);

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.SettlementTermsLocked.selector);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: bytes32(0),
                settlementToken: address(0),
                settleTotal: 600e6,
                startTime: 0,
                deadline: 0,
                state: 0
            })
        );

        _logPass();
    }

    function test_WR13_SettlementTokenLockedAfterFund() public {
        _logCase("WR-13", unicode"Created+funded → 改 settlementToken 被拒");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);
        _fund(id, 500e6);

        MockUSD other = new MockUSD();
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.SettlementTermsLocked.selector);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: bytes32(0),
                settlementToken: address(other),
                settleTotal: 0,
                startTime: 0,
                deadline: 0,
                state: 0
            })
        );

        _logPass();
    }

    function test_WR14_DeadlineChangeAllowedAfterFund() public {
        _logCase("WR-14", unicode"Created+funded → 改 deadline（允许）");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);
        _fund(id, 500e6);

        uint64 newDeadline = uint64(block.timestamp) + 30 days;
        vm.prank(ops);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: bytes32(0),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: 0,
                deadline: newDeadline,
                state: 0
            })
        );
        (,,,,, uint64 dl,) = reg.programs(id);
        assertEq(dl, newDeadline);

        _logPass();
    }

    function test_WR15_FreelyChangeSettlementBeforeFund() public {
        _logCase("WR-15", unicode"未 fund → 自由改 settlement 条件");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);

        MockUSD other = new MockUSD();
        vm.prank(ops);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: bytes32(0),
                settlementToken: address(other),
                settleTotal: 999e6,
                startTime: 0,
                deadline: 0,
                state: 0
            })
        );
        (, , address st, uint256 total, , ,) = reg.programs(id);
        assertEq(st, address(other));
        assertEq(total, 999e6);

        _logPass();
    }

    function test_WR16_RootLockedOnceActive() public {
        _logCase("WR-16", unicode"Active 后不能改 root");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        bytes32 fakeRoot = keccak256("fake");
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: fakeRoot,
                settlementToken: address(0),
                settleTotal: 0,
                startTime: 0,
                deadline: 0,
                state: 0
            })
        );

        _logPass();
    }

    function test_WR17_DeadlineLockedOnceActive() public {
        _logCase("WR-17", unicode"Active 后不能改 deadline");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: bytes32(0),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: 0,
                deadline: uint64(block.timestamp + 60 days),
                state: 0
            })
        );

        _logPass();
    }

    function test_WR18_ExtendDeadlineWhileCreated() public {
        _logCase("WR-18", unicode"Created 阶段延 deadline");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);

        uint64 extended = uint64(block.timestamp + 30 days);
        vm.prank(ops);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: bytes32(0),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: 0,
                deadline: extended,
                state: 0
            })
        );
        (,,,,, uint64 dl,) = reg.programs(id);
        assertEq(dl, extended);

        _logPass();
    }

    function test_WR19_ZeroValuePreservation() public {
        _logCase("WR-19", unicode"零值保留 — 只传 deadline");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);
        (, bytes32 rootBefore, , uint256 totalBefore, uint64 startBefore, , uint8 stateBefore) = reg.programs(id);

        uint64 newDeadline = uint64(block.timestamp + 14 days);
        vm.prank(ops);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: bytes32(0),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: 0,
                deadline: newDeadline,
                state: 0
            })
        );
        (, bytes32 rootAfter, , uint256 totalAfter, uint64 startAfter, uint64 dlAfter, uint8 stateAfter) =
            reg.programs(id);
        assertEq(rootAfter, rootBefore, "root unchanged");
        assertEq(totalAfter, totalBefore, "settleTotal unchanged");
        assertEq(startAfter, startBefore, "startTime unchanged");
        assertEq(stateAfter, stateBefore, "state unchanged");
        assertEq(dlAfter, newDeadline, "deadline updated");

        _logPass();
    }

    function test_WR20_ZeroStateDoesNotRegress() public {
        _logCase("WR-20", unicode"零值保留 — state=0 不回退");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);
        (,,,,,, uint8 sBefore) = reg.programs(id);
        assertEq(sBefore, uint8(WarrantRegistry.State.Created));

        vm.prank(ops);
        reg.configureProgram(id, _emptyPatch(0));
        (,,,,,, uint8 sAfter) = reg.programs(id);
        assertEq(sAfter, uint8(WarrantRegistry.State.Created), "state stays Created");

        _logPass();
    }

    function test_WR21_NotFullyFunded() public {
        _logCase("WR-21", unicode"设 Active 但 reserve 不足 → NotFullyFunded");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);
        _fund(id, 100e6);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.NotFullyFunded.selector, 100e6, 500e6));
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));

        _logPass();
    }

    function test_WR22_SettleTotalNotSet() public {
        _logCase("WR-22", unicode"fund 前未设 settleTotal → SettleTotalNotSet");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));

        usd.mint(ops, 100e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 100e6);
        vm.expectRevert(WarrantRegistry.SettleTotalNotSet.selector);
        reg.fund(id, 100e6);
        vm.stopPrank();

        _logPass();
    }

    function test_WR23_FundLockedOnceActive() public {
        _logCase("WR-23", unicode"Active 后 fund → FundLockedOnceActive");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        usd.mint(ops, 100e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 100e6);
        vm.expectRevert(WarrantRegistry.FundLockedOnceActive.selector);
        reg.fund(id, 100e6);
        vm.stopPrank();

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  D. Claim Boundaries (WR-24 ~ WR-32)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR24_ClaimBeforeWindowStart() public {
        _logCase("WR-24", unicode"窗口开始前");

        vm.startPrank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root2(),
                settlementToken: address(0),
                settleTotal: 500e6,
                startTime: uint64(block.timestamp + 1 days),
                deadline: uint64(block.timestamp + 7 days),
                state: 0
            })
        );
        vm.stopPrank();
        _fund(id, 500e6);
        vm.prank(ops);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.ClaimNotStarted.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    function test_WR25_ClaimAfterDeadline() public {
        _logCase("WR-25", unicode"窗口结束后");

        uint256 id = _createAndActivate(_root2(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.ClaimClosed.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    function test_WR26_DoubleClaim() public {
        _logCase("WR-26", unicode"二次 claim");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.AlreadyClaimed.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    function test_WR27_TamperAmount() public {
        _logCase("WR-27", unicode"篡改 amount");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.InvalidProof.selector);
        reg.claim(id, 0, alice, 0.9e18, _proofAlice());

        _logPass();
    }

    function test_WR28_ForgedProof() public {
        _logCase("WR-28", unicode"完全伪造 proof");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        bytes32[] memory fakeProof = new bytes32[](1);
        fakeProof[0] = keccak256("garbage");

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.InvalidProof.selector);
        reg.claim(id, 0, alice, 0.6e18, fakeProof);

        _logPass();
    }

    function test_WR29_CrossProgramProofMisuse() public {
        _logCase("WR-29", unicode"跨 program proof 错用");

        _createAndActivate(_root2(), 500e6, 7 days);

        bytes32 rootB = _hashPair(_leaf(0, charlie, 0.5e18), _leaf(1, dave, 0.5e18));
        uint256 idB = _createAndActivate(rootB, 500e6, 7 days);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.InvalidProof.selector);
        reg.claim(idB, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    function test_WR30_DustAmountReverts() public {
        _logCase("WR-30", unicode"dust 份额到账为 0");

        bytes32 root = _hashPair(_leaf(0, alice, 1), _leaf(1, bob, 0.4e18));
        uint256 id = _createAndActivate(root, 100, 7 days);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(1, bob, 0.4e18);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NothingToSettle.selector);
        reg.claim(id, 0, alice, 1, proof);

        assertFalse(reg.isClaimed(id, 0), "index not consumed");
        assertFalse(reg.claimStarted(id), "claimStarted not set");

        _logPass();
    }

    function test_WR31_NotConvertibleYetThenCannotFixAfterActive() public {
        _logCase("WR-31", unicode"配资 claim → NotConvertibleYet + Active 后无法补设");

        vm.startPrank(ops);
        uint256 id = reg.createProgram(address(defaultToken), address(0));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root2(),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp + 30 days),
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();

        _step("[1] claim reverts NotConvertibleYet");
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertFalse(reg.isClaimed(id, 0));

        _step(unicode"[2] configureProgram(settlementToken=usd) → ConfigureLockedOnceActive");
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: bytes32(0),
                settlementToken: address(usd),
                settleTotal: 500e6,
                startTime: 0,
                deadline: 0,
                state: 0
            })
        );

        _step(unicode"[3] fund → FundLockedOnceActive");
        usd.mint(ops, 100e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 100e6);
        vm.expectRevert(WarrantRegistry.FundLockedOnceActive.selector);
        reg.fund(id, 100e6);
        vm.stopPrank();

        _logPass();
    }

    function test_WR32_ClaimNonExistentProgram() public {
        _logCase("WR-32", unicode"claim 不存在的 programId");

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.UnknownProgram.selector);
        reg.claim(999, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  E. Fund Boundaries (WR-33 ~ WR-38)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR33_FundZeroAmount() public {
        _logCase("WR-33", unicode"fund(amount=0)");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ZeroAmount.selector);
        reg.fund(id, 0);

        _logPass();
    }

    function test_WR34_FundNonExistentProgram() public {
        _logCase("WR-34", unicode"fund 不存在的 program");

        usd.mint(ops, 100e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 100e6);
        vm.expectRevert(WarrantRegistry.UnknownProgram.selector);
        reg.fund(999, 100e6);
        vm.stopPrank();

        _logPass();
    }

    function test_WR35_FundClosedProgram() public {
        _logCase("WR-35", unicode"fund 已 Closed");

        uint256 id = _createAndActivate(_root2(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(ops);
        reg.sweepUnclaimed(id, custody);

        usd.mint(ops, 100e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 100e6);
        vm.expectRevert(WarrantRegistry.FundLockedOnceActive.selector);
        reg.fund(id, 100e6);
        vm.stopPrank();

        _logPass();
    }

    function test_WR36_FundWithoutSettlementToken() public {
        _logCase("WR-36", unicode"fund 无 settlementToken");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(0));

        usd.mint(ops, 100e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 100e6);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.fund(id, 100e6);
        vm.stopPrank();

        _logPass();
    }

    function test_WR37_MultipleFundAccumulation() public {
        _logCase("WR-37", unicode"多次 fund 累加（Created 态）");

        uint256 id = _createAndConfigure(_root2(), 300e6, 7 days);
        _fund(id, 100e6);
        _fund(id, 200e6);

        assertEq(reg.settleReserve(id), 300e6);

        _logPass();
    }

    function test_WR38_FundInCreatedState() public {
        _logCase("WR-38", unicode"Created + settleTotal 已设 → fund 成功");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);
        _fund(id, 500e6);
        assertEq(reg.settleReserve(id), 500e6, "fund accepted in Created");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  F. Sweep Boundaries (WR-39 ~ WR-44)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR39_SweepBeforeDeadline() public {
        _logCase("WR-39", unicode"deadline 前 sweep");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ClaimStillOpen.selector);
        reg.sweepUnclaimed(id, custody);

        _logPass();
    }

    function test_WR40_SweepToZeroAddress() public {
        _logCase("WR-40", unicode"sweep to=address(0)");

        uint256 id = _createAndActivate(_root2(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ZeroAddress.selector);
        reg.sweepUnclaimed(id, address(0));

        _logPass();
    }

    function test_WR41_SweepNoOneClaimed() public {
        _logCase("WR-41", unicode"sweep 无人 claim");

        uint256 id = _createAndActivate(_root2(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);

        vm.prank(ops);
        reg.sweepUnclaimed(id, custody);

        assertEq(usd.balanceOf(custody), 500e6, "custody got all");
        assertEq(reg.settleReserve(id), 0);
        (,,,,,, uint8 s) = reg.programs(id);
        assertEq(s, uint8(WarrantRegistry.State.Closed));

        _logPass();
    }

    function test_WR42_SweepZeroReserve() public {
        _logCase("WR-42", unicode"sweep 零 reserve");

        uint256 id = _createAndActivate(_root4(), 1000e6, 1 days);

        uint256[4] memory amounts = [uint256(0.4e18), 0.3e18, 0.2e18, 0.1e18];
        address[4] memory accounts = [alice, bob, charlie, dave];
        for (uint256 i; i < 4; i++) {
            vm.prank(accounts[i]);
            reg.claim(id, i, accounts[i], amounts[i], _proof4(i));
        }
        assertEq(reg.settleReserve(id), 0, "reserve is exactly 0");

        vm.warp(block.timestamp + 2 days);

        vm.prank(ops);
        vm.expectEmit(true, true, false, true, address(reg));
        emit WarrantRegistry.Swept(id, custody, 0);
        reg.sweepUnclaimed(id, custody);

        (,,,,,, uint8 s) = reg.programs(id);
        assertEq(s, uint8(WarrantRegistry.State.Closed));
        assertEq(usd.balanceOf(custody), 0, "nothing transferred");

        _logPass();
    }

    function test_WR43_SweepNonExistentProgram() public {
        _logCase("WR-43", unicode"sweep 不存在的 program");

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.UnknownProgram.selector);
        reg.sweepUnclaimed(999, custody);

        _logPass();
    }

    function test_WR44_SweepCreatedState() public {
        _logCase("WR-44", unicode"sweep Created 状态");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.NotActive.selector);
        reg.sweepUnclaimed(id, custody);

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  G. CreateProgram Boundaries (WR-45 ~ WR-47)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR45_CreateProgramZeroToken() public {
        _logCase("WR-45", unicode"token=address(0)");

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ZeroAddress.selector);
        reg.createProgram(address(0), address(usd));

        _logPass();
    }

    function test_WR46_CreateProgramZeroSettlement() public {
        _logCase("WR-46", unicode"settlementToken=address(0)（配资模式）");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(0));
        (, , address st, , , ,) = reg.programs(id);
        assertEq(st, address(0));

        _logPass();
    }

    function test_WR47_ProgramIdIncrements() public {
        _logCase("WR-47", unicode"programId 递增");

        vm.startPrank(ops);
        uint256 a = reg.createProgram(address(usd), address(usd));
        uint256 b = reg.createProgram(address(usd), address(usd));
        uint256 c = reg.createProgram(address(usd), address(usd));
        vm.stopPrank();

        assertEq(a, 0);
        assertEq(b, 1);
        assertEq(c, 2);
        assertEq(reg.programCount(), 3);

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  H. Permissions (WR-48 ~ WR-55)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR48_AdminCannotCreateProgram() public {
        _logCase("WR-48", unicode"admin 不能 createProgram");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, OPS_ROLE)
        );
        reg.createProgram(address(usd), address(usd));

        _logPass();
    }

    function test_WR49_AdminCannotConfigureProgram() public {
        _logCase("WR-49", unicode"admin 不能 configureProgram");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, OPS_ROLE)
        );
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));

        _logPass();
    }

    function test_WR50_AdminCannotFund() public {
        _logCase("WR-50", unicode"admin 不能 fund");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, OPS_ROLE)
        );
        reg.fund(id, 1e6);

        _logPass();
    }

    function test_WR51_AdminCannotSweep() public {
        _logCase("WR-51", unicode"admin 不能 sweepUnclaimed");

        uint256 id = _createAndActivate(_root2(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, OPS_ROLE)
        );
        reg.sweepUnclaimed(id, custody);

        _logPass();
    }

    function test_WR52_StrangerCannotDoAnything() public {
        _logCase("WR-52", unicode"stranger 不能做任何写操作");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));

        _step("createProgram");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPS_ROLE)
        );
        reg.createProgram(address(usd), address(usd));

        _step("configureProgram");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPS_ROLE)
        );
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));

        _step("fund");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPS_ROLE)
        );
        reg.fund(id, 1e6);

        _step("sweepUnclaimed");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPS_ROLE)
        );
        reg.sweepUnclaimed(id, custody);

        _logPass();
    }

    function test_WR53_SelfGrantProtection() public {
        _logCase("WR-53", unicode"自授权保护");

        vm.prank(admin);
        vm.expectRevert(WarrantRegistry.SelfGrantNotAllowed.selector);
        reg.grantRole(OPS_ROLE, admin);

        _logPass();
    }

    function test_WR54_LastAdminCannotRenounce() public {
        _logCase("WR-54", unicode"最后一个 admin 不能 renounce");

        vm.prank(admin);
        vm.expectRevert(WarrantRegistry.CannotRenounceLastAdmin.selector);
        reg.renounceRole(0x00, admin);

        _logPass();
    }

    function test_WR55_OpsCannotGrantRole() public {
        _logCase("WR-55", unicode"OPS 不能 grantRole");

        bytes32 adminRole = reg.DEFAULT_ADMIN_ROLE();
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops, adminRole)
        );
        reg.grantRole(OPS_ROLE, stranger);

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  I. Events (WR-56 ~ WR-60)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR56_EventProgramCreated() public {
        _logCase("WR-56", unicode"ProgramCreated 事件");

        vm.prank(ops);
        vm.expectEmit(true, true, false, true, address(reg));
        emit WarrantRegistry.ProgramCreated(0, address(usd), address(usd));
        reg.createProgram(address(usd), address(usd));

        _logPass();
    }

    function test_WR57_EventProgramConfigured() public {
        _logCase("WR-57", unicode"ProgramConfigured 事件");

        vm.prank(ops);
        uint256 id = reg.createProgram(address(usd), address(usd));

        bytes32 root = _root2();
        uint64 start = uint64(block.timestamp);
        uint64 deadline = uint64(block.timestamp + 7 days);

        vm.prank(ops);
        vm.expectEmit(true, false, false, true, address(reg));
        emit WarrantRegistry.ProgramConfigured(id, root, address(usd), 500e6, start, deadline, 1);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: root,
                settlementToken: address(0),
                settleTotal: 500e6,
                startTime: start,
                deadline: deadline,
                state: 0
            })
        );

        _logPass();
    }

    function test_WR58_EventFunded() public {
        _logCase("WR-58", unicode"Funded 事件");

        uint256 id = _createAndConfigure(_root2(), 500e6, 7 days);
        usd.mint(ops, 500e6);

        vm.startPrank(ops);
        usd.approve(address(reg), 500e6);
        vm.expectEmit(true, true, false, true, address(reg));
        emit WarrantRegistry.Funded(id, ops, 500e6);
        reg.fund(id, 500e6);
        vm.stopPrank();

        _logPass();
    }

    function test_WR59_EventClaimed() public {
        _logCase("WR-59", unicode"Claimed 事件");

        uint256 id = _createAndActivate(_root2(), 500e6, 7 days);

        vm.prank(alice);
        vm.expectEmit(true, false, true, true, address(reg));
        emit WarrantRegistry.Claimed(id, 0, alice, 0.6e18, 300e6);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    function test_WR60_EventSwept() public {
        _logCase("WR-60", unicode"Swept 事件");

        uint256 id = _createAndActivate(_root2(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);

        vm.prank(ops);
        vm.expectEmit(true, true, false, true, address(reg));
        emit WarrantRegistry.Swept(id, custody, 500e6);
        reg.sweepUnclaimed(id, custody);

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  J. Multi-Program Isolation (WR-61 ~ WR-62)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR61_FundIsolation() public {
        _logCase("WR-61", unicode"资金隔离");

        uint256 idA = _createAndActivate(_root2(), 500e6, 7 days);

        bytes32 rootB = _hashPair(_leaf(0, charlie, 0.5e18), _leaf(1, dave, 0.5e18));
        uint256 idB = _createAndActivate(rootB, 300e6, 7 days);

        _step("alice claims programA");
        vm.prank(alice);
        reg.claim(idA, 0, alice, 0.6e18, _proofAlice());

        assertEq(reg.settleReserve(idA), 200e6, "A reserve decreased");
        assertEq(reg.settleReserve(idB), 300e6, "B reserve unchanged");

        _logPass();
    }

    function test_WR62_IsClaimedIsolation() public {
        _logCase("WR-62", unicode"isClaimed 隔离");

        uint256 idA = _createAndActivate(_root2(), 500e6, 7 days);
        uint256 idB = _createAndActivate(_root2(), 500e6, 7 days);

        vm.prank(alice);
        reg.claim(idA, 0, alice, 0.6e18, _proofAlice());

        assertTrue(reg.isClaimed(idA, 0), "A index 0 claimed");
        assertFalse(reg.isClaimed(idB, 0), "B index 0 NOT claimed");

        _step("alice can still claim B");
        vm.prank(alice);
        reg.claim(idB, 0, alice, 0.6e18, _proofAlice());
        assertTrue(reg.isClaimed(idB, 0));

        _logPass();
    }

    function test_WR76_CrossTokenIsolation() public {
        _logCase("WR-76", unicode"跨 token 隔离（不同 mStock）");

        MockComplianceGuardedToken tokenB = new MockComplianceGuardedToken(IComplianceRegistry(address(compliance)));

        _step("create programA with defaultToken, programB with tokenB");
        vm.startPrank(ops);
        uint256 idA = reg.createProgram(address(defaultToken), address(usd));
        reg.configureProgram(idA, WarrantRegistry.Program({
            token: address(0), merkleRoot: _root2(), settlementToken: address(0),
            settleTotal: 500e6, startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days), state: 0
        }));
        vm.stopPrank();
        _fund(idA, 500e6);
        vm.prank(ops);
        reg.configureProgram(idA, _emptyPatch(uint8(WarrantRegistry.State.Active)));

        vm.startPrank(ops);
        uint256 idB = reg.createProgram(address(tokenB), address(usd));
        reg.configureProgram(idB, WarrantRegistry.Program({
            token: address(0), merkleRoot: _root2(), settlementToken: address(0),
            settleTotal: 300e6, startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days), state: 0
        }));
        vm.stopPrank();
        _fund(idB, 300e6);
        vm.prank(ops);
        reg.configureProgram(idB, _emptyPatch(uint8(WarrantRegistry.State.Active)));

        _step("alice claims programA");
        vm.prank(alice);
        reg.claim(idA, 0, alice, 0.6e18, _proofAlice());

        assertEq(reg.settleReserve(idB), 300e6, "B reserve unchanged after A claim");
        assertFalse(reg.isClaimed(idB, 0), "B index 0 NOT claimed");

        _step("alice claims programB");
        vm.prank(alice);
        reg.claim(idB, 0, alice, 0.6e18, _proofAlice());

        assertTrue(reg.isClaimed(idB, 0), "B index 0 claimed");
        assertEq(reg.settleReserve(idB), 300e6 - 180e6, "B reserve decreased correctly");

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  K. Leverage (WR-63 ~ WR-65)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR63_LeverageCreateAndConfigure() public {
        _logCase("WR-63", unicode"配资 create + configure Active");

        vm.startPrank(ops);
        uint256 id = reg.createProgram(address(usd), address(0));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root2(),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp + 7 days),
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();

        (, bytes32 root, address st, , , , uint8 s) = reg.programs(id);
        assertEq(s, uint8(WarrantRegistry.State.Active));
        assertEq(root, _root2());
        assertEq(st, address(0));

        _logPass();
    }

    function test_WR64_LeverageCannotClaim() public {
        _logCase("WR-64", unicode"配资不可 claim");

        vm.startPrank(ops);
        uint256 id = reg.createProgram(address(defaultToken), address(0));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root2(),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp + 7 days),
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    function test_WR65_LeverageCannotFund() public {
        _logCase("WR-65", unicode"配资不可 fund");

        vm.startPrank(ops);
        uint256 id = reg.createProgram(address(usd), address(0));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root2(),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp + 7 days),
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();

        usd.mint(ops, 100e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 100e6);
        vm.expectRevert(WarrantRegistry.FundLockedOnceActive.selector);
        reg.fund(id, 100e6);
        vm.stopPrank();

        _logPass();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  L. Cross-Module (WR-66 ~ WR-75)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_WR66_PausedSettlementTokenBlocksClaim() public {
        _logCase("WR-66", unicode"settlementToken 被暂停时 claim 失败");

        uint256 id = _createCrossModuleProgram();

        _step("[1] pause settlementToken");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(settleToken));

        _step("[2] claim reverts");
        vm.prank(alice);
        vm.expectRevert();
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertFalse(reg.isClaimed(id, 0), "index not consumed");

        _step("[3] cleanup: unpause");
        vm.prank(pauseOps);
        pauseManager.unpauseToken(address(settleToken));

        _logPass();
    }

    function test_WR67_BlockedAccountCannotClaim() public {
        _logCase("WR-67", unicode"account 被 blockUsers(token) → claim 失败");

        uint256 id = _createCrossModuleProgram();

        _step("[1] block alice on complianceGuardedToken");
        address[] memory blocked = new address[](1);
        blocked[0] = alice;
        vm.prank(complianceOps);
        compliance.blockUsers(address(complianceGuardedToken), blocked);

        _step("[2] alice claim reverts");
        vm.prank(alice);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertFalse(reg.isClaimed(id, 0), "index not consumed");

        _logPass();
    }

    function test_WR68_SanctionedAccountCannotClaim() public {
        _logCase("WR-68", unicode"account 被 sanctionUsers(全局) → claim 失败");

        uint256 id = _createCrossModuleProgram();

        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(complianceOps);
        compliance.sanctionUsers(users);

        vm.prank(alice);
        vm.expectRevert(ComplianceRegistry.UserSanctioned.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertFalse(reg.isClaimed(id, 0));

        _logPass();
    }

    function test_WR69_CleanRelayerCannotBypassBlockedAccount() public {
        _logCase("WR-69", unicode"干净 relayer 代被封 account claim → 仍拒绝");

        uint256 id = _createCrossModuleProgram();

        address[] memory blocked = new address[](1);
        blocked[0] = alice;
        vm.prank(complianceOps);
        compliance.blockUsers(address(complianceGuardedToken), blocked);

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    function test_WR70_UnblockedAccountRetries() public {
        _logCase("WR-70", unicode"解封后重试 claim 成功");

        uint256 id = _createCrossModuleProgram();

        address[] memory users = new address[](1);
        users[0] = alice;

        _step("[1] block alice");
        vm.prank(complianceOps);
        compliance.blockUsers(address(complianceGuardedToken), users);

        _step("[2] alice claim fails");
        vm.prank(alice);
        vm.expectRevert();
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertFalse(reg.isClaimed(id, 0));

        _step("[3] unblock alice");
        vm.prank(complianceOps);
        compliance.unblockUsers(address(complianceGuardedToken), users);

        _step("[4] retry succeeds");
        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(settleToken.balanceOf(alice), 300 ether, "alice received settlement");
        assertEq(reg.warrant(id, alice), 0.6e18);
        assertTrue(reg.isClaimed(id, 0));

        _logPass();
    }

    function test_WR71_ClearSanctionsThenRetry() public {
        _logCase("WR-71", unicode"clearSanctions 后重试成功");

        uint256 id = _createCrossModuleProgram();

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.prank(complianceOps);
        compliance.sanctionUsers(users);

        vm.prank(alice);
        vm.expectRevert();
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        vm.prank(complianceOps);
        compliance.clearSanctions();

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(settleToken.balanceOf(alice), 300 ether);

        _logPass();
    }

    function test_WR72_BlockOtherAccountDoesNotAffectAlice() public {
        _logCase("WR-72", unicode"封禁 bob 不影响 alice claim");

        uint256 id = _createCrossModuleProgram();

        address[] memory blocked = new address[](1);
        blocked[0] = bob;
        vm.prank(complianceOps);
        compliance.blockUsers(address(complianceGuardedToken), blocked);

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(settleToken.balanceOf(alice), 300 ether);

        _logPass();
    }

    function test_WR73_BlockOnOtherTokenDoesNotAffect() public {
        _logCase("WR-73", unicode"在别的 token 封禁不影响本 program");

        uint256 id = _createCrossModuleProgram();

        address otherToken = makeAddr("otherToken");
        address[] memory blocked = new address[](1);
        blocked[0] = alice;
        vm.prank(complianceOps);
        compliance.blockUsers(otherToken, blocked);

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(settleToken.balanceOf(alice), 300 ether);

        _logPass();
    }

    function test_WR74_ComplianceUnavailable_NoComplianceMethod() public {
        _logCase("WR-74", unicode"token 不暴露 compliance() → ComplianceUnavailable");

        MockUnguardedToken badToken = new MockUnguardedToken();

        vm.startPrank(ops);
        uint256 id = reg.createProgram(address(badToken), address(usd));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root2(),
                settlementToken: address(0),
                settleTotal: 500e6,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp + 7 days),
                state: 0
            })
        );
        vm.stopPrank();
        _fund(id, 500e6);
        vm.prank(ops);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.ComplianceUnavailable.selector, address(badToken)));
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    function test_WR75_ComplianceUnavailable_ZeroAddress() public {
        _logCase("WR-75", unicode"token.compliance() 返回零地址 → ComplianceUnavailable");

        _setUpCrossModule();
        MockComplianceGuardedToken badToken = new MockComplianceGuardedToken(IComplianceRegistry(address(0)));

        vm.startPrank(ops);
        uint256 id = reg.createProgram(address(badToken), address(usd));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root2(),
                settlementToken: address(0),
                settleTotal: 500e6,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp + 7 days),
                state: 0
            })
        );
        vm.stopPrank();
        _fund(id, 500e6);
        vm.prank(ops);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.ComplianceUnavailable.selector, address(badToken)));
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        _logPass();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INIT-01 ~ INIT-06: initialize(admin, address[] ops) 新签名覆盖
    // 对应 PR #43: 在 initialize 里通过内部 _grantRole 授予 OPS_ROLE,
    // 绕过 public grantRole 的 SelfGrantNotAllowed 检查
    // ─────────────────────────────────────────────────────────────────────────

    function _freshReg(address[] memory initOps) internal returns (WarrantRegistry r) {
        r = WarrantRegistry(
            address(
                new ERC1967Proxy(
                    address(new WarrantRegistry()), abi.encodeCall(WarrantRegistry.initialize, (admin, initOps))
                )
            )
        );
    }

    function test_WRINIT01_EmptyOpsArray() public {
        _logCase("WR-INIT-01", unicode"initialize(admin, []) 空 ops 数组允许");

        address[] memory none = new address[](0);
        WarrantRegistry r = _freshReg(none);

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

    function test_WRINIT02_MultipleOps() public {
        _logCase("WR-INIT-02", unicode"initialize 多个 ops 全部授权");

        address op1 = makeAddr("initOp1");
        address op2 = makeAddr("initOp2");
        address op3 = makeAddr("initOp3");
        address[] memory initOps = new address[](3);
        initOps[0] = op1;
        initOps[1] = op2;
        initOps[2] = op3;
        WarrantRegistry r = _freshReg(initOps);

        bytes32 opsRole = r.OPS_ROLE();
        assertTrue(r.hasRole(opsRole, op1), "op1 missing OPS_ROLE");
        assertTrue(r.hasRole(opsRole, op2), "op2 missing OPS_ROLE");
        assertTrue(r.hasRole(opsRole, op3), "op3 missing OPS_ROLE");
        assertEq(r.getRoleMemberCount(opsRole), 3, "count != 3");

        _logPass();
    }

    function test_WRINIT03_ZeroAddressInOpsReverts() public {
        _logCase("WR-INIT-03", unicode"initialize ops 含 address(0) revert ZeroAddress");

        address[] memory bad = new address[](3);
        bad[0] = makeAddr("initOp1");
        bad[1] = address(0);
        bad[2] = makeAddr("initOp2");

        WarrantRegistry impl = new WarrantRegistry();
        vm.expectRevert(WarrantRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(WarrantRegistry.initialize, (admin, bad)));

        _logPass();
    }

    function test_WRINIT04_DuplicateOpsIdempotent() public {
        _logCase("WR-INIT-04", unicode"initialize ops 重复元素幂等,count 不重复计数");

        address op1 = makeAddr("initOp1");
        address[] memory dup = new address[](3);
        dup[0] = op1;
        dup[1] = op1;
        dup[2] = op1;
        WarrantRegistry r = _freshReg(dup);

        assertTrue(r.hasRole(r.OPS_ROLE(), op1), "op1 missing OPS_ROLE");
        assertEq(r.getRoleMemberCount(r.OPS_ROLE()), 1, "duplicate must not double-count");

        _logPass();
    }

    function test_WRINIT05_SelfGrantBypassedAtInit() public {
        _logCase("WR-INIT-05", unicode"init 内 _grantRole 绕过 SelfGrantNotAllowed");

        // 场景: admin 出现在 ops 数组里. init 期 _grantRole 允许; 但同一 admin 后续
        // 走 public grantRole 给自己会 revert SelfGrantNotAllowed. 这两点合起来证明
        // init 走了内部路径.
        address[] memory selfOps = new address[](1);
        selfOps[0] = admin;
        WarrantRegistry r = _freshReg(selfOps);

        bytes32 opsRole = r.OPS_ROLE();
        bytes32 adminRole = r.DEFAULT_ADMIN_ROLE();
        assertTrue(r.hasRole(opsRole, admin), "admin missing OPS_ROLE granted at init");

        // 对照: public grantRole 同一账户给自己 -> SelfGrantNotAllowed
        address stranger2 = makeAddr("newAdmin");
        vm.prank(admin);
        r.grantRole(adminRole, stranger2);
        vm.prank(stranger2);
        vm.expectRevert(WarrantRegistry.SelfGrantNotAllowed.selector);
        r.grantRole(opsRole, stranger2);

        _logPass();
    }

    function test_WRINIT06_InitOpsCanCallOpsFunction() public {
        _logCase("WR-INIT-06", unicode"init 授权的 ops 立刻能调 OPS-only 函数");

        address op1 = makeAddr("initOp1");
        address[] memory initOps = new address[](1);
        initOps[0] = op1;
        WarrantRegistry r = _freshReg(initOps);

        bytes32 opsRole = r.OPS_ROLE();

        // OPS-only 函数: createProgram. 不 revert 即证明 role check 通过.
        vm.prank(op1);
        uint256 pid = r.createProgram(address(defaultToken), address(usd));
        assertEq(pid, 0, "first pid should be 0");

        // 对照: stranger 无 OPS_ROLE -> revert
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, opsRole);
        vm.prank(stranger);
        vm.expectRevert(expected);
        r.createProgram(address(defaultToken), address(usd));

        _logPass();
    }
}
