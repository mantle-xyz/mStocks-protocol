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
import {CustodyClaimRouter} from "../../src/privatization/CustodyClaimRouter.sol";
import {MockUSD} from "../mocks/MockUSD.sol";

contract CustodyClaimRouterQA is Test {
    string constant MODULE = unicode"CustodyClaimRouter";

    // ── logging ──
    function _logCase(string memory id, string memory name) internal pure {
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
    CustodyClaimRouter internal router;
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
    address internal hotWallet1 = makeAddr("hotWallet1");
    address internal hotWallet2 = makeAddr("hotWallet2");
    address internal hotWallet3 = makeAddr("hotWallet3");
    address internal custody = makeAddr("custody");
    address internal stranger = makeAddr("stranger");

    bytes32 internal BURN_ROLE;
    uint256 internal programId;

    function setUp() public virtual {
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = _deployFactory(address(compliance), address(pauseManager), admin, proxyAdmin, 24 hours);
        factory.grantRole(factory.OPS_ROLE(), address(this));
        usdc = new MockUSD();
        address[] memory registryOps = new address[](1);
        registryOps[0] = address(this); // test drives registry lifecycle
        registry = PrivatizationRegistry(
            address(
                new ERC1967Proxy(
                    address(new PrivatizationRegistry()),
                    abi.encodeCall(PrivatizationRegistry.initialize, (admin, registryOps))
                )
            )
        );
        address[] memory routerOps = new address[](1);
        routerOps[0] = ops;
        router = CustodyClaimRouter(
            address(
                new ERC1967Proxy(
                    address(new CustodyClaimRouter()),
                    abi.encodeCall(CustodyClaimRouter.initialize, (address(registry), admin, routerOps))
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
        router.registerHotWallet(hotWallet1);
        vm.stopPrank();

        BURN_ROLE = oldToken.BURN_ROLE();

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](3);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 300e6);
        legs[1] = PrivatizationRegistry.Leg(address(newToken), 200 ether);
        legs[2] = PrivatizationRegistry.Leg(address(cvr), 100 ether);

        oldToken.mint(100 ether);
        oldToken.transfer(hotWallet1, 100 ether);

        programId = registry.createProgram(address(oldToken), legs);

        vm.startPrank(admin);
        oldToken.grantRole(BURN_ROLE, address(registry));
        oldToken.grantRole(oldToken.OPS_ROLE(), tokenOps);
        vm.stopPrank();
        vm.prank(tokenOps);
        oldToken.setMintAllowed(false);

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        registry.configureProgram(programId, cfg);

        _fundBasket();
    }

    function _fundBasket() internal {
        usdc.mint(address(this), 300e6);
        usdc.approve(address(registry), 300e6);
        registry.fund(programId, address(usdc), 300e6);

        newToken.mint(200 ether);
        newToken.approve(address(registry), 200 ether);
        registry.fund(programId, address(newToken), 200 ether);

        cvr.mint(100 ether);
        cvr.approve(address(registry), 100 ether);
        registry.fund(programId, address(cvr), 100 ether);
    }

    // ═══════════════════════════════════════════════
    //                    TESTS
    // ═══════════════════════════════════════════════

    // ── RTR-01 ──
    function test_RTR01_MainFlowTransferClaimForward() public {
        _logCase("RTR-01", unicode"主流程 transfer->claimFor->篮子转回");

        _step("[Step 1] hotWallet1 transfers OLD to router");
        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 100 ether);
        assertEq(oldToken.balanceOf(address(router)), 100 ether);

        _step("[Step 2] OPS calls claimFor");
        vm.expectEmit(true, true, true, true, address(router));
        emit CustodyClaimRouter.ClaimedFor(programId, hotWallet1, ops, 100 ether);
        vm.prank(ops);
        router.claimFor(programId, hotWallet1, 100 ether);

        _step("[Step 3] verify basket delivered and router empty");
        assertEq(oldToken.totalSupply(), 0, "old burned");
        assertEq(usdc.balanceOf(hotWallet1), 300e6);
        assertEq(newToken.balanceOf(hotWallet1), 200 ether);
        assertEq(cvr.balanceOf(hotWallet1), 100 ether);
        assertEq(oldToken.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(newToken.balanceOf(address(router)), 0);
        assertEq(cvr.balanceOf(address(router)), 0);
        _step("  PASS: basket forwarded, router clean");

        _logPass();
    }

    // ── RTR-02 ──
    function test_RTR02_UnregisteredHotWalletRevert() public {
        _logCase("RTR-02", unicode"未注册热钱包 revert");

        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 100 ether);

        vm.prank(ops);
        vm.expectRevert(CustodyClaimRouter.NotRegisteredHotWallet.selector);
        router.claimFor(programId, stranger, 100 ether);
        _step("  PASS: NotRegisteredHotWallet");

        _logPass();
    }

    // ── RTR-03 ──
    function test_RTR03_NonOpsRevert() public {
        _logCase("RTR-03", unicode"非 OPS revert");

        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 100 ether);

        bytes32 opsRole = router.OPS_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, opsRole)
        );
        router.claimFor(programId, hotWallet1, 100 ether);
        _step("  PASS: AccessControlUnauthorizedAccount");

        _logPass();
    }

    // ── RTR-04 ──
    function test_RTR04_AmountExceedsRouterBalance() public {
        _logCase("RTR-04", unicode"amount 超 router 余额");

        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 10 ether);

        vm.prank(ops);
        // ERC20 transfer inside registry.claim will revert (router only holds 10, not 20)
        vm.expectRevert();
        router.claimFor(programId, hotWallet1, 20 ether);
        _step("  PASS: revert on insufficient router balance");

        _logPass();
    }

    // ── RTR-05 ──
    function test_RTR05_RegisterOnlyAdmin() public {
        _logCase("RTR-05", unicode"注册仅 admin");

        bytes32 adminRole = router.DEFAULT_ADMIN_ROLE();
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops, adminRole)
        );
        router.registerHotWallet(stranger);
        _step("  PASS: OPS cannot register");

        _logPass();
    }

    // ── RTR-06 ──
    function test_RTR06_DeregisteredCannotClaim() public {
        _logCase("RTR-06", unicode"注销后不可 claimFor");

        vm.prank(admin);
        router.deregisterHotWallet(hotWallet1);

        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 100 ether);

        vm.prank(ops);
        vm.expectRevert(CustodyClaimRouter.NotRegisteredHotWallet.selector);
        router.claimFor(programId, hotWallet1, 100 ether);
        _step("  PASS: NotRegisteredHotWallet after deregister");

        _logPass();
    }

    // ── RTR-07 ──
    function test_RTR07_RescueRecovers() public {
        _logCase("RTR-07", unicode"rescue 取回");

        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 100 ether);

        vm.prank(admin);
        router.rescue(address(oldToken), custody, 100 ether);
        assertEq(oldToken.balanceOf(custody), 100 ether);
        assertEq(oldToken.balanceOf(address(router)), 0);
        _step("  PASS: rescue successful");

        _logPass();
    }

    // ── RTR-08 ──
    function test_RTR08_RescueNonAdminRevert() public {
        _logCase("RTR-08", unicode"rescue 非 admin revert");

        bytes32 adminRole = router.DEFAULT_ADMIN_ROLE();
        vm.prank(ops);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ops, adminRole)
        );
        router.rescue(address(oldToken), custody, 1);
        _step("  PASS: OPS cannot rescue");

        _logPass();
    }

    // ── RTR-09 ──
    function test_RTR09_BatchRegister() public {
        _logCase("RTR-09", unicode"批量注册 registerHotWallets");

        address[] memory wallets = new address[](3);
        wallets[0] = makeAddr("batchHw1");
        wallets[1] = makeAddr("batchHw2");
        wallets[2] = makeAddr("batchHw3");

        vm.prank(admin);
        router.registerHotWallets(wallets);

        assertTrue(router.isHotWallet(wallets[0]));
        assertTrue(router.isHotWallet(wallets[1]));
        assertTrue(router.isHotWallet(wallets[2]));
        _step("  PASS: all 3 registered");

        _logPass();
    }

    // ── RTR-10 ──
    function test_RTR10_MultiHotWalletClaimFor() public {
        _logCase("RTR-10", unicode"多热钱包分别 claimFor");

        vm.prank(admin);
        router.registerHotWallet(hotWallet2);

        _step("[Step 1] hw1 sends 40 to hw2, keeping 60");
        vm.prank(hotWallet1);
        oldToken.transfer(hotWallet2, 40 ether);

        _step("[Step 2] both transfer to router");
        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 60 ether);
        vm.prank(hotWallet2);
        oldToken.transfer(address(router), 40 ether);

        _step("[Step 3] OPS claims for each");
        vm.prank(ops);
        router.claimFor(programId, hotWallet1, 60 ether);
        vm.prank(ops);
        router.claimFor(programId, hotWallet2, 40 ether);

        assertEq(usdc.balanceOf(hotWallet1), 180e6, "hw1 60% USDC");
        assertEq(usdc.balanceOf(hotWallet2), 120e6, "hw2 40% USDC");
        assertEq(newToken.balanceOf(hotWallet1), 120 ether, "hw1 60% NEW");
        assertEq(newToken.balanceOf(hotWallet2), 80 ether, "hw2 40% NEW");
        assertEq(cvr.balanceOf(hotWallet1), 60 ether, "hw1 60% CVR");
        assertEq(cvr.balanceOf(hotWallet2), 40 ether, "hw2 40% CVR");
        assertEq(oldToken.totalSupply(), 0, "all burned");
        _step("  PASS: each hw got correct basket");

        _logPass();
    }

    // ── RTR-11 ──
    function test_RTR11_ComplianceBlockAtomicRollback() public {
        _logCase("RTR-11", unicode"合规封禁热钱包原子回滚");

        address[] memory arr = new address[](1);
        arr[0] = hotWallet1;
        vm.prank(complianceOps);
        compliance.blockUsers(address(newToken), arr);

        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 100 ether);

        vm.prank(ops);
        vm.expectRevert();
        router.claimFor(programId, hotWallet1, 100 ether);

        assertEq(oldToken.balanceOf(address(router)), 100 ether, "old still in router");
        assertEq(usdc.balanceOf(hotWallet1), 0, "no USDC leaked");
        assertEq(newToken.balanceOf(hotWallet1), 0, "no NEW leaked");
        assertEq(cvr.balanceOf(hotWallet1), 0, "no CVR leaked");
        _step("  PASS: atomic rollback, old still in router");

        _logPass();
    }

    // ── RTR-12 ──
    function test_RTR12_SelfGrantProtection() public {
        _logCase("RTR-12", unicode"自授权保护");

        bytes32 opsRole = router.OPS_ROLE();
        vm.prank(admin);
        vm.expectRevert(CustodyClaimRouter.SelfGrantNotAllowed.selector);
        router.grantRole(opsRole, admin);
        _step("  PASS: SelfGrantNotAllowed");

        _logPass();
    }

    // ── RTR-13 ──
    function test_RTR13_RenounceLastAdminGuard() public {
        _logCase("RTR-13", unicode"renounce 最后 admin 守卫");

        bytes32 adminRole = router.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(CustodyClaimRouter.CannotRenounceLastAdmin.selector);
        router.renounceRole(adminRole, admin);
        _step("  PASS: CannotRenounceLastAdmin");

        _logPass();
    }

    // ── RTR-14 ──
    function test_RTR14_ClaimForNonexistentProgram() public {
        _logCase("RTR-14", unicode"claimFor 不存在 program revert");

        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 10 ether);

        vm.prank(ops);
        vm.expectRevert(CustodyClaimRouter.UnknownProgram.selector);
        router.claimFor(999, hotWallet1, 10 ether);
        _step("  PASS: UnknownProgram");

        _logPass();
    }

    // ── RTR-15 ──
    function test_RTR15_NothingForwardedEdge() public {
        _logCase("RTR-15", unicode"NothingForwarded 边界");

        // Create a program with a tiny total and huge supply snapshot so mulDiv rounds to 0
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 1);

        ScaledToken oldToken2 = ScaledToken(
            factory.createToken("Dust Co", "DUST", "US0000000099", admin, _self(), new address[](0), new address[](0))
        );
        oldToken2.mint(1e18);
        oldToken2.transfer(hotWallet1, 1);

        uint256 pid2 = registry.createProgram(address(oldToken2), legs);

        vm.startPrank(admin);
        oldToken2.grantRole(oldToken2.BURN_ROLE(), address(registry));
        oldToken2.grantRole(oldToken2.OPS_ROLE(), tokenOps);
        vm.stopPrank();
        vm.prank(tokenOps);
        oldToken2.setMintAllowed(false);

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: 1e18,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        registry.configureProgram(pid2, cfg);

        usdc.mint(address(this), 1);
        usdc.approve(address(registry), 1);
        registry.fund(pid2, address(usdc), 1);

        vm.prank(hotWallet1);
        oldToken2.transfer(address(router), 1);

        vm.prank(ops);
        vm.expectRevert(PrivatizationRegistry.NothingToDeliver.selector);
        router.claimFor(pid2, hotWallet1, 1);
        _step("  PASS: NothingToDeliver on dust (bubbles from registry)");

        _logPass();
    }

    // ── RTR-16 ──
    function test_RTR16_RescueZeroAddressRevert() public {
        _logCase("RTR-16", unicode"rescue(token, address(0)) revert");

        vm.prank(hotWallet1);
        oldToken.transfer(address(router), 10 ether);

        vm.prank(admin);
        vm.expectRevert(CustodyClaimRouter.ZeroAddress.selector);
        router.rescue(address(oldToken), address(0), 10 ether);
        _step("  PASS: ZeroAddress");

        _logPass();
    }

    // ── RTR-17 ──
    function test_RTR17_InitializeZeroAddress() public {
        _logCase("RTR-17", unicode"initialize(address(0)) revert");

        CustodyClaimRouter impl = new CustodyClaimRouter();
        address[] memory emptyOps = new address[](0);

        _step("[Step 1] registry=address(0)");
        vm.expectRevert(CustodyClaimRouter.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(CustodyClaimRouter.initialize, (address(0), admin, emptyOps)));

        _step("[Step 2] admin=address(0)");
        vm.expectRevert(CustodyClaimRouter.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(CustodyClaimRouter.initialize, (address(registry), address(0), emptyOps))
        );
        _step("  PASS: both ZeroAddress");

        _logPass();
    }

    // ── RTR-18 ──
    function test_RTR18_ClaimForZeroAmount() public {
        _logCase("RTR-18", unicode"claimFor(id, hw, 0) ZeroAmount revert");

        vm.prank(ops);
        vm.expectRevert(CustodyClaimRouter.ZeroAmount.selector);
        router.claimFor(programId, hotWallet1, 0);
        _step("  PASS: ZeroAmount");

        _logPass();
    }

    // ── RTR-19 ──
    function test_RTR19_RegisterZeroAddressRevert() public {
        _logCase("RTR-19", unicode"registerHotWallet(address(0)) ZeroAddress revert");

        vm.prank(admin);
        vm.expectRevert(CustodyClaimRouter.ZeroAddress.selector);
        router.registerHotWallet(address(0));
        _step("  PASS: ZeroAddress");

        _logPass();
    }

    // ── helpers ──
    function _self() internal view returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = address(this);
    }

    function _deployFactory(address _c, address _pm, address _owner, address _pa, uint256 _notice)
        internal
        returns (ScaledTokenFactory)
    {
        ScaledTokenFactory impl = new ScaledTokenFactory(new ScaledTokenBeaconDeployer());
        bytes memory data = abi.encodeWithSelector(
            ScaledTokenFactory.initialize.selector, _c, _pm, _owner, _pa, _notice
        );
        return ScaledTokenFactory(payable(address(new TransparentUpgradeableProxy(address(impl), _pa, data))));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INIT-01 ~ INIT-06: initialize(registry, admin, address[] ops) 新签名覆盖
    // 对应 PR #43: 在 initialize 里通过内部 _grantRole 授予 OPS_ROLE,
    // 绕过 public grantRole 的 SelfGrantNotAllowed 检查
    // ─────────────────────────────────────────────────────────────────────────

    function _freshRouter(address[] memory initOps) internal returns (CustodyClaimRouter r) {
        r = CustodyClaimRouter(
            address(
                new ERC1967Proxy(
                    address(new CustodyClaimRouter()),
                    abi.encodeCall(CustodyClaimRouter.initialize, (address(registry), admin, initOps))
                )
            )
        );
    }

    function test_RTRINIT01_EmptyOpsArray() public {
        _logCase("RTR-INIT-01", unicode"initialize(registry, admin, []) 空 ops 数组允许");

        address[] memory none = new address[](0);
        CustodyClaimRouter r = _freshRouter(none);

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

    function test_RTRINIT02_MultipleOps() public {
        _logCase("RTR-INIT-02", unicode"initialize 多个 ops 全部授权");

        address op1 = makeAddr("initOp1");
        address op2 = makeAddr("initOp2");
        address op3 = makeAddr("initOp3");
        address[] memory initOps = new address[](3);
        initOps[0] = op1;
        initOps[1] = op2;
        initOps[2] = op3;
        CustodyClaimRouter r = _freshRouter(initOps);

        bytes32 opsRole = r.OPS_ROLE();
        assertTrue(r.hasRole(opsRole, op1), "op1 missing OPS_ROLE");
        assertTrue(r.hasRole(opsRole, op2), "op2 missing OPS_ROLE");
        assertTrue(r.hasRole(opsRole, op3), "op3 missing OPS_ROLE");
        assertEq(r.getRoleMemberCount(opsRole), 3, "count != 3");

        _logPass();
    }

    function test_RTRINIT03_ZeroAddressInOpsReverts() public {
        _logCase("RTR-INIT-03", unicode"initialize ops 含 address(0) revert ZeroAddress");

        address[] memory bad = new address[](3);
        bad[0] = makeAddr("initOp1");
        bad[1] = address(0);
        bad[2] = makeAddr("initOp2");

        CustodyClaimRouter impl = new CustodyClaimRouter();
        vm.expectRevert(CustodyClaimRouter.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(CustodyClaimRouter.initialize, (address(registry), admin, bad))
        );

        _logPass();
    }

    function test_RTRINIT04_DuplicateOpsIdempotent() public {
        _logCase("RTR-INIT-04", unicode"initialize ops 重复元素幂等,count 不重复计数");

        address op1 = makeAddr("initOp1");
        address[] memory dup = new address[](3);
        dup[0] = op1;
        dup[1] = op1;
        dup[2] = op1;
        CustodyClaimRouter r = _freshRouter(dup);

        assertTrue(r.hasRole(r.OPS_ROLE(), op1), "op1 missing OPS_ROLE");
        assertEq(r.getRoleMemberCount(r.OPS_ROLE()), 1, "duplicate must not double-count");

        _logPass();
    }

    function test_RTRINIT05_SelfGrantBypassedAtInit() public {
        _logCase("RTR-INIT-05", unicode"init 内 _grantRole 绕过 SelfGrantNotAllowed");

        // 场景: admin 出现在 ops 数组里. init 期 _grantRole 允许; 但同一 admin 后续
        // 走 public grantRole 给自己会 revert SelfGrantNotAllowed. 这两点合起来证明
        // init 走了内部路径.
        address[] memory selfOps = new address[](1);
        selfOps[0] = admin;
        CustodyClaimRouter r = _freshRouter(selfOps);

        bytes32 opsRole = r.OPS_ROLE();
        bytes32 adminRole = r.DEFAULT_ADMIN_ROLE();
        assertTrue(r.hasRole(opsRole, admin), "admin missing OPS_ROLE granted at init");

        // 对照: public grantRole 同一账户给自己 -> SelfGrantNotAllowed
        address stranger2 = makeAddr("newAdmin");
        vm.prank(admin);
        r.grantRole(adminRole, stranger2);
        vm.prank(stranger2);
        vm.expectRevert(CustodyClaimRouter.SelfGrantNotAllowed.selector);
        r.grantRole(opsRole, stranger2);

        _logPass();
    }

    function test_RTRINIT06_InitOpsCanCallOpsFunction() public {
        _logCase("RTR-INIT-06", unicode"init 授权的 ops 立刻能调 OPS-only 函数");

        address op1 = makeAddr("initOp1");
        address[] memory initOps = new address[](1);
        initOps[0] = op1;
        CustodyClaimRouter r = _freshRouter(initOps);

        bytes32 opsRole = r.OPS_ROLE();

        // OPS-only 函数: claimFor. 由于其业务前置(热钱包未注册),
        // 预期 revert NotRegisteredHotWallet — 而不是 AccessControl 错误,
        // 即证明 role check 通过.
        vm.prank(op1);
        vm.expectRevert(CustodyClaimRouter.NotRegisteredHotWallet.selector);
        r.claimFor(programId, hotWallet1, 1 ether);

        // 对照: stranger 无 OPS_ROLE -> AccessControlUnauthorizedAccount
        bytes memory expected =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, opsRole);
        vm.prank(stranger);
        vm.expectRevert(expected);
        r.claimFor(programId, hotWallet1, 1 ether);

        _logPass();
    }
}
