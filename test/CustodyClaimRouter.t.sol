// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../src/scaledToken/ScaledTokenFactory.sol";
import {ScaledTokenBeaconDeployer} from "../src/scaledToken/ScaledTokenBeaconDeployer.sol";
import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../src/pauseRegistry/PauseRegistry.sol";
import {PrivatizationRegistry} from "../src/privatization/PrivatizationRegistry.sol";
import {CustodyClaimRouter} from "../src/privatization/CustodyClaimRouter.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

/// @notice Tests for CustodyClaimRouter: CEX hot wallets `transfer` old mStock in, an OPS operator
///         drives the privatization claim, and the reward basket is forwarded back atomically.
contract CustodyClaimRouterTest is Test {
    ScaledTokenFactory internal factory;
    ComplianceRegistry internal compliance;
    PauseRegistry internal pauseManager;
    PrivatizationRegistry internal registry;
    CustodyClaimRouter internal router;
    MockUSD internal usdc;

    ScaledToken internal oldToken;
    ScaledToken internal newToken;
    ScaledToken internal cvr;

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal ops = makeAddr("ops"); // router OPS
    address internal hotWallet = makeAddr("hotWallet"); // CEX hot wallet (transfer-only)
    address internal stranger = makeAddr("stranger");
    address internal custody = makeAddr("custody");
    address internal tokenOps = makeAddr("tokenOps");

    bytes32 internal BURN_ROLE;
    uint256 internal programId;

    /// @dev Factory is deployed behind an ERC1967Proxy in tests (production uses
    ///      TransparentUpgradeableProxy — see Deploy.s.sol) so tests can call implementation
    ///      functions directly without the transparent-admin caller restriction.
    function _deployFactory() internal returns (ScaledTokenFactory) {
        ScaledTokenFactory impl = new ScaledTokenFactory(new ScaledTokenBeaconDeployer());
        bytes memory initData = abi.encodeWithSelector(
            ScaledTokenFactory.initialize.selector,
            address(compliance),
            address(pauseManager),
            admin,
            proxyAdmin,
            24 hours
        );
        return ScaledTokenFactory(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    function setUp() public {
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = _deployFactory();
        // Factory self-grant is blocked, so admin delegates factory OPS to the test contract, which
        // then calls createToken (unpranked = msg.sender is this test).
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
        router.registerHotWallet(hotWallet);
        vm.stopPrank();

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        address[] memory none = new address[](0);
        oldToken = ScaledToken(factory.createToken("Old Co", "OLD", "US0000000001", admin, issuers, none, none));
        newToken = ScaledToken(factory.createToken("New Co", "NEW", "US0000000002", admin, issuers, none, none));
        cvr = ScaledToken(factory.createToken("Deal CVR", "CVR", "US0000000003", admin, issuers, none, none));

        BURN_ROLE = oldToken.BURN_ROLE();

        // A privatization program: each leg's `total` is distributed pro-rata across old supply.
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](3);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 300e6); // 300 USDC total
        legs[1] = PrivatizationRegistry.Leg(address(newToken), 200 ether); // 200 NEW total
        legs[2] = PrivatizationRegistry.Leg(address(cvr), 100 ether); // 100 CVR total

        // seed the hot wallet with the WHOLE old supply before freezing
        oldToken.mint(100 ether);
        oldToken.transfer(hotWallet, 100 ether);

        programId = registry.createProgram(address(oldToken), legs); // address(this) holds registry OPS

        // registry burns surrendered OLD; freeze OLD supply (setMintAllowed is OPS-gated)
        vm.startPrank(admin);
        oldToken.grantRole(BURN_ROLE, address(registry));
        oldToken.grantRole(oldToken.OPS_ROLE(), tokenOps);
        vm.stopPrank();
        vm.prank(tokenOps);
        oldToken.setMintAllowed(false);

        // configure: OPS supplies the frozen 100e18 snapshot + window + state=Active
        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: 100 ether,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        registry.configureProgram(programId, cfg);

        // fund the basket (hotWallet holds 100% of supply → claiming 100 pays the full totals)
        _fundUsd(300e6);
        _fund(newToken, 200 ether);
        _fund(cvr, 100 ether);
    }

    function _fund(ScaledToken t, uint256 amount) internal {
        t.mint(amount);
        t.approve(address(registry), amount);
        registry.fund(programId, address(t), amount);
    }

    function _fundUsd(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(registry), amount);
        registry.fund(programId, address(usdc), amount);
    }

    // ── tests ───────────────────────────────────────────────────────────────────

    /// @dev End-to-end: hot wallet transfers OLD in, OPS claims, basket lands back in the hot wallet.
    function test_claimFor_forwardsBasketToHotWallet() public {
        // hot wallet does the only thing it can: a plain ERC-20 transfer into the router
        vm.prank(hotWallet);
        oldToken.transfer(address(router), 100 ether);

        vm.expectEmit(true, true, true, true, address(router));
        emit CustodyClaimRouter.ClaimedFor(programId, hotWallet, ops, 100 ether);
        vm.prank(ops);
        router.claimFor(programId, hotWallet, 100 ether);

        // OLD burned; basket delivered to the hot wallet; router left empty
        assertEq(oldToken.totalSupply(), 0, "old burned");
        assertEq(oldToken.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(hotWallet), 300e6);
        assertEq(newToken.balanceOf(hotWallet), 200 ether);
        assertEq(cvr.balanceOf(hotWallet), 100 ether);
        assertEq(usdc.balanceOf(address(router)), 0, "router keeps nothing");
        assertEq(newToken.balanceOf(address(router)), 0);
        assertEq(cvr.balanceOf(address(router)), 0);
    }

    /// @dev claimFor refuses any recipient not on the hot-wallet allowlist.
    function test_claimFor_rejectsUnregisteredHotWallet() public {
        vm.prank(hotWallet);
        oldToken.transfer(address(router), 100 ether);

        vm.prank(ops);
        vm.expectRevert(CustodyClaimRouter.NotRegisteredHotWallet.selector);
        router.claimFor(programId, stranger, 100 ether);
    }

    /// @dev Only OPS can trigger a claim.
    function test_claimFor_onlyOps() public {
        vm.prank(hotWallet);
        oldToken.transfer(address(router), 100 ether);

        vm.prank(stranger);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        router.claimFor(programId, hotWallet, 100 ether);
    }

    /// @dev Amount is bounded by what the router actually holds — OPS cannot conjure more.
    function test_claimFor_amountBoundedByRouterBalance() public {
        vm.prank(hotWallet);
        oldToken.transfer(address(router), 40 ether); // only 40 in

        vm.prank(ops);
        vm.expectRevert(); // ERC20 insufficient balance on registry.transferFrom(router)
        router.claimFor(programId, hotWallet, 100 ether);
    }

    /// @dev Registering hot wallets is admin-only; a leaked OPS key cannot self-authorize a payee.
    function test_registerHotWallet_onlyAdmin() public {
        vm.prank(ops);
        vm.expectRevert(); // OPS lacks DEFAULT_ADMIN_ROLE
        router.registerHotWallet(stranger);
    }

    /// @dev Deregistered hot wallets can no longer be paid.
    function test_deregisteredHotWalletCannotClaim() public {
        vm.prank(admin);
        router.deregisterHotWallet(hotWallet);

        vm.prank(hotWallet);
        oldToken.transfer(address(router), 100 ether);

        vm.prank(ops);
        vm.expectRevert(CustodyClaimRouter.NotRegisteredHotWallet.selector);
        router.claimFor(programId, hotWallet, 100 ether);
    }

    /// @dev Admin can rescue tokens transferred in but never claimed.
    function test_rescue_recoversStrayOldTokens() public {
        vm.prank(hotWallet);
        oldToken.transfer(address(router), 100 ether);

        vm.prank(admin);
        router.rescue(address(oldToken), custody, 100 ether);
        assertEq(oldToken.balanceOf(custody), 100 ether);
        assertEq(oldToken.balanceOf(address(router)), 0);
    }

    function test_rescue_onlyAdmin() public {
        vm.prank(ops);
        vm.expectRevert();
        router.rescue(address(oldToken), custody, 1);
    }
}
