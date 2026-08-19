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

/// @notice Tests for PrivatizationRegistry: program-ified delisting where each leg carries a
///         `total` and a claim pays pro-rata `amount * total / oldSupplySnapshot`. The test
///         contract holds ISSUER_ROLE on the tokens (to seed old balances and mint reward
///         inventory) and OPS_ROLE on the registry (to fund).
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
    address internal tokenOps = makeAddr("tokenOps");

    bytes32 internal BURN_ROLE;
    uint64 internal constant WEEK = 7 days;

    function setUp() public {
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = new ScaledTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin, 24 hours);
        factory.grantRole(factory.OPS_ROLE(), admin); // createToken is OPS-gated (role-opt)
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
        registry.grantRole(registry.OPS_ROLE(), address(this)); // test drives lifecycle (create/configure/fund/sweep)
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

    /// @dev Grant the registry BURN_ROLE on `t` (least privilege — burn only) and freeze its
    ///      supply (setMintAllowed is OPS-gated, so route through a tokenOps actor). Must run after
    ///      all seeding, since freeze stops minting — the frozen supply is what configure snapshots.
    function _freeze(ScaledToken t) internal {
        bytes32 opsRole = t.OPS_ROLE(); // cache before pranks (arg call would consume the prank)
        vm.startPrank(admin);
        t.grantRole(BURN_ROLE, address(registry));
        t.grantRole(opsRole, tokenOps);
        vm.stopPrank();
        vm.prank(tokenOps);
        t.setMintAllowed(false);
    }

    /// @dev OPS configures the window; the contract snapshots the (frozen) old supply. Called as
    ///      address(this), which holds the registry OPS_ROLE (see setUp).
    function _configure(uint256 programId, uint64 startTime, uint64 deadline) internal {
        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0), startTime: startTime, deadline: deadline, oldSupplySnapshot: 0, state: 0
        });
        registry.configureProgram(programId, cfg);
    }

    /// @dev freeze + configure with a default [now, now+1w] window.
    function _activate(uint256 programId, ScaledToken old) internal {
        _freeze(old);
        _configure(programId, uint64(block.timestamp), uint64(block.timestamp + WEEK));
    }

    function _legs3() internal view returns (PrivatizationRegistry.Leg[] memory legs) {
        legs = new PrivatizationRegistry.Leg[](3);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 300e6); // 300 USDC total
        legs[1] = PrivatizationRegistry.Leg(address(newToken), 200 ether); // 200 NEW total
        legs[2] = PrivatizationRegistry.Leg(address(cvr), 100 ether); // 100 CVR total
    }

    function _blockOnNew(address who) internal {
        address[] memory arr = new address[](1);
        arr[0] = who;
        vm.prank(complianceOps);
        compliance.blockUsers(address(newToken), arr);
    }

    // ── tests ─────────────────────────────────────────────────────────────────

    /// @dev A sole holder (100% of supply) claims the entire per-leg `total`.
    function test_createConfigureFundClaim_multiLegBasket() public {
        _seed(oldToken, alice, 100 ether); // alice holds the whole 100e18 supply

        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activate(id, oldToken); // snapshot = 100e18
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

    /// @dev The pro-rata denominator is the FROZEN snapshot, not live supply: two holders split
    ///      `total` by their share and Σ payouts == total, even though burns shrink live supply
    ///      between the two claims.
    function test_proRata_twoHolders_noOverDistribution() public {
        _seed(oldToken, alice, 60 ether);
        _seed(oldToken, bob, 40 ether); // total supply 100e18

        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activate(id, oldToken); // snapshot = 100e18 (fixed)
        _fundUsd(id, 300e6);
        _fund(id, newToken, 200 ether);
        _fund(id, cvr, 100 ether);

        vm.startPrank(alice);
        oldToken.approve(address(registry), 60 ether);
        registry.claim(id, 60 ether); // 60/100 of each total
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 180e6);
        assertEq(newToken.balanceOf(alice), 120 ether);
        assertEq(cvr.balanceOf(alice), 60 ether);

        // supply is now 40e18, but bob still divides by the 100e18 snapshot → 40/100, not 40/40
        vm.startPrank(bob);
        oldToken.approve(address(registry), 40 ether);
        registry.claim(id, 40 ether);
        vm.stopPrank();
        assertEq(usdc.balanceOf(bob), 120e6);
        assertEq(newToken.balanceOf(bob), 80 ether);
        assertEq(cvr.balanceOf(bob), 40 ether);

        // Σ == total; reserves drained; no over-distribution
        assertEq(registry.reserved(id, address(usdc)), 0);
        assertEq(registry.reserved(id, address(newToken)), 0);
        assertEq(registry.reserved(id, address(cvr)), 0);
        assertEq(oldToken.totalSupply(), 0, "all old burned");
    }

    function test_programIsolation() public {
        _seed(oldToken, alice, 100 ether);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 500e6);

        uint256 p0 = registry.createProgram(address(oldToken), legs);
        uint256 p1 = registry.createProgram(address(newToken), legs);
        _activate(p0, oldToken); // snapshot oldToken supply = 100e18

        _fundUsd(p0, 500e6);
        _fundUsd(p1, 999e6); // sibling program's money (p1 stays Created — never claimed)

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
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 500e6);
        uint256 id = registry.createProgram(address(oldToken), legs);
        _activate(id, oldToken);
        _fundUsd(id, 100e6); // underfunded: owes the full 500e6 to the sole holder

        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.InsufficientReserved.selector);
        registry.claim(id, 100 ether);
        vm.stopPrank();
    }

    function test_claim_blockedHolderRevertsWhole() public {
        _seed(oldToken, bob, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activate(id, oldToken);
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
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 500e6);
        uint256 id = registry.createProgram(address(oldToken), legs);
        _freeze(oldToken);
        _configure(id, uint64(block.timestamp), uint64(block.timestamp + 1 days));
        _fundUsd(id, 500e6);

        vm.expectRevert(PrivatizationRegistry.ClaimStillOpen.selector);
        registry.sweepUnclaimed(id, custody);

        vm.warp(block.timestamp + 2 days);
        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.ClaimClosed.selector);
        registry.claim(id, 100 ether);
        vm.stopPrank();

        registry.sweepUnclaimed(id, custody);
        assertEq(usdc.balanceOf(custody), 500e6);
        assertEq(registry.reserved(id, address(usdc)), 0);
    }

    function test_cvrRedemption_reusesRegistry() public {
        // A holder ends up with a CVR-mStock; later a milestone opens a redemption program whose
        // oldToken IS the CVR-mStock, paying USDC + a bit of NEW stock — reusing this registry.
        _seed(cvr, alice, 100 ether);

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](2);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 400e6); // 400 USDC total
        legs[1] = PrivatizationRegistry.Leg(address(newToken), 100 ether); // 100 NEW total

        uint256 id = registry.createProgram(address(cvr), legs);
        _activate(id, cvr); // freeze the CVR + snapshot its supply
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
        vm.expectRevert(PrivatizationRegistry.NoLegs.selector);
        registry.createProgram(address(oldToken), legs);
    }

    /// @dev configureProgram refuses to snapshot until the old supply is frozen.
    function test_configure_requiresFrozenSupply() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());

        // grant BURN_ROLE but do NOT freeze → configure must revert
        vm.prank(admin);
        oldToken.grantRole(BURN_ROLE, address(registry));

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + WEEK),
            oldSupplySnapshot: 0,
            state: 0
        });
        vm.expectRevert(PrivatizationRegistry.SupplyNotFrozen.selector);
        registry.configureProgram(id, cfg);
    }

    /// @dev A claim before the window opens reverts.
    function test_claim_beforeStartReverts() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _freeze(oldToken);
        _configure(id, uint64(block.timestamp + 1 days), uint64(block.timestamp + WEEK)); // starts in the future
        _fundUsd(id, 300e6);
        _fund(id, newToken, 200 ether);
        _fund(id, cvr, 100 ether);

        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.ClaimNotStarted.selector);
        registry.claim(id, 100 ether);
        vm.stopPrank();
    }

    /// @dev The whole program lifecycle is OPS-only — the registry admin (role manager) cannot
    ///      create a program (and, being unable to self-grant OPS, never gains that power directly).
    function test_createProgram_isOpsOnly_notAdmin() public {
        vm.prank(admin);
        vm.expectRevert(); // AccessControlUnauthorizedAccount — admin lacks OPS_ROLE
        registry.createProgram(address(oldToken), _legs3());
    }
}
