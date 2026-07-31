// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../src/pauseRegistry/PauseRegistry.sol";
import {PrivatizationPool} from "../src/privatization/PrivatizationPool.sol";

/// @dev Minimal settlement stablecoin (6 decimals like USDC).
contract MockUSD is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Tests for 方案一 (PrivatizationPool): fixed-rate, approve+claim, no snapshot/escrow.
contract PrivatizationPoolTest is Test {
    ScaledTokenFactory internal factory;
    ComplianceRegistry internal compliance;
    PauseRegistry internal pauseManager;
    MockUSD internal usdc;

    ScaledToken internal oldToken; // retired security
    ScaledToken internal newToken; // consideration stock

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal complianceOps = makeAddr("complianceOps");
    address internal custody = makeAddr("custody");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant RATE = 1e18;

    function setUp() public {
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = new ScaledTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin, 24 hours);
        usdc = new MockUSD();

        address[] memory issuers = new address[](1);
        issuers[0] = address(this); // test contract seeds balances (is a contract, satisfies EOA guard)
        address[] memory schedulers = new address[](0);
        oldToken = ScaledToken(factory.createToken("Old Co", "OLD", "US0000000001", admin, issuers, schedulers));
        newToken = ScaledToken(factory.createToken("New Co", "NEW", "US0000000002", admin, issuers, schedulers));

        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        vm.stopPrank();
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _seedOld(address to, uint256 amount) internal {
        oldToken.mint(amount); // to this (issuer)
        oldToken.transfer(to, amount);
    }

    function _fundPoolNew(address pool, uint256 amount) internal {
        newToken.mint(amount);
        newToken.transfer(pool, amount);
    }

    /// @dev Deploy a pool and wire it up: pool holds ISSUER_ROLE on old token (to burn),
    ///      old token mint is frozen.
    function _deployPool(uint256 newRate, uint256 usdcRate, uint64 deadline) internal returns (PrivatizationPool pool) {
        pool = new PrivatizationPool(
            address(oldToken),
            newRate == 0 ? address(0) : address(newToken),
            usdcRate == 0 ? address(0) : address(usdc),
            newRate,
            usdcRate,
            deadline,
            admin
        );
        bytes32 issuerRole = oldToken.ISSUER_ROLE();
        vm.startPrank(admin);
        oldToken.grantRole(issuerRole, address(pool));
        oldToken.setMintAllowed(false); // freeze old supply
        vm.stopPrank();
    }

    function _blockOnNew(address who) internal {
        address[] memory arr = new address[](1);
        arr[0] = who;
        vm.prank(complianceOps);
        compliance.blockUsers(address(newToken), arr);
    }

    // ─── tests ────────────────────────────────────────────────────────────────

    function test_claim_stockPlusCash() public {
        _seedOld(alice, 100 ether);
        // 2 NEW + 3 USDC (6dp) per 1 OLD
        PrivatizationPool pool = _deployPool(2e18, 3e6, uint64(block.timestamp + 7 days));
        _fundPoolNew(address(pool), 200 ether);
        usdc.mint(address(pool), 300e6);

        (uint256 newOut, uint256 usdcOut) = pool.previewClaim(100 ether);
        assertEq(newOut, 200 ether);
        assertEq(usdcOut, 300e6);

        vm.startPrank(alice);
        oldToken.approve(address(pool), 100 ether);
        pool.claim(100 ether);
        vm.stopPrank();

        assertEq(oldToken.balanceOf(alice), 0, "old surrendered");
        assertEq(oldToken.totalSupply(), 0, "old burned");
        assertEq(newToken.balanceOf(alice), 200 ether, "new delivered");
        assertEq(usdc.balanceOf(alice), 300e6, "cash delivered");
    }

    function test_claim_partialAmount() public {
        _seedOld(alice, 100 ether);
        PrivatizationPool pool = _deployPool(2e18, 0, uint64(block.timestamp + 7 days));
        _fundPoolNew(address(pool), 200 ether);

        vm.startPrank(alice);
        oldToken.approve(address(pool), 40 ether);
        pool.claim(40 ether);
        vm.stopPrank();

        assertEq(oldToken.balanceOf(alice), 60 ether, "remainder kept");
        assertEq(newToken.balanceOf(alice), 80 ether);
    }

    function test_claim_cashOnlyRedemption() public {
        _seedOld(alice, 50 ether);
        PrivatizationPool pool = _deployPool(0, 5e6, uint64(block.timestamp + 7 days)); // 5 USDC per OLD
        usdc.mint(address(pool), 250e6);

        vm.startPrank(alice);
        oldToken.approve(address(pool), 50 ether);
        pool.claim(50 ether);
        vm.stopPrank();

        assertEq(oldToken.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 250e6);
    }

    function test_claim_blockedHolderReverts() public {
        _seedOld(bob, 100 ether);
        PrivatizationPool pool = _deployPool(2e18, 0, uint64(block.timestamp + 7 days));
        _fundPoolNew(address(pool), 200 ether);
        _blockOnNew(bob); // bob cannot receive NEW → whole claim reverts

        vm.startPrank(bob);
        oldToken.approve(address(pool), 100 ether);
        vm.expectRevert(); // UserBlocked from NEW token compliance
        pool.claim(100 ether);
        vm.stopPrank();

        assertEq(oldToken.balanceOf(bob), 100 ether, "old NOT taken on failed claim");
    }

    function test_claim_afterDeadlineReverts() public {
        _seedOld(alice, 100 ether);
        PrivatizationPool pool = _deployPool(2e18, 0, uint64(block.timestamp + 1 days));
        _fundPoolNew(address(pool), 200 ether);

        vm.warp(block.timestamp + 2 days);
        vm.startPrank(alice);
        oldToken.approve(address(pool), 100 ether);
        vm.expectRevert(PrivatizationPool.ClaimClosed.selector);
        pool.claim(100 ether);
        vm.stopPrank();
    }

    function test_sweepUnclaimed() public {
        PrivatizationPool pool = _deployPool(2e18, 3e6, uint64(block.timestamp + 1 days));
        _fundPoolNew(address(pool), 200 ether);
        usdc.mint(address(pool), 300e6);

        vm.prank(admin);
        vm.expectRevert(PrivatizationPool.ClaimStillOpen.selector);
        pool.sweepUnclaimed(custody);

        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        pool.sweepUnclaimed(custody);
        assertEq(newToken.balanceOf(custody), 200 ether);
        assertEq(usdc.balanceOf(custody), 300e6);
    }

    function test_sweep_onlyAdmin() public {
        PrivatizationPool pool = _deployPool(2e18, 0, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vm.expectRevert(PrivatizationPool.NotAdmin.selector);
        pool.sweepUnclaimed(custody);
    }

    function test_deploy_requiresConsideration() public {
        vm.expectRevert(PrivatizationPool.NoConsiderationConfigured.selector);
        new PrivatizationPool(address(oldToken), address(0), address(0), 0, 0, uint64(block.timestamp + 1 days), admin);
    }
}
