// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WarrantRegistry} from "../src/privatization/WarrantRegistry.sol";
import {MockUSD} from "./mocks/MockUSD.sol";

/// @notice Tests for WarrantRegistry: snapshot + Merkle "record + settle", program-ified, with a
///         deferredSettlement flag distinguishing a general warrant from 配资.
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

    // ── general warrant: immediate settlement at claim ──────────────────────────

    function test_warrant_immediateSettleAtClaim() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), uint64(block.timestamp + 7 days), true, address(usd), 2e6); // 2 USD / warrant
        _fund(id, 300e6);

        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());

        assertEq(reg.recorded(id, alice), 100 ether, "recorded");
        assertEq(reg.settled(id, alice), 100 ether, "settled immediately");
        assertEq(usd.balanceOf(alice), 200e6, "paid 100*2 USD");
        assertEq(reg.settleReserve(id), 100e6, "reserve drawn down");
    }

    // ── general warrant: deferred — record now, settle later ────────────────────

    function test_warrant_deferredThenSettle() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), uint64(block.timestamp + 30 days), true, address(0), 0); // not convertible yet

        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
        assertEq(reg.recorded(id, alice), 100 ether);
        assertEq(reg.settled(id, alice), 0, "only recorded");
        assertEq(usd.balanceOf(alice), 0);

        // Milestone resolves: configure + fund, then holder settles.
        vm.prank(admin);
        reg.configureSettlement(id, address(usd), 2e6);
        _fund(id, 200e6);

        vm.prank(alice);
        reg.claimSettlement(id);
        assertEq(reg.settled(id, alice), 100 ether);
        assertEq(usd.balanceOf(alice), 200e6);
    }

    // ── 配资: record-only, expires; unclaimed reserve fully sweepable ────────────

    function test_leverage_expiresAndSweeps() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), uint64(block.timestamp + 1 days), false, address(usd), 2e6); // 配资
        _fund(id, 300e6); // covers alice(100) + bob(50)

        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice()); // settles immediately
        assertEq(usd.balanceOf(alice), 200e6);
        assertEq(reg.settleReserve(id), 100e6); // bob's untouched portion

        // 配资 has no deferred settlement path.
        vm.prank(bob);
        vm.expectRevert(WarrantRegistry.NotDeferred.selector);
        reg.claimSettlement(id);

        // After deadline bob's unclaimed allocation expires → full remaining reserve sweeps.
        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        reg.sweepUnsettled(id, custody);
        assertEq(usd.balanceOf(custody), 100e6);
        assertEq(reg.settleReserve(id), 0);
    }

    // ── deferred sweep retains outstanding (recorded-but-unsettled) ─────────────

    function test_deferredSweep_retainsOutstanding() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), uint64(block.timestamp + 1 days), true, address(0), 0);

        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice()); // recorded only

        vm.prank(admin);
        reg.configureSettlement(id, address(usd), 2e6);
        _fund(id, 300e6); // overfunded; alice owed 200e6

        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        reg.sweepUnsettled(id, custody); // must retain alice's 200e6

        assertEq(usd.balanceOf(custody), 100e6, "only the excess swept");
        assertEq(reg.settleReserve(id), 200e6, "outstanding retained");

        // alice can still settle after the deadline (deferred).
        vm.prank(alice);
        reg.claimSettlement(id);
        assertEq(usd.balanceOf(alice), 200e6);
    }

    // ── guards ───────────────────────────────────────────────────────────────

    function test_claim_doubleClaimReverts() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), uint64(block.timestamp + 7 days), true, address(usd), 2e6);
        _fund(id, 300e6);

        vm.prank(alice);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.AlreadyClaimed.selector);
        reg.claim(id, 0, alice, 100 ether, _proofAlice());
    }

    function test_claim_invalidProofReverts() public {
        vm.prank(admin);
        uint256 id = reg.createProgram(_root(), uint64(block.timestamp + 7 days), true, address(usd), 2e6);
        _fund(id, 300e6);

        vm.prank(alice);
        vm.expectRevert(WarrantRegistry.InvalidProof.selector);
        reg.claim(id, 0, alice, 999 ether, _proofAlice()); // wrong amount
    }
}
