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
        registryOps[0] = address(this); // test drives lifecycle (create/configure/fund/sweep)
        registry = PrivatizationRegistry(
            address(
                new ERC1967Proxy(
                    address(new PrivatizationRegistry()),
                    abi.encodeCall(PrivatizationRegistry.initialize, (admin, registryOps))
                )
            )
        );
        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        registry.registerSweepRecipient(custody); // sweep destination used throughout these tests
        vm.stopPrank();

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        address[] memory none = new address[](0);
        oldToken = ScaledToken(factory.createToken("Old Co", "OLD", "US0000000001", admin, issuers, none, none));
        newToken = ScaledToken(factory.createToken("New Co", "NEW", "US0000000002", admin, issuers, none, none));
        cvr = ScaledToken(factory.createToken("Deal CVR", "CVR", "US0000000003", admin, issuers, none, none));

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
    /// @dev Grants the registry BURN_ROLE without freezing mint, so a test can show what
    ///      the freeze is protecting.
    function _grantBurn(ScaledToken t) internal {
        vm.prank(admin);
        t.grantRole(BURN_ROLE, address(registry));
    }

    function _freeze(ScaledToken t) internal {
        bytes32 opsRole = t.OPS_ROLE(); // cache before pranks (arg call would consume the prank)
        vm.startPrank(admin);
        t.grantRole(BURN_ROLE, address(registry));
        t.grantRole(opsRole, tokenOps);
        vm.stopPrank();
        vm.prank(tokenOps);
        t.setMintAllowed(false);
    }

    /// @dev OPS configures the window. Under the patch model the caller supplies the snapshot (the
    ///      frozen totalSupply, read here as an off-chain operator would) and sets state=Active.
    /// @dev Configures the snapshot and window but leaves the program Created. Opening it
    ///      is a separate step because the contract requires every leg to be funded first.
    function _configure(uint256 programId, uint64 startTime, uint64 deadline) internal {
        (address oldTok,,,,) = registry.programs(programId);
        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: startTime,
            deadline: deadline,
            oldSupplySnapshot: ScaledToken(oldTok).totalSupply(),
            state: 0 // stay Created until every leg is funded
        });
        registry.configureProgram(programId, cfg);
    }

    /// @dev Flips a fully funded program to Active.
    function _open(uint256 programId) internal {
        registry.configureProgram(
            programId,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: 0,
                deadline: 0,
                oldSupplySnapshot: 0,
                state: uint8(PrivatizationRegistry.State.Active)
            })
        );
    }

    /// @dev freeze + configure with a default [now, now+1w] window. Still Created.
    function _activate(uint256 programId, ScaledToken old) internal {
        _freeze(old);
        _configure(programId, uint64(block.timestamp), uint64(block.timestamp + WEEK));
    }

    /// @dev The whole opening sequence for a `_legs3()` basket: configure, fund all three
    ///      legs to their totals, open.
    function _activateAndFundLegs3(uint256 programId, ScaledToken old) internal {
        _activate(programId, old);
        _fundUsd(programId, 300e6);
        _fund(programId, newToken, 200 ether);
        _fund(programId, cvr, 100 ether);
        _open(programId);
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
        _activateAndFundLegs3(id, oldToken); // snapshot = 100e18

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
        _activateAndFundLegs3(id, oldToken); // snapshot = 100e18 (fixed)

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
        _open(p0);

        // p1's money. It needs its own snapshot before it can be funded at all now, and it
        // is left Created deliberately: the point is that p0's claim cannot reach it.
        _freeze(newToken);
        registry.configureProgram(
            p1,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp + WEEK),
                oldSupplySnapshot: 1 ether, // newToken has no supply here; any non-zero denominator
                state: 0
            })
        );
        _fundUsd(p1, 999e6);

        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(p0, 100 ether);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 500e6);
        assertEq(registry.reserved(p0, address(usdc)), 0);
        assertEq(registry.reserved(p1, address(usdc)), 999e6, "sibling program's reserve untouched");
    }

    /// oldToken and the legs are fixed at creation, but oldSupplySnapshot — the claim
    /// denominator — is not, and funding locks it. Without this guard a caller could fund
    /// straight after creating and strand the snapshot at zero: previewClaim returns zeros
    /// and every claim reverts on the division, while the reserves sit there.
    function test_fund_beforeSnapshotIsSetReverts() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());

        usdc.mint(address(this), 300e6);
        usdc.approve(address(registry), 300e6);
        vm.expectRevert(PrivatizationRegistry.SupplySnapshotNotSet.selector);
        registry.fund(id, address(usdc), 300e6);

        assertEq(registry.reserved(id, address(usdc)), 0, "nothing was taken");

        // In the right order it goes through.
        _freeze(oldToken);
        _configure(id, uint64(block.timestamp), uint64(block.timestamp + WEEK));
        _fundUsd(id, 300e6);
        assertEq(registry.reserved(id, address(usdc)), 300e6);
    }

    /// Under-funding can no longer produce InsufficientReserved: opening a program requires
    /// every leg's reserve to cover its total, and payouts are `amount * total / snapshot`
    /// over a supply that cannot exceed the snapshot — so the reserve is sufficient by
    /// construction.
    ///
    /// It survives for one case, and this is what the freeze step exists to prevent: if the
    /// old token can still be minted after the snapshot is taken, total supply outgrows the
    /// denominator, the program promises more than `total`, and whoever claims last is left
    /// short. Here the token is deliberately not frozen.
    function test_claim_insufficientReservedWhenSupplyOutgrowsTheSnapshot() public {
        _seed(oldToken, alice, 100 ether);
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 500e6);
        uint256 id = registry.createProgram(address(oldToken), legs);

        _grantBurn(oldToken); // burn permitted, mint NOT frozen
        _configure(id, uint64(block.timestamp), uint64(block.timestamp + WEEK)); // snapshot = 100e18
        _fundUsd(id, 500e6);
        _open(id); // fully funded against the snapshot

        // Supply doubles after the snapshot was taken.
        _seed(oldToken, bob, 100 ether);

        // bob claims first and the denominator still says he owns all of it.
        vm.startPrank(bob);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(id, 100 ether);
        vm.stopPrank();
        assertEq(usdc.balanceOf(bob), 500e6, "bob drained the whole leg");
        assertEq(registry.reserved(id, address(usdc)), 0);

        // alice is owed the same 500e6 and there is nothing left.
        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        vm.expectRevert(PrivatizationRegistry.InsufficientReserved.selector);
        registry.claim(id, 100 ether);
        vm.stopPrank();
    }

    /// Funding is a Created-state action. Active asserts that every leg's reserve covers its
    /// total, and that assertion would mean nothing if the reserves could still move —
    /// including upward, since a later top-up implies it was wrong when made.
    function test_fund_lockedOnceActive() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);

        usdc.mint(address(this), 1e6);
        usdc.approve(address(registry), 1e6);
        vm.expectRevert(PrivatizationRegistry.FundLockedOnceActive.selector);
        registry.fund(id, address(usdc), 1e6);
        assertEq(registry.reserved(id, address(usdc)), 300e6, "unchanged");
    }

    /// And after sweeping, which the same condition covers.
    function test_fund_lockedOnceClosed() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);
        vm.warp(block.timestamp + 2 * WEEK);
        registry.sweepUnclaimed(id, custody);

        usdc.mint(address(this), 1e6);
        usdc.approve(address(registry), 1e6);
        vm.expectRevert(PrivatizationRegistry.FundLockedOnceActive.selector);
        registry.fund(id, address(usdc), 1e6);
    }

    /// The check that makes the above unreachable through the normal path. A basket short on
    /// any leg pays out on none of them, since claim() delivers every leg or reverts, so the
    /// bound is per leg rather than "something was funded".
    function test_configureProgram_activeRequiresEveryLegFunded() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _freeze(oldToken);
        _configure(id, uint64(block.timestamp), uint64(block.timestamp + WEEK));

        vm.expectRevert(
            abi.encodeWithSelector(PrivatizationRegistry.LegNotFullyFunded.selector, address(usdc), 0, 300e6)
        );
        _open(id);

        _fundUsd(id, 300e6);
        _fund(id, newToken, 200 ether);
        // cvr leg still empty — two of three is not enough.
        vm.expectRevert(
            abi.encodeWithSelector(PrivatizationRegistry.LegNotFullyFunded.selector, address(cvr), 0, 100 ether)
        );
        _open(id);

        // Short by one wei on the last leg is still short.
        _fund(id, cvr, 100 ether - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrivatizationRegistry.LegNotFullyFunded.selector, address(cvr), 100 ether - 1, 100 ether
            )
        );
        _open(id);

        _fund(id, cvr, 1);
        _open(id);
        (,,,, uint8 state) = registry.programs(id);
        assertEq(state, uint8(PrivatizationRegistry.State.Active));
    }

    function test_claim_blockedHolderRevertsWhole() public {
        _seed(oldToken, bob, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);
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
        _open(id);

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
        _open(id);

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

    /// @dev Patch semantics: a zero field keeps the stored value; only non-zero fields overwrite.
    function test_configure_patchKeepsZeroFields() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _freeze(oldToken);

        // First configure: set the window and snapshot, staying Created — patching is only
        // allowed there now, so this is where "zero means keep" has to hold.
        uint64 start = uint64(block.timestamp);
        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: start,
            deadline: uint64(block.timestamp + WEEK),
            oldSupplySnapshot: 100 ether,
            state: 0
        });
        registry.configureProgram(id, cfg);

        // Patch: change ONLY the deadline; every other field passed as 0 must stay put.
        uint64 newDeadline = uint64(block.timestamp + 2 * WEEK);
        PrivatizationRegistry.Program memory patch = PrivatizationRegistry.Program({
            oldToken: address(0), startTime: 0, deadline: newDeadline, oldSupplySnapshot: 0, state: 0
        });
        registry.configureProgram(id, patch);

        (address oldTok, uint64 st, uint64 dl, uint256 snap, uint8 state) = registry.programs(id);
        assertEq(oldTok, address(oldToken), "oldToken kept");
        assertEq(st, start, "startTime kept");
        assertEq(dl, newDeadline, "deadline overwritten");
        assertEq(snap, 100 ether, "snapshot kept");
        assertEq(state, uint8(PrivatizationRegistry.State.Created), "state kept: a zero patch does not open it");
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
        _open(id);

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

    // ── configureProgram lock guards ─────────────────────────────────────────────

    /// @dev Once any leg has been funded, oldToken/oldSupplySnapshot must not move — but other
    ///      fields (e.g. deadline) remain adjustable.
    function test_configureProgram_termsLockedAfterFund() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activate(id, oldToken);
        _fundUsd(id, 300e6); // any non-zero reserve locks the terms

        vm.expectRevert(PrivatizationRegistry.TermsLockedAfterFund.selector);
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0), startTime: 0, deadline: 0, oldSupplySnapshot: 999 ether, state: 0
            })
        );

        vm.expectRevert(PrivatizationRegistry.TermsLockedAfterFund.selector);
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(newToken), startTime: 0, deadline: 0, oldSupplySnapshot: 0, state: 0
            })
        );

        // other fields remain adjustable after funding
        uint64 newDeadline = uint64(block.timestamp) + 30 days;
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0), startTime: 0, deadline: newDeadline, oldSupplySnapshot: 0, state: 0
            })
        );
        (,, uint64 deadline,,) = registry.programs(id);
        assertEq(deadline, newDeadline);
    }

    /// @dev Once any claim has succeeded, configureProgram refuses the whole patch — every
    ///      claimant of a program must be settled under identical terms.
    function test_configureProgram_lockedAfterClaimStarted() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);

        vm.startPrank(alice);
        oldToken.approve(address(registry), 50 ether);
        registry.claim(id, 50 ether);
        vm.stopPrank();

        vm.expectRevert(PrivatizationRegistry.ConfigureLockedOnceActive.selector);
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: 0,
                deadline: uint64(block.timestamp) + 999 days, // even a "harmless" deadline extension
                oldSupplySnapshot: 0,
                state: 0
            })
        );
    }

    function test_configureProgram_cannotRegressState() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activate(id, oldToken); // now Active

        vm.expectRevert(PrivatizationRegistry.InvalidStateTransition.selector);
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: 0,
                deadline: 0,
                oldSupplySnapshot: 0,
                state: uint8(PrivatizationRegistry.State.Created)
            })
        );
    }

    function test_configureProgram_cannotJumpToClosed() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3()); // Created

        vm.expectRevert(PrivatizationRegistry.InvalidStateTransition.selector);
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: 0,
                deadline: 0,
                oldSupplySnapshot: 0,
                state: uint8(PrivatizationRegistry.State.Closed)
            })
        );
    }

    function test_configureProgram_cannotReopenClosedProgram() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _freeze(oldToken);
        _configure(id, uint64(block.timestamp), uint64(block.timestamp + 1 days));
        _fundUsd(id, 300e6);
        _fund(id, newToken, 200 ether);
        _fund(id, cvr, 100 ether);
        _open(id);
        vm.warp(block.timestamp + 2 days);
        registry.sweepUnclaimed(id, custody); // now Closed

        // Closed is not Created, so the configure lock covers it — which also answers
        // whether a swept program's snapshot could still be rewritten. It cannot.
        vm.expectRevert(PrivatizationRegistry.ConfigureLockedOnceActive.selector);
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: 0,
                deadline: 0,
                oldSupplySnapshot: 0,
                state: uint8(PrivatizationRegistry.State.Active)
            })
        );
    }

    // ── configureProgram window validation ──────────────────────────────────────

    function test_configureProgram_activationRejectsExpiredWindow() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activate(id, oldToken);
        _fundUsd(id, 300e6);
        _fund(id, newToken, 200 ether);
        _fund(id, cvr, 100 ether);
        vm.warp(block.timestamp + 2 * WEEK);
        vm.expectRevert(PrivatizationRegistry.InvalidWindow.selector);
        _open(id);
        (,,,, uint8 state) = registry.programs(id);
        assertEq(state, uint8(PrivatizationRegistry.State.Created));
        assertEq(registry.reserved(id, address(usdc)), 300e6);

        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: 0,
                deadline: uint64(block.timestamp + WEEK),
                oldSupplySnapshot: 0,
                state: uint8(PrivatizationRegistry.State.Active)
            })
        );
        (,,,, state) = registry.programs(id);
        assertEq(state, uint8(PrivatizationRegistry.State.Active));
    }

    function test_configureProgram_activationRejectsDeadlineAtCurrentTime() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activate(id, oldToken);
        vm.warp(block.timestamp + WEEK);
        vm.expectRevert(PrivatizationRegistry.InvalidWindow.selector);
        _open(id);
    }

    function test_configureProgram_activationRejectsUnsetDeadline() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        vm.expectRevert(PrivatizationRegistry.InvalidWindow.selector);
        _open(id);
    }

    function test_configureProgram_rejectsPastDeadline() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        vm.expectRevert(PrivatizationRegistry.InvalidWindow.selector);
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: 0,
                deadline: uint64(block.timestamp), // not strictly in the future
                oldSupplySnapshot: 0,
                state: 0
            })
        );
    }

    function test_configureProgram_rejectsDeadlineNotAfterStartTime() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        vm.expectRevert(PrivatizationRegistry.InvalidWindow.selector);
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: uint64(block.timestamp) + 2 days,
                deadline: uint64(block.timestamp) + 1 days, // before startTime
                oldSupplySnapshot: 0,
                state: 0
            })
        );
    }

    function test_configureProgram_rejectsStartTimeMovedPastExistingDeadline() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + 1 days,
                oldSupplySnapshot: 0,
                state: 0
            })
        );

        vm.expectRevert(PrivatizationRegistry.InvalidWindow.selector);
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: uint64(block.timestamp) + 2 days, // now past the stored deadline
                deadline: 0,
                oldSupplySnapshot: 0,
                state: 0
            })
        );
    }

    function test_configureProgram_acceptsValidWindow() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(0),
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + 1 days,
                oldSupplySnapshot: 0,
                state: 0
            })
        );
        (, uint64 startTime, uint64 deadline,,) = registry.programs(id);
        assertEq(startTime, uint64(block.timestamp));
        assertEq(deadline, uint64(block.timestamp) + 1 days);
    }

    // ── oldToken uniqueness ──────────────────────────────────────────────────────

    /// @dev A second program cannot target an oldToken another program already targets — two
    ///      programs redeeming the same security against two independently-frozen snapshots would
    ///      let it be claimed against twice, inconsistently.
    function test_createProgram_rejectsDuplicateOldToken() public {
        registry.createProgram(address(oldToken), _legs3());

        vm.expectRevert(
            abi.encodeWithSelector(PrivatizationRegistry.OldTokenAlreadyRegistered.selector, address(oldToken))
        );
        registry.createProgram(address(oldToken), _legs3());
    }

    /// @dev A closed program's oldToken stays registered — it was retired, not freed up for reuse.
    function test_createProgram_rejectsOldTokenFromAClosedProgram() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);
        vm.warp(block.timestamp + 2 * WEEK);
        registry.sweepUnclaimed(id, custody); // now Closed

        vm.expectRevert(
            abi.encodeWithSelector(PrivatizationRegistry.OldTokenAlreadyRegistered.selector, address(oldToken))
        );
        registry.createProgram(address(oldToken), _legs3());
    }

    /// @dev configureProgram's oldToken repoint is subject to the same uniqueness check as creation.
    function test_configureProgram_rejectsRepointToAlreadyRegisteredOldToken() public {
        PrivatizationRegistry.Leg[] memory legsWithoutNewToken = new PrivatizationRegistry.Leg[](2);
        legsWithoutNewToken[0] = PrivatizationRegistry.Leg(address(usdc), 300e6);
        legsWithoutNewToken[1] = PrivatizationRegistry.Leg(address(cvr), 100 ether);
        registry.createProgram(address(newToken), legsWithoutNewToken); // registers newToken

        uint256 id = registry.createProgram(address(oldToken), _legs3());
        vm.expectRevert(
            abi.encodeWithSelector(PrivatizationRegistry.OldTokenAlreadyRegistered.selector, address(newToken))
        );
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(newToken), startTime: 0, deadline: 0, oldSupplySnapshot: 0, state: 0
            })
        );
    }

    /// @dev Repointing to a brand-new oldToken registers it; repointing back to the program's own
    ///      current oldToken is a no-op, not a self-conflict.
    function test_configureProgram_repointToFreshOldTokenRegistersIt() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3());

        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(cvr), startTime: 0, deadline: 0, oldSupplySnapshot: 0, state: 0
            })
        );
        (address oldTok,,,,) = registry.programs(id);
        assertEq(oldTok, address(cvr));
        assertTrue(registry.oldTokenRegistered(address(cvr)));

        // now a fresh program cannot also target cvr
        vm.expectRevert(abi.encodeWithSelector(PrivatizationRegistry.OldTokenAlreadyRegistered.selector, address(cvr)));
        registry.createProgram(address(cvr), _legs3());

        // re-supplying the program's own current oldToken is not treated as a repoint at all
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(cvr), startTime: 0, deadline: 0, oldSupplySnapshot: 0, state: 0
            })
        );
    }

    /// @dev A repoint frees the replaced token: it was never actually delisted (repoint is only
    ///      reachable while Created and unfunded, so nothing was ever burned against it), so it
    ///      must stay available — for a fresh program, or for repointing this program back.
    function test_configureProgram_repointFreesTheReplacedOldToken() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3ExCvr());
        assertTrue(registry.oldTokenRegistered(address(oldToken)));

        // mis-repoint: oldToken -> cvr
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(cvr), startTime: 0, deadline: 0, oldSupplySnapshot: 0, state: 0
            })
        );
        assertFalse(registry.oldTokenRegistered(address(oldToken)), "replaced token freed");
        assertTrue(registry.oldTokenRegistered(address(cvr)));

        // the correction channel can correct its own error: repoint straight back
        registry.configureProgram(
            id,
            PrivatizationRegistry.Program({
                oldToken: address(oldToken), startTime: 0, deadline: 0, oldSupplySnapshot: 0, state: 0
            })
        );
        (address oldTok,,,,) = registry.programs(id);
        assertEq(oldTok, address(oldToken), "repointed back to the original");
        assertTrue(registry.oldTokenRegistered(address(oldToken)));
        assertFalse(registry.oldTokenRegistered(address(cvr)), "abandoned repoint target freed too");

        // ...and the freed intermediate token can start a real program of its own
        uint256 id2 = registry.createProgram(address(cvr), _legs3ExCvr());
        (address oldTok2,,,,) = registry.programs(id2);
        assertEq(oldTok2, address(cvr));
    }

    /// @dev The freeing only applies to a repointed-away token. A token whose program actually ran
    ///      to completion stays registered forever — Closed programs are not configurable, so no
    ///      path can ever clear their oldToken.
    function test_configureProgram_closedProgramOldTokenStaysRegistered() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);
        vm.warp(block.timestamp + 2 * WEEK);
        registry.sweepUnclaimed(id, custody); // now Closed

        assertTrue(registry.oldTokenRegistered(address(oldToken)));
        vm.expectRevert(
            abi.encodeWithSelector(PrivatizationRegistry.OldTokenAlreadyRegistered.selector, address(oldToken))
        );
        registry.createProgram(address(oldToken), _legs3ExCvr());
    }

    /// @dev Legs basket without cvr, for tests that repoint a program's oldToken to cvr (a leg
    ///      token equal to oldToken is rejected at create).
    function _legs3ExCvr() internal view returns (PrivatizationRegistry.Leg[] memory legs) {
        legs = new PrivatizationRegistry.Leg[](2);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 300e6);
        legs[1] = PrivatizationRegistry.Leg(address(newToken), 200 ether);
    }

    // ── fund token validation ────────────────────────────────────────────────────

    /// @dev fund() refuses a token that isn't one of the program's legs — crediting it to
    ///      `reserved` anyway would strand it forever, since claim/sweep only iterate the legs.
    function test_fund_rejectsTokenNotInLegs() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3()); // legs: usdc, newToken, cvr
        _freeze(oldToken);
        _configure(id, uint64(block.timestamp), uint64(block.timestamp + WEEK));

        ScaledToken wrong = ScaledToken(
            factory.createToken(
                "Unrelated", "UNR", "US0000000099", admin, _issuersOf(address(this)), new address[](0), new address[](0)
            )
        );
        wrong.mint(1 ether);
        wrong.approve(address(registry), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PrivatizationRegistry.NotALegToken.selector, address(wrong)));
        registry.fund(id, address(wrong), 1 ether);
    }

    function _issuersOf(address issuer) internal pure returns (address[] memory issuers) {
        issuers = new address[](1);
        issuers[0] = issuer;
    }

    // ── revokeRole last-admin guard ──────────────────────────────────────────────

    /// @dev renounceRole already blocks removing the last admin; revokeRole is a second path to
    ///      the exact same self-removal (an admin can revoke its own role) and needs the same guard.
    /// @dev grantRole rejects address(0): it can never transact, but would still inflate the
    ///      member count the last-admin guards rely on.
    function test_grantRole_rejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PrivatizationRegistry.ZeroAddress.selector);
        registry.grantRole(0x00, address(0));
    }

    function test_AdminCannotRevokeLastAdmin() public {
        vm.prank(admin);
        vm.expectRevert(PrivatizationRegistry.CannotRenounceLastAdmin.selector);
        registry.revokeRole(0x00, admin);
    }

    function test_NonLastAdminCanBeRevoked() public {
        address secondAdmin = makeAddr("secondAdmin");
        vm.prank(admin);
        registry.grantRole(0x00, secondAdmin);

        vm.prank(admin);
        registry.revokeRole(0x00, secondAdmin);
        assertFalse(registry.hasRole(0x00, secondAdmin));
        assertTrue(registry.hasRole(0x00, admin), "sole remaining admin untouched");
    }

    // ── leg token cannot equal oldToken ─────────────────────────────────────────

    /// @dev A leg paid in `oldToken` itself would have claim() burn oldToken and then try to pay
    ///      that same leg out of a reserve that can never legitimately be funded (minting oldToken
    ///      back defeats the point of retiring it) — permanently DOSing every claim on the program.
    function test_createProgram_rejectsLegTokenEqualToOldToken() public {
        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](2);
        legs[0] = PrivatizationRegistry.Leg(address(usdc), 300e6);
        legs[1] = PrivatizationRegistry.Leg(address(oldToken), 100 ether); // mismatched: == oldToken

        vm.expectRevert(PrivatizationRegistry.BadLeg.selector);
        registry.createProgram(address(oldToken), legs);
    }

    function test_claimStartedGetterRemoved() public view {
        (bool ok,) = address(registry).staticcall(abi.encodeWithSignature("claimStarted(uint256)", 0));
        assertFalse(ok, "obsolete getter removed");
    }

    // ── previewClaim considers program state ────────────────────────────────────

    /// @dev previewClaim returns zeros while still Created, even once snapshot + window are set —
    ///      claim() itself would revert (not yet Active), so previewing a payout here is misleading.
    function test_previewClaim_zeroWhileCreated() public {
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _freeze(oldToken);
        _configure(id, uint64(block.timestamp), uint64(block.timestamp + WEEK)); // snapshot set, stays Created

        uint256[] memory outs = registry.previewClaim(id, 100 ether);
        for (uint256 i = 0; i < outs.length; ++i) {
            assertEq(outs[i], 0);
        }
    }

    /// @dev previewClaim returns zeros again once the program has closed.
    function test_previewClaim_zeroOnceClosed() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);
        vm.warp(block.timestamp + 2 * WEEK);
        registry.sweepUnclaimed(id, custody); // now Closed

        uint256[] memory outs = registry.previewClaim(id, 100 ether);
        for (uint256 i = 0; i < outs.length; ++i) {
            assertEq(outs[i], 0);
        }
    }

    /// @dev previewClaim returns the real pro-rata payout once Active — the one state it's meant
    ///      to preview.
    function test_previewClaim_nonZeroWhenActive() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);

        uint256[] memory outs = registry.previewClaim(id, 100 ether);
        assertEq(outs[0], 300e6);
        assertEq(outs[1], 200 ether);
        assertEq(outs[2], 100 ether);
    }

    function test_sweepUnclaimed_emptyReservesCloseWithoutEvent() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);
        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(id, 100 ether);
        vm.stopPrank();
        assertEq(registry.reserved(id, address(usdc)), 0);
        assertEq(registry.reserved(id, address(newToken)), 0);
        assertEq(registry.reserved(id, address(cvr)), 0);
        vm.warp(block.timestamp + 2 * WEEK);

        vm.recordLogs();
        registry.sweepUnclaimed(id, custody);
        assertEq(vm.getRecordedLogs().length, 0, "no transfers or Swept event");
        (,,,, uint8 state) = registry.programs(id);
        assertEq(state, uint8(PrivatizationRegistry.State.Closed));
    }

    function test_sweepUnclaimed_oneRemainingLegEmitsEvent() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activate(id, oldToken);
        _fundUsd(id, 301e6); // one extra USDC remains after the full claim
        _fund(id, newToken, 200 ether);
        _fund(id, cvr, 100 ether);
        _open(id);
        vm.startPrank(alice);
        oldToken.approve(address(registry), 100 ether);
        registry.claim(id, 100 ether);
        vm.stopPrank();
        assertEq(registry.reserved(id, address(newToken)), 0);
        assertEq(registry.reserved(id, address(cvr)), 0);
        vm.warp(block.timestamp + 2 * WEEK);

        vm.expectEmit(true, true, false, true, address(registry));
        emit PrivatizationRegistry.Swept(id, custody);
        registry.sweepUnclaimed(id, custody);
        assertEq(usdc.balanceOf(custody), 1e6);
        assertEq(registry.reserved(id, address(usdc)), 0);
    }

    // ── sweepUnclaimed recipient allowlist ───────────────────────────────────────

    /// @dev A leaked/malicious OPS key can trigger a sweep, but only to an admin-approved address —
    ///      an arbitrary `to` is refused even though OPS otherwise fully controls sweepUnclaimed.
    function test_sweepUnclaimed_rejectsUnregisteredRecipient() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);
        vm.warp(block.timestamp + 2 * WEEK);

        address stranger = makeAddr("stranger");
        vm.expectRevert(PrivatizationRegistry.NotRegisteredSweepRecipient.selector);
        registry.sweepUnclaimed(id, stranger);
    }

    function test_sweepUnclaimed_acceptsRegisteredRecipient() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);
        vm.warp(block.timestamp + 2 * WEEK);

        registry.sweepUnclaimed(id, custody); // registered in setUp
        assertEq(usdc.balanceOf(custody), 300e6);
    }

    /// @dev Deregistering closes the allowlist entry — a previously-valid destination is refused
    ///      once removed.
    function test_sweepUnclaimed_rejectsAfterDeregistration() public {
        _seed(oldToken, alice, 100 ether);
        uint256 id = registry.createProgram(address(oldToken), _legs3());
        _activateAndFundLegs3(id, oldToken);
        vm.warp(block.timestamp + 2 * WEEK);

        vm.prank(admin);
        registry.deregisterSweepRecipient(custody);

        vm.expectRevert(PrivatizationRegistry.NotRegisteredSweepRecipient.selector);
        registry.sweepUnclaimed(id, custody);
    }

    /// @dev The zero address can never be registered, so it's never a valid sweep destination.
    function test_registerSweepRecipient_rejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PrivatizationRegistry.ZeroAddress.selector);
        registry.registerSweepRecipient(address(0));
    }

    /// @dev The registry itself can never be a sweep destination — sweeping to address(this)
    ///      would zero the reserve accounting and close the program while the tokens never move.
    function test_registerSweepRecipient_rejectsSelf() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PrivatizationRegistry.InvalidSweepRecipient.selector, address(registry)));
        registry.registerSweepRecipient(address(registry));

        address[] memory recipients = new address[](2);
        recipients[0] = makeAddr("fine");
        recipients[1] = address(registry);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PrivatizationRegistry.InvalidSweepRecipient.selector, address(registry)));
        registry.registerSweepRecipients(recipients);
    }

    /// @dev Managing the allowlist is admin-only — OPS cannot self-authorize a sweep destination.
    function test_registerSweepRecipient_onlyAdmin() public {
        vm.expectRevert(); // AccessControlUnauthorizedAccount — this test contract holds OPS, not admin
        registry.registerSweepRecipient(makeAddr("newRecipient"));
    }

    function test_registerSweepRecipients_batch() public {
        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");
        address[] memory recipients = new address[](2);
        recipients[0] = r1;
        recipients[1] = r2;

        vm.prank(admin);
        registry.registerSweepRecipients(recipients);
        assertTrue(registry.isSweepRecipient(r1));
        assertTrue(registry.isSweepRecipient(r2));
    }
}
