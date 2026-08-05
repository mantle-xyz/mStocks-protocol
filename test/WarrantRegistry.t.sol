// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WarrantRegistry} from "../src/privatization/WarrantRegistry.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

/// @notice Tests for WarrantRegistry: snapshot + Merkle, single-step "claim = record + settle".
///         配资 reuses the contract as a record anchor only (createProgram, never claimed).
contract WarrantRegistryTest is Test {
    WarrantRegistry internal reg;
    MockUSD internal usd;

    address internal admin = makeAddr("admin");
    address internal ops = makeAddr("ops");
    address internal custody = makeAddr("custody");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usd = new MockUSD();
        reg = new WarrantRegistry(admin);
        bytes32 opsRole = reg.OPS_ROLE();
        vm.prank(admin);
        reg.grantRole(opsRole, ops);
    }

    // ── merkle helpers: 2-leaf tree over (index, account, amount) ────────────────

    function _leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// alice=index0 amount 100, bob=index1 amount 50.
    function _root() internal view returns (bytes32) {
        return _hashPair(_leaf(0, alice, 100 ether), _leaf(1, bob, 50 ether));
    }

    function _proofAlice() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = _leaf(1, bob, 50 ether);
    }

    function _fund(uint256 id, uint256 amount) internal {
        usd.mint(ops, amount);
        vm.startPrank(ops);
        usd.approve(address(reg), amount);
        reg.fund(id, amount);
        vm.stopPrank();
    }

    // ── warrant: single-step claim = record + settle ────────────────────────────

    function test_claim_recordsAndSettles() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), address(usd), 2e6, uint64(block.timestamp + 7 days)); // 2 USD / warrant
        _fund(id, 300e6);

        assertEq(reg.previewClaim(id, 100 ether), 200e6);

        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());

        assertEq(reg.warrant(id, alice), 100 ether, "on-chain queryable warrant amount");
        assertEq(usd.balanceOf(alice), 200e6, "settled in U");
        assertEq(reg.settleReserve(id), 100e6, "reserve drawn down");
        assertTrue(reg.isClaimed(id, 0));
    }

    // ── not-convertible-yet → revert → configure + fund → retry succeeds ────────

    function test_claim_notConvertibleYet_thenRetry() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), address(0), 0, uint64(block.timestamp + 30 days)); // settlement unknown

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
        assertFalse(reg.isClaimed(id, 0), "index not consumed on failed claim");

        // Milestone resolves.
        vm.prank(admin);
        reg.configureSettlement(id, address(usd), 2e6);
        _fund(id, 200e6);

        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice()); // same proof, now settles
        assertEq(reg.warrant(id, alice), 100 ether);
        assertEq(usd.balanceOf(alice), 200e6);
    }

    function test_claim_insufficientReservedReverts_thenRetry() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), address(usd), 2e6, uint64(block.timestamp + 7 days));
        _fund(id, 100e6); // alice needs 200e6

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.InsufficientReserved.selector);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
        assertFalse(reg.isClaimed(id, 0));

        _fund(id, 100e6); // top up
        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
        assertEq(usd.balanceOf(alice), 200e6);
    }

    function test_claim_doubleClaimReverts() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), address(usd), 2e6, uint64(block.timestamp + 7 days));
        _fund(id, 300e6);

        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.AlreadyClaimed.selector);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
    }

    function test_claim_invalidProofReverts() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), address(usd), 2e6, uint64(block.timestamp + 7 days));
        _fund(id, 300e6);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.InvalidProof.selector);
        reg.claim(id, 0, alice, 999 ether, _proofAlice());
    }

    function test_claim_afterDeadlineReverts_and_sweep() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), address(usd), 2e6, uint64(block.timestamp + 1 days));
        _fund(id, 300e6);

        // alice claims within window; bob never does.
        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
        assertEq(reg.settleReserve(id), 100e6);

        vm.prank(admin);
        vm.expectRevert(WarrantRegistry.ClaimStillOpen.selector);
        reg.sweepUnclaimed(id, custody);

        vm.warp(block.timestamp + 2 days);
        bytes32[] memory proofBob = new bytes32[](1);
        proofBob[0] = _leaf(0, alice, 100 ether);
        vm.prank(bob);
        vm.expectRevert(WarrantRegistry.ClaimClosed.selector);
        reg.claim(id, 1, bob, 50 ether, proofBob);

        vm.prank(admin);
        reg.sweepUnclaimed(id, custody);
        assertEq(usd.balanceOf(custody), 100e6, "bob's unclaimed share swept");
        assertEq(reg.settleReserve(id), 0);
    }

    // ── 配资: record anchor only — createProgram, no claim/fund ──────────────────

    function test_leverage_recordAnchorOnly() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), address(0), 0, uint64(block.timestamp + 1 days)); // settlementToken 0

        (bytes32 root, address settlementToken,,,) = reg.programs(id);
        assertEq(root, _root(), "credit-line root anchored on-chain");
        assertEq(settlementToken, address(0), "no settlement - record only");
        assertEq(reg.warrant(id, alice), 0, "nobody claims leverage record");

        // No claim path: claiming reverts (not convertible), consistent with 配资 having no claim.
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.NotConvertibleYet.selector);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
    }
}
