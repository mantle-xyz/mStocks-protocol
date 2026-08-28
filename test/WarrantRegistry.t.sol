// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WarrantRegistry} from "../src/privatization/WarrantRegistry.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

/// @notice Tests for WarrantRegistry: record-date snapshot + Merkle, single-step
///         "claim = record + settle". 配资 reuses the contract as a record anchor only
///         (createProgram + configureProgram, never claimed). The whole program lifecycle
///         (create/configure/fund/sweep) is OPS-driven; admin only manages roles.
contract WarrantRegistryTest is Test {
    WarrantRegistry internal reg;
    MockUSD internal usd;

    address internal admin = makeAddr("admin");
    address internal ops = makeAddr("ops");
    address internal custody = makeAddr("custody");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal oldStock = makeAddr("oldStock");

    function setUp() public {
        usd = new MockUSD();
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
}
