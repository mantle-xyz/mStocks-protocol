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
///         "claim = record + settle". 配资 reuses the contract as a record anchor only
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
        reg = WarrantRegistry(
            address(
                new ERC1967Proxy(address(new WarrantRegistry()), abi.encodeCall(WarrantRegistry.initialize, (admin)))
            )
        );
        bytes32 opsRole = reg.OPS_ROLE();
        vm.prank(admin);
        reg.grantRole(opsRole, ops);
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

    function _fund(uint256 id, uint256 amount) internal {
        usd.mint(ops, amount);
        vm.startPrank(ops);
        usd.approve(address(reg), amount);
        reg.fund(id, amount);
        vm.stopPrank();
    }

    /// Creates a program and configures it Active with `root`, `usd` settlement, `settleTotal`,
    /// and a [now, now+window] claim window.
    function _createActiveProgram(bytes32 root, uint256 settleTotal, uint64 window) internal returns (uint256 id) {
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
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();
    }

    // ── warrant: single-step claim = record + settle ────────────────────────────

    function test_claim_recordsAndSettles() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days); // alice 60% -> 300e6, bob 30% -> 150e6
        _fund(id, 500e6);

        assertEq(reg.previewClaim(id, 0.6e18), 300e6);

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        assertEq(reg.warrant(id, alice), 0.6e18, "on-chain queryable warrant amount");
        assertEq(usd.balanceOf(alice), 300e6, "settled in U");
        assertEq(reg.settleReserve(id), 200e6, "reserve drawn down");
        assertTrue(reg.isClaimed(id, 0));
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
        _fund(id, 500e6);
        _blockAlice();

        vm.prank(alice);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    function test_claim_sanctionedAccountReverts() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _fund(id, 500e6);
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
        _fund(id, 500e6);
        _blockAlice();

        // bob is not blocked and is a legitimate claimer of his own leaf.
        vm.prank(bob);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    /// Blocking one account must not close the program for everyone else.
    function test_claim_blockOnOneAccountDoesNotAffectAnother() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _fund(id, 500e6);
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
        _fund(id, 500e6);
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
        _fund(id, 500e6);

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
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();
        _fund(id, 500e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.ComplianceUnavailable.selector, address(plain)));
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    /// Same, for a token whose registry address is zero — what an uninitialized token
    /// proxy looks like from the outside. `compliance()` returns rather than reverts here,
    /// so it is a distinct branch from the case above.
    function test_claim_tokenWithAZeroComplianceRegistryFailsClosed() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _fund(id, 500e6);
        stock.setCompliance(IComplianceRegistry(address(0)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.ComplianceUnavailable.selector, oldStock));
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    /// The bricked state is recoverable, which is what makes failing closed acceptable:
    /// no claim can have succeeded, so `claimStarted` is false and configureProgram can
    /// still repoint `token`.
    function test_claim_aBrickedProgramIsRecoverableByRepointingTheToken() public {
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
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();
        _fund(id, 500e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WarrantRegistry.ComplianceUnavailable.selector, address(plain)));
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());

        // Repoint at a compliance-guarded token. Everything else is left at zero, which
        // configureProgram reads as "keep".
        vm.prank(ops);
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

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(usd.balanceOf(alice), 300e6);
    }

    /// Sanctions are cleared by an epoch bump rather than per-entry deletes, so this
    /// checks the claim path sees the bump.
    function test_claim_clearingSanctionsReopensTheClaim() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _fund(id, 500e6);
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

    function test_claim_notConvertibleYet_thenRetry() public {
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

        // Milestone resolves: OPS sets settlement + total via configureProgram.
        vm.prank(ops);
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
        _fund(id, 300e6);

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice()); // same proof, now settles
        assertEq(reg.warrant(id, alice), 0.6e18);
        assertEq(usd.balanceOf(alice), 300e6);
    }

    function test_claim_insufficientReservedReverts_thenRetry() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days); // alice needs 300e6
        _fund(id, 100e6);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.InsufficientReserved.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertFalse(reg.isClaimed(id, 0));

        _fund(id, 200e6); // top up to 300e6
        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        assertEq(usd.balanceOf(alice), 300e6);
    }

    function test_claim_doubleClaimReverts() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _fund(id, 500e6);

        vm.prank(alice);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.AlreadyClaimed.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    function test_claim_invalidProofReverts() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
        _fund(id, 500e6);

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
                state: uint8(WarrantRegistry.State.Active)
            })
        );
        vm.stopPrank();
        _fund(id, 500e6);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.ClaimNotStarted.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
    }

    function test_claim_afterDeadlineReverts_and_sweep() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 1 days);
        _fund(id, 500e6);

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

    // ── 配资: record anchor only — createProgram + configureProgram, no claim/fund ─────

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

        // No claim path: claiming reverts (not convertible), consistent with 配资 having no claim.
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.claim(id, 0, alice, 0.6e18, _proofAlice());
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

    function test_configureProgram_cannotRegressState() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days); // now Active

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

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.InvalidStateTransition.selector);
        reg.configureProgram(id, _emptyPatch(uint8(WarrantRegistry.State.Active)));
    }

    /// @dev Once {fund} has put a balance behind a program, settlementToken/settleTotal must not
    ///      move — otherwise settleReserve would be denominated in a token that was never actually
    ///      funded in that amount.
    function test_configureProgram_settlementTermsLockedAfterFund() public {
        uint256 id = _createActiveProgram(_root(), 500e6, 7 days);
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
        _fund(id, 1000e6);

        vm.prank(bob);
        reg.claim(id, 1, bob, 0.3e18, _proofBob());
        assertTrue(reg.claimStarted(id), "a successful claim must set claimStarted");

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedAfterClaim.selector);
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
    function test_configureProgram_deadlineCannotBeExtendedAfterAClaim() public {
        uint256 id = _createActiveProgram(_root(), 1000e6, 7 days);
        _fund(id, 1000e6);

        // Before any claim, extending is fine.
        vm.prank(ops);
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

        vm.prank(bob);
        reg.claim(id, 1, bob, 0.3e18, _proofBob());

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ConfigureLockedAfterClaim.selector);
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
        _fund(id, 1000e6);

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
        _fund(id, 100);

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
        _fund(id, 1000e6);
        vm.warp(block.timestamp + 8 days);

        vm.prank(ops);
        vm.expectRevert(WarrantRegistry.ZeroAddress.selector);
        reg.sweepUnclaimed(id, address(0));
    }
}
