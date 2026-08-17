// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../src/pauseRegistry/PauseRegistry.sol";
import {PrivatizationRegistry} from "../src/privatization/PrivatizationRegistry.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

/// @notice Tests for PrivatizationRegistry: program-ified fixed-rate delisting with per-program
///         reserve accounting. The test contract holds ISSUER_ROLE on the tokens (to seed old
///         balances and mint reward inventory) and OPS_ROLE on the registry (to fund).
contract PrivatizationRegistryTest is Test {
    ScaledTokenFactory internal factory;
    ComplianceRegistry internal compliance;
    PauseRegistry internal pauseManager;
    PrivatizationRegistry internal registry;
    MockUSD internal usdc;

    ScaledToken internal oldToken; // A
    ScaledToken internal newToken; // B
    ScaledToken internal cvr; // CVR-mStock

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal complianceOps = makeAddr("complianceOps");
    address internal custody = makeAddr("custody");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal BURN_ROLE;

    function setUp() public {
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = new ScaledTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin, 24 hours);
        usdc = new MockUSD();
        registry = PrivatizationRegistry(
            address(
                new ERC1967Proxy(
                    address(new PrivatizationRegistry()), abi.encodeCall(PrivatizationRegistry.initialize, (admin))
                )
            )
        );

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        address[] memory none = new address[](0);
        oldToken = ScaledToken(factory.createToken("Old Co", "OLD", "US0000000001", admin, issuers, none));
        newToken = ScaledToken(factory.createToken("New Co", "NEW", "US0000000002", admin, issuers, none));
        cvr = ScaledToken(factory.createToken("Deal CVR", "CVR", "US0000000003", admin, issuers, none));

        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        registry.grantRole(registry.OPS_ROLE(), address(this)); // test funds programs
        vm.stopPrank();

        BURN_ROLE = oldToken.BURN_ROLE();
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _seed(ScaledToken t, address to, uint256 amount) internal {
        t.mint(amount);
        t.transfer(to, amount);
    }

    function _fund(uint256 programId, ScaledToken t, uint256 amount) internal {
        t.mint(amount);
        t.approve(address(registry), amount);
        registry.fund(programId, address(t), amount);
    }

    function _fundUsd(uint256 programId, uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(registry), amount);
        registry.fund(programId, address(usdc), amount);
    }

    /// @dev The registry only ever burns surrendered old tokens, so it gets BURN_ROLE only
    ///      (least privilege — it cannot mint), plus supply is frozen after seeding.
    function _grantBurn(ScaledToken t) internal {
        vm.prank(admin);
        t.grantRole(BURN_ROLE, address(registry));
        vm.prank(admin);
        t.setMintAllowed(false);
    }

    function _legs3() internal view returns (PrivatizationRegistry.Leg[] memory legs) {
        legs = new PrivatizationRegistry.Leg[](3);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 3e6); // 3 USDC / OLD
        legs[1] = PrivatizationRegistry.Leg(address(newToken), 2e18); // 2 NEW / OLD
        legs[2] = PrivatizationRegistry.Leg(address(cvr), 1e18); // 1 CVR / OLD
    }

    function _blockOnNew(address who) internal {
        address[] memory arr = new address[](1);
        arr[0] = who;
        vm.prank(complianceOps);
        compliance.blockUsers(address(newToken), arr);
    }

    // ── tests ─────────────────────────────────────────────────────────────────

    function test_createFundClaim_multiLegBasket() public {
        _seed(oldToken, alice, 100 ether);

        vm.prank(admin);
        uint256 id = registry.createProgram(address(oldToken), _legs3(), uint64(block.timestamp + 7 days));
        _grantBurn(oldToken);
        _fundUsd(id, 300e6);
        _fund(id, newToken, 200 ether);
        _fund(id, cvr, 100 ether);

        uint256[] memory outs = registry.previewClaim(id, 100 ether);
        assertEq(outs[0], 300e6);
        assertEq(outs[1], 200 ether);
        assertEq(outs[2], 100 ether);

        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(id, 100 ether);
        vm.stopPrank();

        assertEq(oldToken.balanceOf(alice), 0);
        assertEq(oldToken.totalSupply(), 0, "old burned");
        assertEq(usdc.balanceOf(alice), 300e6);
        assertEq(newToken.balanceOf(alice), 200 ether);
        assertEq(cvr.balanceOf(alice), 100 ether);
        assertEq(registry.reserved(id, address(usdc)), 0);
        assertEq(registry.reserved(id, address(newToken)), 0);
    }

    function test_programIsolation() public {
        _seed(oldToken, alice, 100 ether);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 5e6);

        vm.startPrank(admin);
        uint256 p0 = registry.createProgram(address(oldToken), legs, uint64(block.timestamp + 7 days));
        uint256 p1 = registry.createProgram(address(newToken), legs, uint64(block.timestamp + 7 days));
        vm.stopPrank();
        _grantBurn(oldToken);

        _fundUsd(p0, 500e6);
        _fundUsd(p1, 999e6); // sibling program's money

        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(p0, 100 ether);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 500e6);
        assertEq(registry.reserved(p0, address(usdc)), 0);
        assertEq(registry.reserved(p1, address(usdc)), 999e6, "sibling program's reserve untouched");
    }

    function test_claim_insufficientReservedReverts() public {
        _seed(oldToken, alice, 100 ether);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 5e6);
        vm.prank(admin);
        uint256 id = registry.createProgram(address(oldToken), legs, uint64(block.timestamp + 7 days));
        _grantBurn(oldToken);
        _fundUsd(id, 100e6); // underfunded: owed 500e6

        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.InsufficientReserved.selector);
        registry.claim(id, 100 ether);
        vm.stopPrank();
    }

    function test_claim_blockedHolderRevertsWhole() public {
        _seed(oldToken, bob, 100 ether);
        vm.prank(admin);
        uint256 id = registry.createProgram(address(oldToken), _legs3(), uint64(block.timestamp + 7 days));
        _grantBurn(oldToken);
        _fundUsd(id, 300e6);
        _fund(id, newToken, 200 ether);
        _fund(id, cvr, 100 ether);
        _blockOnNew(bob);

        vm.startPrank(bob);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert();
        registry.claim(id, 100 ether);
        vm.stopPrank();
        assertEq(oldToken.balanceOf(bob), 100 ether, "old not taken on failed claim");
    }

    function test_claim_afterDeadlineReverts_and_sweep() public {
        _seed(oldToken, alice, 100 ether);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 5e6);
        vm.prank(admin);
        uint256 id = registry.createProgram(address(oldToken), legs, uint64(block.timestamp + 1 days));
        _grantBurn(oldToken);
        _fundUsd(id, 500e6);

        vm.prank(admin);
        vm.expectRevert(PrivatizationRegistry.ClaimStillOpen.selector);
        registry.sweepUnclaimed(id, custody);

        vm.warp(block.timestamp + 2 days);
        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.ClaimClosed.selector);
        registry.claim(id, 100 ether);
        vm.stopPrank();

        vm.prank(admin);
        registry.sweepUnclaimed(id, custody);
        assertEq(usdc.balanceOf(custody), 500e6);
        assertEq(registry.reserved(id, address(usdc)), 0);
    }

    function test_cvrRedemption_reusesRegistry() public {
        // A holder ends up with a CVR-mStock; later a milestone opens a redemption program whose
        // oldToken IS the CVR-mStock, paying USDC + a bit of NEW stock — reusing this registry.
        _seed(cvr, alice, 100 ether);

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](2);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 4e6); // 4 USDC / CVR
        legs[1] = PrivatizationRegistry.Leg(address(newToken), 1e18); // 1 NEW / CVR

        vm.prank(admin);
        uint256 id = registry.createProgram(address(cvr), legs, uint64(block.timestamp + 7 days));
        _grantBurn(cvr); // registry burns the surrendered CVR
        _fundUsd(id, 400e6);
        _fund(id, newToken, 100 ether);

        vm.startPrank(alice);
        cvr.approve(address(registry), 100 ether);
        registry.claim(id, 100 ether);
        vm.stopPrank();

        assertEq(cvr.balanceOf(alice), 0, "CVR redeemed + burned");
        assertEq(usdc.balanceOf(alice), 400e6);
        assertEq(newToken.balanceOf(alice), 100 ether);
    }

    function test_createProgram_rejectsEmptyLegs() public {
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](0);
        vm.prank(admin);
        vm.expectRevert(PrivatizationRegistry.NoLegs.selector);
        registry.createProgram(address(oldToken), legs, uint64(block.timestamp + 1 days));
    }
}
