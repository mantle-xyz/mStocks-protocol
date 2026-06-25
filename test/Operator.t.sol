// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Operator} from "../src/operator/Operator.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";
import {SecuritiesTokenFactory} from "../src/securitiesToken/SecuritiesTokenFactory.sol";
import {Compliance} from "../src/compliance/Compliance.sol";
import {PauseManager} from "../src/pauseManager/PauseManager.sol";

/// Minimal in-memory stablecoin for tests.
contract MockStable is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract OperatorTest is Test {
    Operator internal op;
    MockStable internal stable;
    SecuritiesToken internal token;
    Compliance internal compliance;
    PauseManager internal pauseManager;
    SecuritiesTokenFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal ops = makeAddr("ops");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");   // buyer

    bytes32 internal OPS_ROLE;
    bytes32 internal TOKEN_ISSUER_ROLE;

    function setUp() public {
        // Deploy core protocol stack.
        vm.startPrank(admin);
        compliance = new Compliance(admin);
        pauseManager = new PauseManager(admin);
        factory = new SecuritiesTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin);
        address[] memory empty = new address[](0);
        token = SecuritiesToken(
            factory.deployToken("Apple Inc.", "AAPL", "US0378331005", admin, empty, empty)
        );

        // Deploy Operator + wire up.
        op = new Operator(admin, treasury);
        op.grantRole(op.OPS_ROLE(), ops);

        // Whitelist stable + token on the Operator.
        stable = new MockStable();
        op.setApprovedStable(address(stable), true);
        op.setApprovedToken(address(token), true);

        // Operator needs ISSUER_ROLE on the token to mint.
        token.grantRole(token.ISSUER_ROLE(), address(op));
        vm.stopPrank();

        OPS_ROLE = op.OPS_ROLE();
        TOKEN_ISSUER_ROLE = token.ISSUER_ROLE();

        // Fund alice with stable and have her pre-approve Operator.
        stable.mint(alice, 10_000 ether);
        vm.prank(alice);
        stable.approve(address(op), type(uint256).max);
    }

    // ═══════════════════════════════════════════════
    //                  Happy path
    // ═══════════════════════════════════════════════

    function test_PurchaseHappyPath() public {
        vm.prank(ops);
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);

        assertEq(stable.balanceOf(alice), 9_900 ether);
        assertEq(stable.balanceOf(treasury), 100 ether);
        assertEq(token.balanceOf(alice), 50 ether);
        assertEq(token.balanceOf(address(op)), 0);  // Operator held no leftover
        assertEq(token.totalSupply(), 50 ether);
    }

    function test_PurchaseEmitsEvent() public {
        vm.prank(ops);
        vm.expectEmit(true, true, true, true);
        emit Operator.Purchased(alice, address(stable), 100 ether, address(token), 50 ether, ops);
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
    }

    // ═══════════════════════════════════════════════
    //                  Permission checks
    // ═══════════════════════════════════════════════

    function test_NonOpsCannotPurchase() public {
        vm.prank(alice);
        vm.expectRevert();  // AccessControl revert (OpenZeppelin custom error)
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
    }

    function test_AdminCannotPurchase() public {
        // admin is DEFAULT_ADMIN_ROLE but NOT OPS_ROLE — and self-grant guard would
        // block them from granting it to themselves anyway.
        vm.prank(admin);
        vm.expectRevert();
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
    }

    function test_RejectsNonWhitelistedStable() public {
        MockStable rogue = new MockStable();
        vm.prank(ops);
        vm.expectRevert(Operator.NotApprovedStable.selector);
        op.purchase(alice, address(rogue), 100 ether, address(token), 50 ether);
    }

    function test_RejectsNonWhitelistedToken() public {
        // Deploy a parallel token but don't whitelist it.
        vm.startPrank(admin);
        address[] memory empty = new address[](0);
        address otherToken = factory.deployToken("Tesla Inc.", "TSLA", "US88160R1014", admin, empty, empty);
        vm.stopPrank();

        vm.prank(ops);
        vm.expectRevert(Operator.NotApprovedToken.selector);
        op.purchase(alice, address(stable), 100 ether, otherToken, 50 ether);
    }

    function test_ZeroUserReverts() public {
        vm.prank(ops);
        vm.expectRevert(Operator.ZeroAddress.selector);
        op.purchase(address(0), address(stable), 100 ether, address(token), 50 ether);
    }

    function test_ZeroAmountReverts() public {
        vm.prank(ops);
        vm.expectRevert(Operator.ZeroAmount.selector);
        op.purchase(alice, address(stable), 0, address(token), 50 ether);

        vm.prank(ops);
        vm.expectRevert(Operator.ZeroAmount.selector);
        op.purchase(alice, address(stable), 100 ether, address(token), 0);
    }

    function test_TreasuryNotSetReverts() public {
        // Deploy a fresh Operator without treasury and verify the guard fires.
        vm.startPrank(admin);
        Operator op2 = new Operator(admin, address(0));
        op2.grantRole(op2.OPS_ROLE(), ops);
        op2.setApprovedStable(address(stable), true);
        op2.setApprovedToken(address(token), true);
        vm.stopPrank();

        vm.prank(ops);
        vm.expectRevert(Operator.TreasuryNotSet.selector);
        op2.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
    }

    // ═══════════════════════════════════════════════
    //                  Approval / balance failures
    // ═══════════════════════════════════════════════

    function test_InsufficientApprovalReverts() public {
        address bob = makeAddr("bob");
        stable.mint(bob, 1_000 ether);
        // bob did NOT approve op
        vm.prank(ops);
        vm.expectRevert();  // ERC20 insufficient allowance
        op.purchase(bob, address(stable), 100 ether, address(token), 50 ether);
    }

    function test_InsufficientBalanceReverts() public {
        address poor = makeAddr("poor");
        // poor pre-approves but has no balance
        vm.prank(poor);
        stable.approve(address(op), type(uint256).max);

        vm.prank(ops);
        vm.expectRevert();  // ERC20 insufficient balance
        op.purchase(poor, address(stable), 100 ether, address(token), 50 ether);
    }

    // ═══════════════════════════════════════════════
    //          Integration with token guards
    // ═══════════════════════════════════════════════

    function test_PausedTokenBlocksPurchase() public {
        vm.prank(admin);
        pauseManager.pauseToken(address(token));

        vm.prank(ops);
        vm.expectRevert();  // TokenPaused from PauseManagerClient
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
    }

    function test_BlockedUserCannotPurchase() public {
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(admin);
        compliance.addToBlocklist(address(token), list);

        vm.prank(ops);
        vm.expectRevert(Compliance.UserBlocked.selector);
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
    }

    function test_OperatorWithoutIssuerRoleReverts() public {
        // Revoke ISSUER_ROLE from operator, then attempt purchase
        vm.prank(admin);
        token.revokeRole(TOKEN_ISSUER_ROLE, address(op));

        vm.prank(ops);
        vm.expectRevert(Operator.MissingIssuerRole.selector);
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
    }

    function test_PurchaseRoleCheckRunsBeforeStablePull() public {
        // Revoke ISSUER_ROLE — purchase should revert WITHOUT pulling alice's stable.
        vm.prank(admin);
        token.revokeRole(TOKEN_ISSUER_ROLE, address(op));

        uint256 aliceStableBefore = stable.balanceOf(alice);
        uint256 treasuryStableBefore = stable.balanceOf(treasury);

        vm.prank(ops);
        vm.expectRevert(Operator.MissingIssuerRole.selector);
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);

        assertEq(stable.balanceOf(alice), aliceStableBefore);
        assertEq(stable.balanceOf(treasury), treasuryStableBefore);
    }

    // ═══════════════════════════════════════════════
    //                  Admin management
    // ═══════════════════════════════════════════════

    function test_AdminCanUpdateTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        op.setTreasury(newTreasury);
        assertEq(op.treasury(), newTreasury);
    }

    function test_NonAdminCannotUpdateTreasury() public {
        vm.prank(ops);
        vm.expectRevert();
        op.setTreasury(makeAddr("x"));
    }

    function test_AdminCanRevokeStableWhitelist() public {
        vm.prank(admin);
        op.setApprovedStable(address(stable), false);

        vm.prank(ops);
        vm.expectRevert(Operator.NotApprovedStable.selector);
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
    }

    // ═══════════════════════════════════════════════
    //                  Self-grant guard
    // ═══════════════════════════════════════════════

    function test_AdminCannotSelfGrantOps() public {
        vm.prank(admin);
        vm.expectRevert(Operator.SelfGrantNotAllowed.selector);
        op.grantRole(OPS_ROLE, admin);
    }

    // ═══════════════════════════════════════════════
    //                       sell
    // ═══════════════════════════════════════════════

    /// Set up the state needed for sell: alice owns some token (via a prior purchase),
    /// alice has approved Operator on her token, treasury has stable + has approved Operator.
    function _setupSell() internal {
        // First do a purchase so alice has 50 tokens.
        vm.prank(ops);
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
        assertEq(token.balanceOf(alice), 50 ether);

        // Alice approves Operator on the security token (so Operator can pull on her behalf).
        vm.prank(alice);
        token.approve(address(op), type(uint256).max);

        // Treasury approves Operator on the stable (so Operator can pay out from treasury).
        vm.prank(treasury);
        stable.approve(address(op), type(uint256).max);
    }

    function test_SellHappyPath() public {
        _setupSell();
        uint256 treasuryStableBefore = stable.balanceOf(treasury);

        vm.prank(ops);
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);

        // alice burned 20 token, received 40 stable back
        assertEq(token.balanceOf(alice), 30 ether);
        assertEq(token.totalSupply(), 30 ether);
        assertEq(token.balanceOf(address(op)), 0); // operator burned everything it received
        assertEq(stable.balanceOf(alice), 9_900 ether + 40 ether);
        assertEq(stable.balanceOf(treasury), treasuryStableBefore - 40 ether);
    }

    function test_SellEmitsEvent() public {
        _setupSell();
        vm.prank(ops);
        vm.expectEmit(true, true, true, true);
        emit Operator.Sold(alice, address(token), 20 ether, address(stable), 40 ether, ops);
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);
    }

    function test_NonOpsCannotSell() public {
        _setupSell();
        vm.prank(alice);
        vm.expectRevert();
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);
    }

    function test_SellRejectsNonWhitelistedToken() public {
        _setupSell();
        vm.startPrank(admin);
        address[] memory empty = new address[](0);
        address otherToken = factory.deployToken("Tesla Inc.", "TSLA", "US88160R1014", admin, empty, empty);
        vm.stopPrank();

        vm.prank(ops);
        vm.expectRevert(Operator.NotApprovedToken.selector);
        op.sell(alice, otherToken, 20 ether, address(stable), 40 ether);
    }

    function test_SellRejectsNonWhitelistedStable() public {
        _setupSell();
        MockStable rogue = new MockStable();
        vm.prank(ops);
        vm.expectRevert(Operator.NotApprovedStable.selector);
        op.sell(alice, address(token), 20 ether, address(rogue), 40 ether);
    }

    function test_SellZeroUserReverts() public {
        _setupSell();
        vm.prank(ops);
        vm.expectRevert(Operator.ZeroAddress.selector);
        op.sell(address(0), address(token), 20 ether, address(stable), 40 ether);
    }

    function test_SellZeroAmountReverts() public {
        _setupSell();
        vm.prank(ops);
        vm.expectRevert(Operator.ZeroAmount.selector);
        op.sell(alice, address(token), 0, address(stable), 40 ether);

        vm.prank(ops);
        vm.expectRevert(Operator.ZeroAmount.selector);
        op.sell(alice, address(token), 20 ether, address(stable), 0);
    }

    function test_SellInsufficientUserApprovalReverts() public {
        // Do a purchase but do NOT approve token to operator
        vm.prank(ops);
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
        vm.prank(treasury);
        stable.approve(address(op), type(uint256).max);

        vm.prank(ops);
        vm.expectRevert(); // ERC20 insufficient allowance
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);
    }

    function test_SellInsufficientTreasuryApprovalReverts() public {
        // Set up with user approval but treasury does NOT approve op for payout
        vm.prank(ops);
        op.purchase(alice, address(stable), 100 ether, address(token), 50 ether);
        vm.prank(alice);
        token.approve(address(op), type(uint256).max);
        // treasury approval intentionally omitted

        vm.prank(ops);
        vm.expectRevert();
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);
    }

    function test_PausedTokenBlocksSell() public {
        _setupSell();
        vm.prank(admin);
        pauseManager.pauseToken(address(token));

        vm.prank(ops);
        vm.expectRevert(); // TokenPaused
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);
    }

    function test_BlockedUserCannotSell() public {
        _setupSell();
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(admin);
        compliance.addToBlocklist(address(token), list);

        vm.prank(ops);
        vm.expectRevert(Compliance.UserBlocked.selector);
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);
    }

    function test_OperatorWithoutIssuerRoleCannotSell() public {
        _setupSell();
        vm.prank(admin);
        token.revokeRole(TOKEN_ISSUER_ROLE, address(op));

        vm.prank(ops);
        vm.expectRevert(Operator.MissingIssuerRole.selector);
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);
    }

    function test_SellRoleCheckRunsBeforeTokenPull() public {
        _setupSell();
        vm.prank(admin);
        token.revokeRole(TOKEN_ISSUER_ROLE, address(op));

        uint256 aliceTokenBefore = token.balanceOf(alice);
        uint256 totalSupplyBefore = token.totalSupply();

        vm.prank(ops);
        vm.expectRevert(Operator.MissingIssuerRole.selector);
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);

        // alice's token balance unchanged, supply unchanged → no token movement happened
        assertEq(token.balanceOf(alice), aliceTokenBefore);
        assertEq(token.totalSupply(), totalSupplyBefore);
    }

    function test_BurnDisabledBlocksSell() public {
        _setupSell();
        vm.prank(admin);
        token.setBurnEnabled(false);

        vm.prank(ops);
        vm.expectRevert(SecuritiesToken.BurnDisabled.selector);
        op.sell(alice, address(token), 20 ether, address(stable), 40 ether);
    }
}
