// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../src/pauseRegistry/PauseRegistry.sol";
import {TokenIssuer} from "../src/tokenIssuer/TokenIssuer.sol";

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

/// @notice Tests for 方案二: TokenIssuer privatization (configure + claim, mint new on demand).
contract TokenIssuerPrivatizationTest is Test {
    ScaledTokenFactory internal factory;
    ComplianceRegistry internal compliance;
    PauseRegistry internal pauseManager;
    TokenIssuer internal issuer;
    MockUSD internal usdc;

    ScaledToken internal oldToken;
    ScaledToken internal newToken;

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal complianceOps = makeAddr("complianceOps");
    address internal ops = makeAddr("ops");
    address internal custody = makeAddr("custody");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = new ScaledTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin, 24 hours);
        usdc = new MockUSD();

        // The issuer holds ISSUER_ROLE on both tokens; the test contract also seeds old balances.
        issuer = TokenIssuer(
            address(new ERC1967Proxy(address(new TokenIssuer()), abi.encodeCall(TokenIssuer.initialize, (admin))))
        );

        address[] memory issuers = new address[](2);
        issuers[0] = address(issuer);
        issuers[1] = address(this);
        address[] memory schedulers = new address[](0);
        oldToken = ScaledToken(factory.createToken("Old Co", "OLD", "US0000000001", admin, issuers, schedulers));
        newToken = ScaledToken(factory.createToken("New Co", "NEW", "US0000000002", admin, issuers, schedulers));

        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        issuer.grantRole(issuer.OPS_ROLE(), ops);
        vm.stopPrank();
    }

    /// @dev Fund + reserve `amount` of USDC for `oldToken`'s privatization via the accounted path.
    function _fundCash(uint256 amount) internal {
        usdc.mint(ops, amount);
        vm.startPrank(ops);
        usdc.approve(address(issuer), amount);
        issuer.depositPrivatizationCash(address(oldToken), amount);
        vm.stopPrank();
    }

    function _seedOld(address to, uint256 amount) internal {
        oldToken.mint(amount); // test contract is an issuer on old token
        oldToken.transfer(to, amount);
    }

    function _configure(uint256 newRate, uint256 usdcRate, uint64 deadline) internal {
        vm.startPrank(admin);
        issuer.configurePrivatization(
            address(oldToken),
            newRate == 0 ? address(0) : address(newToken),
            usdcRate == 0 ? address(0) : address(usdc),
            newRate,
            usdcRate,
            deadline
        );
        oldToken.setMintAllowed(false); // freeze old supply (after seeding)
        vm.stopPrank();
    }

    function _blockOnNew(address who) internal {
        address[] memory arr = new address[](1);
        arr[0] = who;
        vm.prank(complianceOps);
        compliance.blockUsers(address(newToken), arr);
    }

    function test_claim_stockPlusCash_mintsNewOnDemand() public {
        _seedOld(alice, 100 ether);
        _configure(2e18, 3e6, uint64(block.timestamp + 7 days));
        _fundCash(300e6); // fund + reserve cash leg; new token minted on demand

        (uint256 newOut, uint256 usdcOut) = issuer.previewPrivatizationClaim(address(oldToken), 100 ether);
        assertEq(newOut, 200 ether);
        assertEq(usdcOut, 300e6);

        vm.startPrank(alice);
        oldToken.approve(address(issuer), 100 ether);
        issuer.claimPrivatization(address(oldToken), 100 ether);
        vm.stopPrank();

        assertEq(oldToken.balanceOf(alice), 0);
        assertEq(oldToken.totalSupply(), 0, "old burned");
        assertEq(newToken.balanceOf(alice), 200 ether, "new minted + delivered");
        assertEq(newToken.totalSupply(), 200 ether);
        assertEq(usdc.balanceOf(alice), 300e6);
    }

    function test_claim_cashOnly() public {
        _seedOld(alice, 50 ether);
        _configure(0, 5e6, uint64(block.timestamp + 7 days));
        _fundCash(250e6);

        vm.startPrank(alice);
        oldToken.approve(address(issuer), 50 ether);
        issuer.claimPrivatization(address(oldToken), 50 ether);
        vm.stopPrank();

        assertEq(oldToken.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 250e6);
    }

    function test_claim_insufficientReservedCashReverts() public {
        _seedOld(alice, 100 ether);
        _configure(0, 5e6, uint64(block.timestamp + 7 days));
        _fundCash(100e6); // underfunded: owed 500e6

        vm.startPrank(alice);
        oldToken.approve(address(issuer), 100 ether);
        vm.expectRevert(TokenIssuer.InsufficientReservedCash.selector);
        issuer.claimPrivatization(address(oldToken), 100 ether);
        vm.stopPrank();
    }

    function test_claim_blockedHolderReverts() public {
        _seedOld(bob, 100 ether);
        _configure(2e18, 0, uint64(block.timestamp + 7 days));
        _blockOnNew(bob);

        vm.startPrank(bob);
        oldToken.approve(address(issuer), 100 ether);
        vm.expectRevert(); // UserBlocked on NEW
        issuer.claimPrivatization(address(oldToken), 100 ether);
        vm.stopPrank();

        assertEq(oldToken.balanceOf(bob), 100 ether, "old not taken on failed claim");
    }

    function test_claim_inactiveReverts() public {
        _seedOld(alice, 100 ether);
        // no configure
        vm.startPrank(alice);
        oldToken.approve(address(issuer), 100 ether);
        vm.expectRevert(TokenIssuer.PrivatizationInactive.selector);
        issuer.claimPrivatization(address(oldToken), 100 ether);
        vm.stopPrank();
    }

    function test_claim_afterDeadlineReverts() public {
        _seedOld(alice, 100 ether);
        _configure(2e18, 0, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);

        vm.startPrank(alice);
        oldToken.approve(address(issuer), 100 ether);
        vm.expectRevert(TokenIssuer.PrivatizationClaimClosed.selector);
        issuer.claimPrivatization(address(oldToken), 100 ether);
        vm.stopPrank();
    }

    function test_configure_requiresConsideration() public {
        vm.prank(admin);
        vm.expectRevert(TokenIssuer.NoConsiderationConfigured.selector);
        issuer.configurePrivatization(address(oldToken), address(0), address(0), 0, 0, uint64(block.timestamp + 1 days));
    }

    function test_configure_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        issuer.configurePrivatization(
            address(oldToken), address(newToken), address(0), 2e18, 0, uint64(block.timestamp + 1 days)
        );
    }

    function test_close_stopsClaims() public {
        _seedOld(alice, 100 ether);
        _configure(2e18, 0, uint64(block.timestamp + 7 days));
        vm.prank(admin);
        issuer.closePrivatization(address(oldToken));

        vm.startPrank(alice);
        oldToken.approve(address(issuer), 100 ether);
        vm.expectRevert(TokenIssuer.PrivatizationInactive.selector);
        issuer.claimPrivatization(address(oldToken), 100 ether);
        vm.stopPrank();
    }

    function test_sweepUnclaimed_deadlineGated() public {
        _seedOld(alice, 100 ether);
        _configure(0, 5e6, uint64(block.timestamp + 1 days));
        _fundCash(500e6);

        // Before the deadline the reserved cash cannot be swept — protects live claimers.
        vm.prank(admin);
        vm.expectRevert(TokenIssuer.PrivatizationClaimStillOpen.selector);
        issuer.sweepUnclaimed(address(oldToken), custody);

        // Alice claims half; 250e6 remains reserved.
        vm.startPrank(alice);
        oldToken.approve(address(issuer), 50 ether);
        issuer.claimPrivatization(address(oldToken), 50 ether);
        vm.stopPrank();
        assertEq(issuer.usdcReserved(address(oldToken)), 250e6);

        // After the deadline, the unclaimed remainder sweeps to custody and the event closes.
        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        issuer.sweepUnclaimed(address(oldToken), custody);
        assertEq(usdc.balanceOf(custody), 250e6);
        assertEq(issuer.usdcReserved(address(oldToken)), 0);

        (,,,,, bool active) = issuer.privatizations(address(oldToken));
        assertFalse(active, "closed after sweep");
    }

    function test_sweepUnclaimed_onlyAdmin() public {
        _configure(0, 5e6, uint64(block.timestamp + 1 days));
        _fundCash(100e6);
        vm.warp(block.timestamp + 2 days);
        vm.prank(ops);
        vm.expectRevert();
        issuer.sweepUnclaimed(address(oldToken), custody);
    }

    function test_depositCash_requiresCashLeg() public {
        _seedOld(alice, 1 ether);
        _configure(2e18, 0, uint64(block.timestamp + 7 days)); // stock-only, no cash leg
        usdc.mint(ops, 1e6);
        vm.startPrank(ops);
        usdc.approve(address(issuer), 1e6);
        vm.expectRevert(TokenIssuer.NoCashLeg.selector);
        issuer.depositPrivatizationCash(address(oldToken), 1e6);
        vm.stopPrank();
    }
}
