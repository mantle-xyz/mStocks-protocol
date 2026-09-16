// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WarrantRegistry} from "../src/privatization/WarrantRegistry.sol";
import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {IComplianceRegistry} from "../src/complianceRegistry/IComplianceRegistry.sol";
import {MockUSD} from "./mocks/MockUSD.sol";
import {MockComplianceGuardedToken, MockUnguardedToken} from "./mocks/MockComplianceGuardedToken.sol";

/// @notice Tests for WarrantRegistry: record-date snapshot + Merkle, single-step
///         "claim = record + settle". Leverage records reuse the contract as a record anchor only
///         (createProgram + configureProgram, never claimed). The whole program lifecycle
///         (create/configure/fund/sweep) is OPS-driven; admin only manages roles.
contract WarrantRegistryTest is Test {
    WarrantRegistry internal reg;
    MockUSD internal usd;
    ComplianceRegistry internal comp;
    MockComplianceGuardedToken internal stock;

    address internal admin = makeAddr("admin");
    address internal ops = makeAddr("ops");
    address internal custody = makeAddr("custody");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");
    /// The program's token. A real one is compliance-guarded, and WarrantRegistry reads
    /// its registry to decide whether an account may be paid, so an EOA here would only
    /// prove the contract works against a token that cannot exist in production.
    address internal oldStock;

    function setUp() public {
        usd = new MockUSD();
        // The real registry, not a mock: these tests are as much about the integration
        // — that UserBlocked and UserSanctioned reach the claimer — as about the branch.
        comp = new ComplianceRegistry(admin);
        // The role is read first: vm.prank applies to the next call, and comp.OPS_ROLE()
        // would otherwise be it.
        bytes32 compOps = comp.OPS_ROLE();
        vm.prank(admin);
        comp.grantRole(compOps, ops);
        stock = new MockComplianceGuardedToken(IComplianceRegistry(address(comp)));
        oldStock = address(stock);
        address[] memory registryOps = new address[](1);
        registryOps[0] = ops;
        reg = WarrantRegistry(
            address(
                new ERC1967Proxy(
                    address(new WarrantRegistry()), abi.encodeCall(WarrantRegistry.initialize, (admin, registryOps))
                )
            )
        );
    }

    // ── merkle helpers: 2-leaf tree over (index, account, amount) ────────────────
    // amount is the account's normalized share (base RATE_SCALE = 1e18).

    function _leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// alice=index0 share 0.6e18 (60%), bob=index1 share 0.3e18 (30%).
    function _root() internal view returns (bytes32) {
        return _hashPair(_leaf(0, alice, 0.6e18), _leaf(1, bob, 0.3e18));
    }

    function _proofAlice() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = _leaf(1, bob, 0.3e18);
    }

    function _proofBob() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = _leaf(0, alice, 0.6e18);
    }

    /// A tree whose amounts sum to 1.3e18 — above RATE_SCALE. Snapshots are meant to sum
    /// to exactly RATE_SCALE; one that sums higher promises more than `settleTotal` can
    /// pay, and it is the only way InsufficientReserved is still reachable now that going
    /// Active requires the reserve to cover settleTotal.
    function _overSumRoot() internal view returns (bytes32) {
        return _hashPair(_leaf(0, alice, 0.8e18), _leaf(1, bob, 0.5e18));
    }

    function _overSumProofAlice() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = _leaf(1, bob, 0.5e18);
    }

    function _overSumProofBob() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = _leaf(0, alice, 0.8e18);
    }

    function _fund(uint256 id, uint256 amount) internal {
        usd.mint(ops, amount);
        vm.startPrank(ops);
        usd.approve(address(reg), amount);
        reg.fund(id, amount);
        vm.stopPrank();
    }

    /// Creates a program, configures `root` / `usd` settlement / `settleTotal` and a
    /// [now, now+window] window, funds it to `settleTotal`, and only then makes it Active.
    ///
    /// The order is the contract's, not a convention: fund() refuses to run before
    /// settleTotal is set, and the Active transition refuses to run before the reserve
    /// covers it. A fixture that went Active first would be testing a state the contract
    /// no longer allows.
    function _createActiveProgram(bytes32 root, uint256 settleTotal, uint64 window) internal returns (uint256 id) {
        id = _createConfiguredProgram(root, settleTotal, window);
        _fund(id, settleTotal);
        vm.prank(ops);
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));
    }

    /// Stops one step short of {_createActiveProgram}: configured and still Created, so a
    /// test can fund it partially, leave it unfunded, or inspect the pre-Active state.
    function _createConfiguredProgram(bytes32 root, uint256 settleTotal, uint64 window) internal returns (uint256 id) {
        vm.startPrank(ops);
        id = reg.createProgram(oldStock, address(usd));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: root,
                settlementToken: address(0),
                settleTotal: settleTotal,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + window,
                state: 0 // stay Created until funded
            })
        );
        vm.stopPrank();
    }

    function _state(uint256 id) internal view returns (WarrantRegistry.State) {
        (,,,,,, uint8 st) = reg.programs(id);
        return WarrantRegistry.State(st);
    }

    /// A patch that changes only `state`; every zero field is read as "keep".
    function _patch(WarrantRegistry.State state) internal pure returns (WarrantRegistry.Program memory) {
        return WarrantRegistry.Program({
            token: address(0),
            merkleRoot: bytes32(0),
            settlementToken: address(0),
            settleTotal: 0,
            startTime: 0,
            deadline: 0,
            state: uint8(state)
        });
    }

    // ── warrant: single-step claim = record + settle ────────────────────────────

    function test_claim_recordsAndSettles() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days); // alice 60% -> 300e6, bob 30% -> 150e6

        assertEq(reg.previewClaim(id, 0.6e18), 300e6);

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        assertEq(reg.warrant(id, alice), 0.6e18, "on-chain queryable warrant amount");
        assertEq(usd.balanceOf(alice), 300e6, "settled in U");
        assertEq(reg.settleReserve(id), 200e6, "reserve drawn down");
        assertTrue(reg.isClaimed(id, 0));
    }

    // ── ordering: configure → fund → Active ──────────────────────────────────────
    // The sequence is enforced rather than documented, because both ways of getting it
    // wrong are silent: they produce a program that looks configured, holds money, and
    // pays nobody.

    /// createProgram already sets settlementToken, so fund() would otherwise succeed
    /// straight after creating — and funding locks the settlement terms, leaving
    /// settleTotal at zero permanently.
    function test_fund_beforeSettleTotalIsSetReverts() public {
        vm.prank(ops);
        uint256 id = reg.createProgram(oldStock, address(usd));

        usd.mint(ops, 500e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 500e6);
        vm.expectRevert(WarrantRegistry.SettleTotalNotSet.selector);
        reg.fund(id, 500e6);
        vm.stopPrank();

        assertEq(reg.settleReserve(id), 0, "nothing was taken");
    }

    /// The state this prevents, spelled out: without the guard above, the terms lock would
    /// close over settleTotal == 0 and every claim would revert NothingToSettle forever.
    /// Kept as a named test because "funded but unpayable" is not obvious from the code.
    function test_fund_beforeConfigureWouldStrandTheProgram() public {
        vm.prank(ops);
        uint256 id = reg.createProgram(oldStock, address(usd));

        // Had fund() been allowed here, settleReserve would be non-zero with settleTotal
        // still zero, and this patch — the only way to set it — would be refused.
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.SettleTotalNotSet.selector);
        reg.fund(id, 1);

        // Because it was refused, the terms are still settable and the program is fine.
        uint256 funded = _createConfiguredProgram(_root(), 500e6, 7 days);
        _fund(funded, 500e6);
        vm.prank(ops);
        reg.configureProgram(funded, _patch(WarrantRegistry.State.Active));
        assertEq(uint8(_state(funded)), uint8(WarrantRegistry.State.Active));
        assertEq(id, 0);
    }

    /// Funding is a Created-state action. Active asserts that the reserve covers what the
    /// program owes, and that assertion would mean nothing if the reserve could still move
    /// — including upward, since a later top-up implies the assertion was wrong when made.
    function test_fund_lockedOnceActive() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);

        usd.mint(ops, 1e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 1e6);
        vm.expectRevert(WarrantRegistry.FundLockedOnceActive.selector);
        reg.fund(id, 1e6);
        vm.stopPrank();
        assertEq(reg.settleReserve(id), 500e6, "unchanged");
    }

    /// And after sweeping, which the same condition covers.
    function test_fund_lockedOnceClosed() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(ops);
        reg.sweepUnclaimed(id, custody);

        usd.mint(ops, 1e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 1e6);
        vm.expectRevert(WarrantRegistry.FundLockedOnceActive.selector);
        reg.fund(id, 1e6);
        vm.stopPrank();
    }

    /// Active means claimable, so it has to mean funded. Otherwise holders discover the
    /// shortfall as InsufficientReserved and cannot tell it from a bug.
    function test_configureProgram_activeRequiresFullFunding() public {
        uint256 id = _createConfiguredProgram(_root(), 500e6, 7 days);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.NotFullyFunded.selector, 0, 500e6));
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));

        // Partial funding is still not enough — the bound is settleTotal, not "non-zero".
        _fund(id, 499e6);
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.NotFullyFunded.selector, 499e6, 500e6));
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));

        _fund(id, 1e6);
        vm.prank(ops);
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));
        assertEq(uint8(_state(id)), uint8(WarrantRegistry.State.Active));
    }

    /// Over-funding is allowed: a tree summing above RATE_SCALE needs proportionally more
    /// than settleTotal, and this contract cannot know the sum, so the check is a floor.
    function test_configureProgram_activeAcceptsOverFunding() public {
        uint256 id = _createConfiguredProgram(_root(), 500e6, 7 days);
        _fund(id, 650e6);
        vm.prank(ops);
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));
        assertEq(uint8(_state(id)), uint8(WarrantRegistry.State.Active));
    }

    /// Leverage records never settle and never fund, so the funding requirement must not
    /// apply to them — settleTotal == 0 is the marker.
    function test_configureProgram_recordOnlyProgramGoesActiveUnfunded() public {
        vm.startPrank(ops);
        uint256 id = reg.createProgram(oldStock, address(0));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root(),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + 7 days,
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();
        assertEq(uint8(_state(id)), uint8(WarrantRegistry.State.Active));
        assertEq(reg.settleReserve(id), 0);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    /// The gap the funding check could not cover on its own: a record-only program is
    /// already Active, so adding settlement terms to it would not re-enter the state
    /// transition and the funding check would not run — leaving it Active, convertible and
    /// unfunded. The configure lock closes that, because Active refuses the patch outright.
    function test_configureProgram_cannotAddSettlementTermsToAnActiveRecordOnlyProgram() public {
        vm.startPrank(ops);
        uint256 id = reg.createProgram(oldStock, address(0));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root(),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + 7 days,
                state: uint8(WarrantRegistry.State.Active)
            })
        );

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
        vm.stopPrank();

        (,, address settlementToken, uint256 settleTotal,,,) = reg.programs(id);
        assertEq(settlementToken, address(0), "still record-only");
        assertEq(settleTotal, 0);
        assertEq(reg.settleReserve(id), 0);
    }

    // ── compliance ───────────────────────────────────────────────────────────────
    // A warrant is an entitlement derived from holding the security, so it has to honour
    // the same blocklist the security does. The registry is read off the program's token
    // rather than configured on this contract, so there is no second address that can
    // drift out of step with the one the token enforces.

    function _blockAlice() internal {
        address[] memory who = new address[](1);
        who[0] = alice;
        vm.prank(ops);
        comp.blockUsers(oldStock, who);
    }

    function _sanctionAlice() internal {
        address[] memory who = new address[](1);
        who[0] = alice;
        vm.prank(ops);
        comp.sanctionUsers(who);
    }

    /// Token-level block: the reason has to reach the caller, not be flattened into a
    /// generic failure, because "blocked for this token" and "globally sanctioned" are
    /// resolved by different desks.
    function test_claim_blockedAccountReverts() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _blockAlice();

        vm.prank(alice);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    function test_claim_sanctionedAccountReverts() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _sanctionAlice();

        vm.prank(alice);
        vm.expectRevert(ComplianceRegistry.UserSanctioned.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    /// The check is on `account`, not the caller. claim() accepts a proof on anyone's
    /// behalf and pays `account`, so checking the caller would let a clean relayer collect
    /// for a blocked one — which is the whole of the bypass.
    function test_claim_blockedAccountCannotBeClaimedForByACleanRelayer() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _blockAlice();

        // bob is not blocked and is a legitimate claimer of his own leaf.
        vm.prank(bob);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    /// Blocking one account must not close the program for everyone else.
    function test_claim_blockOnOneAccountDoesNotAffectAnother() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _blockAlice();

        vm.prank(bob);
        reg.claim(id, 1, bob, 0.3e18, _proofBob());
        assertEq(usd.balanceOf(bob), 150e6);
    }

    /// A block is a hold, not a forfeiture: the rejected claim must leave its index
    /// unconsumed so the same leaf still settles once compliance clears. If the revert
    /// landed after `_claimed.set`, the entitlement would be destroyed by a hold.
    function test_claim_blockedThenUnblockedStillSettles() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _blockAlice();

        vm.prank(alice);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        assertFalse(reg.isClaimed(id, 0), "a rejected claim must not consume the index");
        assertEq(reg.warrant(id, alice), 0, "nothing recorded");
        assertEq(reg.settleReserve(id), 500e6, "reserve untouched");
        assertFalse(reg.claimStarted(id), "a rejected claim must not lock configureProgram");

        address[] memory who = new address[](1);
        who[0] = alice;
        vm.prank(ops);
        comp.unblockUsers(oldStock, who);

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(usd.balanceOf(alice), 300e6);
        assertTrue(reg.isClaimed(id, 0));
    }

    /// A block scoped to a different token must not reach this program. The registry is
    /// keyed (token, user), and passing the wrong token here would either block accounts
    /// that are clear or clear accounts that are blocked.
    function test_claim_blockOnADifferentTokenDoesNotApply() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);

        address[] memory who = new address[](1);
        who[0] = alice;
        vm.prank(ops);
        comp.blockUsers(address(usd), who); // blocked for the settlement asset, not the stock

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(usd.balanceOf(alice), 300e6);
    }

    /// Fails closed. A token with no registry means the account's standing is unknown, and
    /// paying out a security's entitlement to an account that cannot be checked is the
    /// case this guard exists to prevent.
    function test_claim_tokenWithoutAComplianceRegistryFailsClosed() public {
        MockUnguardedToken plain = new MockUnguardedToken();

        vm.startPrank(ops);
        uint256 id = reg.createProgram(address(plain), address(usd));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root(),
                settlementToken: address(0),
                settleTotal: 500e6,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp + 7 days),
                state: 0 // Created until funded
            })
        );
        vm.stopPrank();
        _fund(id, 500e6);
        vm.prank(ops);
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.ComplianceUnavailable.selector, address(plain)));
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    /// Same, for a token whose registry address is zero — what an uninitialized token
    /// proxy looks like from the outside. `compliance()` returns rather than reverts here,
    /// so it is a distinct branch from the case above.
    function test_claim_tokenWithAZeroComplianceRegistryFailsClosed() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        stock.setCompliance(IComplianceRegistry(address(0)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.ComplianceUnavailable.selector, oldStock));
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    /// Failing closed on an unreadable registry can strand a program: once Active the
    /// token cannot be repointed, so no claim will ever succeed. The money is still
    /// recoverable — sweepUnclaimed after the deadline — but the program is not, which is
    /// the price of having the terms a holder sees be the terms the program opened with.
    ///
    /// The mitigation is that this is discoverable before opening: the token is set at
    /// createProgram, and the whole Created state exists to check things like this.
    function test_claim_strandedByAnUnreadableRegistry_fundsRecoverBySweep() public {
        MockUnguardedToken plain = new MockUnguardedToken();

        vm.startPrank(ops);
        uint256 id = reg.createProgram(address(plain), address(usd));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root(),
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
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.ComplianceUnavailable.selector, address(plain)));
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        // Repointing the token is no longer available.
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: oldStock,
                merkleRoot: bytes32(0),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: 0,
                deadline: 0,
                state: 0
            })
        );

        // The reserve is not lost, only delayed to the deadline.
        vm.warp(block.timestamp + 8 days);
        vm.prank(ops);
        reg.sweepUnclaimed(id, custody);
        assertEq(usd.balanceOf(custody), 500e6);
        assertEq(reg.settleReserve(id), 0);
    }

    /// Sanctions are cleared by an epoch bump rather than per-entry deletes, so this
    /// checks the claim path sees the bump.
    function test_claim_clearingSanctionsReopensTheClaim() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _sanctionAlice();

        vm.prank(alice);
        vm.expectRevert(ComplianceRegistry.UserSanctioned.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        vm.prank(ops);
        comp.clearSanctions();

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(usd.balanceOf(alice), 300e6);
    }

    // ── not-convertible-yet → revert → configure + fund → retry succeeds ────────

    function test_claim_notConvertibleYet_needsASecondProgram() public {
        vm.startPrank(ops);
        uint256 id = reg.createProgram(oldStock, address(0)); // settlementToken unset
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root(),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + 30 days,
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertFalse(reg.isClaimed(id, 0), "index not consumed on failed claim");

        // Milestone resolves — but the terms can no longer be added in place. Turning a
        // record-only anchor into a payable program is a new program now, because the
        // configure lock closes at Active and this one is already Active.
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

        // So it stays record-only, and the claim keeps failing the same way.
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertFalse(reg.isClaimed(id, 0));

        // The route is a second program over the same root. The record anchor stays where
        // it is, and the payable program is configured, funded and opened in the normal
        // order — which is the point of the lock: the terms a holder sees are the terms
        // the program opened with.
        uint256 payable_ = _createActiveProgram(_root(), 500e6, 30 days);
        vm.prank(alice);
        reg.claim(payable_, 0, alice, 0.6e18, _proofAlice());
        assertEq(reg.warrant(payable_, alice), 0.6e18);
        assertEq(usd.balanceOf(alice), 300e6);
        assertEq(reg.warrant(id, alice), 0, "the record-only program recorded nothing");
    }

    /// InsufficientReserved means one specific thing: the tree's amounts sum above
    /// RATE_SCALE, so the program owes more than `settleTotal`. Opening requires the reserve
    /// to cover settleTotal, which is exact for a tree summing to RATE_SCALE — under-funding
    /// cannot produce this, and a caller who sees it should look at the snapshot.
    ///
    /// And it is unrecoverable, which is the point of funding being a Created-state action:
    /// Active asserts "the reserve covers what this program owes", and that assertion would
    /// mean nothing if the reserve could still move. So the reconciliation has to happen
    /// before opening. Nothing on chain can do it — the sum is not visible to the contract.
    function test_claim_treeSummingAboveRateScaleStrandsTheLastClaimant() public {
        uint256 id = _createActiveProgram(_overSumRoot(), 500e6, 7 days);
        assertEq(reg.settleReserve(id), 500e6, "Active implies the reserve covers settleTotal");
        assertEq(reg.previewClaim(id, 0.8e18), 400e6);
        assertEq(reg.previewClaim(id, 0.5e18), 250e6); // 400 + 250 = 650e6 > 500e6

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.8e18, _overSumProofAlice());
        assertEq(reg.settleReserve(id), 100e6);

        vm.prank(bob);
        vm.expectRevert(WarrantRegistry.InsufficientReserved.selector);
        reg.claim(id, 1, bob, 0.5e18, _overSumProofBob());
        assertFalse(reg.isClaimed(id, 1), "a rejected claim must not consume the index");

        // No topping up: the program is Active.
        usd.mint(ops, 150e6);
        vm.startPrank(ops);
        usd.approve(address(reg), 150e6);
        vm.expectRevert(WarrantRegistry.FundLockedOnceActive.selector);
        reg.fund(id, 150e6);
        vm.stopPrank();

        // bob's entitlement is stuck until the deadline; the reserve is not lost.
        vm.warp(block.timestamp + 8 days);
        vm.prank(ops);
        reg.sweepUnclaimed(id, custody);
        assertEq(usd.balanceOf(custody), 100e6);
        assertEq(usd.balanceOf(bob), 0, "never paid");
    }

    /// The same tree, reconciled before opening: fund what the leaves actually sum to rather
    /// than what settleTotal says, and both claims settle. This is the check that has to
    /// happen while the program is Created — Σ previewClaim over the leaves against
    /// settleReserve.
    function test_fund_reconcilingBeforeOpeningPaysEveryone() public {
        uint256 id = _createConfiguredProgram(_overSumRoot(), 500e6, 7 days);

        // 0.8e18 + 0.5e18 = 1.3e18 of RATE_SCALE, so the program owes 1.3 * settleTotal.
        assertEq(reg.previewClaim(id, 0.8e18) + reg.previewClaim(id, 0.5e18), 650e6);
        _fund(id, 650e6);
        vm.prank(ops);
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.8e18, _overSumProofAlice());
        vm.prank(bob);
        reg.claim(id, 1, bob, 0.5e18, _overSumProofBob());
        assertEq(usd.balanceOf(alice), 400e6);
        assertEq(usd.balanceOf(bob), 250e6);
        assertEq(reg.settleReserve(id), 0, "exactly consumed");
    }

    function test_claim_doubleClaimReverts() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.AlreadyClaimed.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    function test_claim_invalidProofReverts() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.InvalidProof.selector);
        reg.claim(id, 0, alice, 0.9e18, _proofAlice());
    }

    function test_claim_beforeStartTimeReverts() public {
        vm.startPrank(ops);
        uint256 id = reg.createProgram(oldStock, address(usd));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root(),
                settlementToken: address(0),
                settleTotal: 500e6,
                startTime: uint64(block.timestamp) + 1 days,
                deadline: uint64(block.timestamp) + 7 days,
                state: 0 // Created until funded
            })
        );
        vm.stopPrank();
        _fund(id, 500e6);
        vm.prank(ops);
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.ClaimNotStarted.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    function test_claim_afterDeadlineReverts_and_sweep() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 1 days);

        // alice claims within window; bob never does.
        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(reg.settleReserve(id), 200e6);

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ClaimStillOpen.selector);
        reg.sweepUnclaimed(id, custody);

        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        vm.expectRevert(WarrantRegistry.ClaimClosed.selector);
        reg.claim(id, 1, bob, 0.3e18, _proofBob());

        vm.prank(ops);
        reg.sweepUnclaimed(id, custody);
        assertEq(usd.balanceOf(custody), 200e6, "bob's unclaimed share swept");
        assertEq(reg.settleReserve(id), 0);
    }

    // ── leverage: record anchor only — createProgram + configureProgram, no claim/fund ─────

    function test_leverage_recordAnchorOnly() public {
        vm.startPrank(ops);
        uint256 id = reg.createProgram(oldStock, address(0));
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root(),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: uint64(block.timestamp),
                deadline: uint64(block.timestamp) + 1 days,
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();

        (, bytes32 root, address settlementToken,,,,) = reg.programs(id);
        assertEq(root, _root(), "credit-line root anchored on-chain");
        assertEq(settlementToken, address(0), "no settlement - record only");
        assertEq(reg.warrant(id, alice), 0, "nobody claims leverage record");

        // No claim path: claiming reverts (not convertible), consistent with leverage having no claim.
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    function test_configureProgram_activationRejectsEmptyRootAfterFunding() public {
        uint256 id = _createConfiguredProgram(bytes32(0), 500e6, 7 days);
        _fund(id, 500e6);
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.MerkleRootNotSet.selector);
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));
        assertEq(uint8(_state(id)), uint8(WarrantRegistry.State.Created));
        assertEq(reg.settleReserve(id), 500e6);
    }

    function test_configureProgram_recordOnlyActivationAlsoRequiresRoot() public {
        vm.startPrank(ops);
        uint256 id = reg.createProgram(oldStock, address(0));
        WarrantRegistry.Program memory patch = _patch(WarrantRegistry.State.Active);
        patch.deadline = uint64(block.timestamp + 7 days);
        vm.expectRevert(WarrantRegistry.MerkleRootNotSet.selector);
        reg.configureProgram(id, patch);
        patch.merkleRoot = _root();
        reg.configureProgram(id, patch);
        vm.stopPrank();
        assertEq(uint8(_state(id)), uint8(WarrantRegistry.State.Active));
    }

    function test_configureProgram_acceptsRootInActivationPatch() public {
        uint256 id = _createConfiguredProgram(bytes32(0), 500e6, 7 days);
        _fund(id, 500e6);
        WarrantRegistry.Program memory patch = _patch(WarrantRegistry.State.Active);
        patch.merkleRoot = _root();
        vm.prank(ops);
        reg.configureProgram(id, patch);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(usd.balanceOf(alice), 300e6);
    }

    function test_configureProgram_fundedRootRemainsCorrectableUntilActive() public {
        uint256 id = _createConfiguredProgram(_root(), 500e6, 7 days);
        _fund(id, 500e6);
        bytes32 correctedRoot = _hashPair(_leaf(0, alice, 0.4e18), _leaf(1, bob, 0.6e18));
        WarrantRegistry.Program memory patch = _patch(WarrantRegistry.State.None);
        patch.merkleRoot = correctedRoot;
        vm.startPrank(ops);
        reg.configureProgram(id, patch);
        reg.configureProgram(id, _patch(WarrantRegistry.State.Active));
        patch.merkleRoot = _root();
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(id, patch);
        vm.stopPrank();

        vm.expectRevert(WarrantRegistry.InvalidProof.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(1, bob, 0.6e18);
        reg.claim(id, 0, alice, 0.4e18, proof);
        assertEq(usd.balanceOf(alice), 200e6);
    }

    // ── state-machine guards ─────────────────────────────────────────────────────

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

    /// The configure lock now fires before the state machine does, so an Active program
    /// refuses the patch outright rather than reaching the transition check.
    function test_configureProgram_cannotRegressState() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days); // now Active

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Created)));
    }

    /// The transition check is still reachable, but only inside Created — the one state
    /// where configuring is allowed. Created -> Created is not forward progress.
    function test_configureProgram_cannotRestateCreatedAsCreated() public {
        vm.prank(ops);
        uint256 id = reg.createProgram(oldStock, address(usd));

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.InvalidStateTransition.selector);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Created)));
    }

    function test_configureProgram_cannotJumpToClosed() public {
        vm.prank(ops);
        uint256 id = reg.createProgram(oldStock, address(usd)); // Created

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.InvalidStateTransition.selector);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Closed)));
    }

    function test_configureProgram_cannotReopenClosedProgram() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(ops);
        reg.sweepUnclaimed(id, custody); // now Closed

        // Closed is not Created either, so the lock covers it — which also settles the
        // question of whether a swept program's root could still be rewritten. It cannot.
        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));
    }

    /// @dev Once {fund} has put a balance behind a program, settlementToken/settleTotal must not
    ///      move — otherwise settleReserve would be denominated in a token that was never actually
    ///      funded in that amount.
    /// Kept on a still-Created program: once Active, configureProgram refuses everything,
    /// so this lock is only observable in the window where configuring is still allowed —
    /// configure terms, fund, then try to move them.
    function test_configureProgram_settlementTermsLockedAfterFund() public {
        uint256 id = _createConfiguredProgram(_root(), 500e6, 7 days);
        _fund(id, 100e6); // any non-zero reserve locks the terms

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

        // other fields (e.g. deadline) remain freely adjustable after funding
        vm.prank(ops);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: bytes32(0),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: 0,
                deadline: uint64(block.timestamp) + 30 days,
                state: 0
            })
        );
        (,,,,, uint64 deadline,) = reg.programs(id);
        assertEq(deadline, uint64(block.timestamp) + 30 days);
    }

    // ── role guards ──────────────────────────────────────────────────────────────

    function test_createProgram_onlyOps() public {
        vm.prank(admin); // admin holds DEFAULT_ADMIN_ROLE, not OPS_ROLE
        vm.expectRevert();
        reg.createProgram(oldStock, address(usd));
    }

    function test_configureProgram_onlyOps() public {
        vm.prank(ops);
        uint256 id = reg.createProgram(oldStock, address(usd));

        vm.prank(admin);
        vm.expectRevert();
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: _root(),
                settlementToken: address(0),
                settleTotal: 0,
                startTime: 0,
                deadline: 0,
                state: uint8(WarrantRegistry.State.Active)
            })
        );
    }

    function test_fund_onlyOps() public {
        vm.prank(ops);
        uint256 id = reg.createProgram(oldStock, address(usd));
        vm.prank(admin);
        vm.expectRevert();
        reg.fund(id, 1e6);
    }

    function test_sweepUnclaimed_onlyOps() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 1 days);
        vm.warp(block.timestamp + 2 days);

        vm.prank(admin);
        vm.expectRevert();
        reg.sweepUnclaimed(id, custody);
    }

    function test_selfGrantReverts() public {
        bytes32 opsRole = reg.OPS_ROLE();
        vm.prank(admin);
        vm.expectRevert(WarrantRegistry.SelfGrantNotAllowed.selector);
        reg.grantRole(opsRole, admin);
    }

    function test_lastAdminCannotRenounce() public {
        vm.prank(admin);
        vm.expectRevert(WarrantRegistry.CannotRenounceLastAdmin.selector);
        reg.renounceRole(0x00, admin);
    }

    /// @dev revokeRole is a second path to the same self-removal renounceRole is guarded against
    ///      (an admin can revoke its own role just as well as renounce it) — needs the same guard.
    function test_lastAdminCannotBeRevoked() public {
        vm.prank(admin);
        vm.expectRevert(WarrantRegistry.CannotRenounceLastAdmin.selector);
        reg.revokeRole(0x00, admin);
    }

    // ── configureProgram is frozen once anyone has claimed ──────────────────────

    /// @dev The hole this closes: `merkleRoot` had no lock. OPS could swap the whole holder set
    ///      after the program was funded AND after holders had begun claiming — redirecting
    ///      committed funds to an address absent from the original root, while `state` stayed
    ///      `Active` and nothing on chain marked that it had happened. {PrivatizationRegistry}
    ///      guarded the same thing with `claimStarted`; this contract did not.
    function test_configureProgram_rootCannotBeSwappedAfterAClaim() public {
        // Tree B puts mallory at alice's index 0 with alice's share.
        bytes32 rootB = _hashPair(_leaf(0, mallory, 0.6e18), _leaf(1, bob, 0.3e18));

        uint256 id = _createActiveProgram(_root(), 1000e6, 7 days);

        vm.prank(bob);
        reg.claim(id, 1, bob, 0.3e18, _proofBob());
        assertTrue(reg.claimStarted(id), "a successful claim must set claimStarted");

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedOnceActive.selector);
        reg.configureProgram(
            id,
            WarrantRegistry.Program({
                token: address(0),
                merkleRoot: rootB,
                settlementToken: address(0),
                settleTotal: 0,
                startTime: 0,
                deadline: 0,
                state: 0
            })
        );

        (, bytes32 storedRoot,,,,,) = reg.programs(id);
        assertEq(storedRoot, _root(), "root must still be the one holders were told about");

        // And alice, entitled under the original root, can still claim.
        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(usd.balanceOf(alice), 600e6);
    }

    /// @dev The lock is whole-patch, so it also blocks extending the deadline once claiming has
    ///      started. Documented as a test because it is a real operational limit, not an accident:
    ///      a window that has to move after the first claim needs a new program.
    /// The claim window is fixed at the moment the program opens, in both directions.
    ///
    /// Extending is harmless to holders and shortening is not — shortening plus
    /// {sweepUnclaimed} takes the reserve back before anyone can claim — but the lock does
    /// not distinguish them. That is the deliberate cost of having one condition: an
    /// exception for "extend only" is another branch to get wrong, and a window set
    /// generously at the start needs no exception.
    function test_configureProgram_deadlineIsFixedOnceActive() public {
        uint256 id = _createActiveProgram(_root(), 1000e6, 7 days);

        // Extending: refused, even though it could only help holders.
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
                deadline: uint64(block.timestamp + 30 days),
                state: 0
            })
        );

        // Shortening: refused. This is the one that mattered — it was the setup for
        // sweeping the reserve out from under holders who had not claimed yet.
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
                deadline: uint64(block.timestamp + 1),
                state: 0
            })
        );

        // And the window still works as configured.
        vm.prank(bob);
        reg.claim(id, 1, bob, 0.3e18, _proofBob());

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
    }

    // ── gaps closed from the self-test doc ─────────────────────────────────────

    /// @dev A program that exists but was never configured has no root and no window, so it must
    ///      not be claimable. Guards against `Created` being mistaken for claimable.
    function test_claim_beforeConfigureReverts() public {
        vm.prank(ops);
        uint256 id = reg.createProgram(oldStock, address(usd));

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotActive.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    /// @dev Anyone may submit a valid proof on an account's behalf; both the payout and the
    ///      on-chain record must accrue to `account`, never to the submitter. The contract's own
    ///      doc comment promises this, so it needs a test.
    function test_claim_onBehalfOfAnotherAccount() public {
        uint256 id = _createActiveProgram(_root(), 1000e6, 7 days);

        address relayer = makeAddr("relayer");
        vm.prank(relayer);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        assertEq(usd.balanceOf(alice), 600e6, "payout goes to the account, not the submitter");
        assertEq(usd.balanceOf(relayer), 0, "submitter receives nothing");
        assertEq(reg.warrant(id, alice), 0.6e18, "record accrues to the account");
        assertEq(reg.warrant(id, relayer), 0);
    }

    /// @dev A share so small that `amount * settleTotal / RATE_SCALE` floors to zero must revert
    ///      rather than consume the index for nothing. Reachable in production: shares are
    ///      normalized to RATE_SCALE, so a holder with a tiny fraction of the supply can round to
    ///      zero against a small settleTotal.
    function test_claim_dustShareRoundingToZeroReverts() public {
        // alice's share is 1 wei of RATE_SCALE; with settleTotal 100 the payout floors to 0.
        bytes32 root = _hashPair(_leaf(0, alice, 1), _leaf(1, bob, 0.3e18));
        uint256 id = _createActiveProgram(root, 100, 7 days);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(1, bob, 0.3e18);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NothingToSettle.selector);
        reg.claim(id, 0, alice, 1, proof);

        assertFalse(reg.isClaimed(id, 0), "a reverted claim must not consume the index");
        assertFalse(reg.claimStarted(id), "a reverted claim must not freeze configureProgram");
    }

    /// @dev sweepUnclaimed must reject the zero address — the reserve would otherwise be burned.
    function test_sweepUnclaimed_rejectsZeroAddress() public {
        uint256 id = _createActiveProgram(_root(), 1000e6, 7 days);
        vm.warp(block.timestamp + 8 days);

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ZeroAddress.selector);
        reg.sweepUnclaimed(id, address(0));
    }
}
