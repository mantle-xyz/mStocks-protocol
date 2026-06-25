// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";
import {SecuritiesTokenFactory} from "../src/securitiesToken/SecuritiesTokenFactory.sol";
import {Compliance} from "../src/compliance/Compliance.sol";
import {PauseManager} from "../src/pauseManager/PauseManager.sol";

/**
 * Forge unit/integration tests for SecuritiesToken and its dependencies.
 * Run with: forge test -vv
 *
 * Each test deploys a fresh stack (Compliance, PauseManager, Factory, Token) via
 * setUp(), so state is isolated. The token is deployed via the factory so we exercise
 * the BeaconProxy + initialize path on every run.
 */
contract SecuritiesTokenTest is Test {
    SecuritiesTokenFactory internal factory;
    Compliance internal compliance;
    PauseManager internal pauseManager;
    SecuritiesToken internal token;

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal issuer = makeAddr("issuer");
    address internal operator = makeAddr("operator");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");
    address internal stranger = makeAddr("stranger");

    bytes32 internal ISSUER_ROLE;
    bytes32 internal OPS_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE;

    function setUp() public {
        vm.startPrank(admin);

        compliance = new Compliance(admin);
        pauseManager = new PauseManager(admin);
        factory = new SecuritiesTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin);

        address[] memory issuers = new address[](1);
        issuers[0] = issuer;
        address[] memory operators = new address[](1);
        operators[0] = operator;

        address proxy = factory.deployToken("Apple Inc.", "AAPL", "US0378331005", admin, issuers, operators);
        token = SecuritiesToken(proxy);

        vm.stopPrank();

        ISSUER_ROLE = token.ISSUER_ROLE();
        OPS_ROLE = token.OPS_ROLE();
        DEFAULT_ADMIN_ROLE = 0x00;
    }

    // ═══════════════════════════════════════════════
    //                  Init / metadata
    // ═══════════════════════════════════════════════

    function test_InitialState() public view {
        assertEq(token.name(), "Apple Inc.");
        assertEq(token.symbol(), "AAPL");
        assertEq(token.identifier(), "US0378331005");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
        assertEq(token.uiMultiplier(), 1 ether);
        assertTrue(token.mintEnabled());
        assertTrue(token.burnEnabled());
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(token.hasRole(ISSUER_ROLE, issuer));
        assertTrue(token.hasRole(OPS_ROLE, operator));
    }

    function test_AdminCanRenameAndReSymbol() public {
        vm.startPrank(admin);
        token.setName("Apple Inc. v2");
        token.setSymbol("AAPL2");
        token.setIdentifier("NEWID123");
        vm.stopPrank();

        assertEq(token.name(), "Apple Inc. v2");
        assertEq(token.symbol(), "AAPL2");
        assertEq(token.identifier(), "NEWID123");
    }

    function test_NonAdminCannotRename() public {
        vm.prank(stranger);
        vm.expectRevert();
        token.setName("X");
    }

    // ═══════════════════════════════════════════════
    //                  Mint / burn
    // ═══════════════════════════════════════════════

    function test_AdminCanMint() public {
        vm.prank(admin);
        token.mint(1_000 ether);
        assertEq(token.balanceOf(admin), 1_000 ether);
        assertEq(token.totalSupply(), 1_000 ether);
    }

    function test_IssuerCanMint() public {
        vm.prank(issuer);
        token.mint(500 ether);
        assertEq(token.balanceOf(issuer), 500 ether);
    }

    function test_StrangerCannotMint() public {
        vm.prank(stranger);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.mint(1 ether);
    }

    function test_OperatorCannotMint() public {
        // OPS_ROLE is only for multiplier ops, not mint/burn.
        vm.prank(operator);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.mint(1 ether);
    }

    function test_MintDisabledBlocksMint() public {
        vm.prank(admin);
        token.setMintEnabled(false);
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.MintDisabled.selector);
        token.mint(1 ether);
    }

    function test_AdminCanBurn() public {
        vm.startPrank(admin);
        token.mint(1_000 ether);
        token.burn(400 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(admin), 600 ether);
        assertEq(token.totalSupply(), 600 ether);
    }

    function test_BurnDisabledBlocksBurn() public {
        vm.startPrank(admin);
        token.mint(1 ether);
        token.setBurnEnabled(false);
        vm.expectRevert(SecuritiesToken.BurnDisabled.selector);
        token.burn(1 ether);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════
    //                  Transfer / approve
    // ═══════════════════════════════════════════════

    function test_TransferHappyPath() public {
        vm.prank(admin);
        token.mint(1_000 ether);

        vm.prank(admin);
        token.transfer(user1, 400 ether);
        assertEq(token.balanceOf(admin), 600 ether);
        assertEq(token.balanceOf(user1), 400 ether);

        vm.prank(user1);
        token.transfer(user2, 150 ether);
        assertEq(token.balanceOf(user1), 250 ether);
        assertEq(token.balanceOf(user2), 150 ether);
    }

    function test_ApproveAndTransferFrom() public {
        vm.prank(admin);
        token.mint(1_000 ether);
        vm.prank(admin);
        token.transfer(user1, 500 ether);

        vm.prank(user1);
        token.approve(user2, 200 ether);
        assertEq(token.allowance(user1, user2), 200 ether);

        vm.prank(user2);
        token.transferFrom(user1, user2, 200 ether);
        assertEq(token.balanceOf(user1), 300 ether);
        assertEq(token.balanceOf(user2), 200 ether);
        assertEq(token.allowance(user1, user2), 0);
    }

    // ═══════════════════════════════════════════════
    //                  Pause
    // ═══════════════════════════════════════════════

    function test_PausedTokenBlocksTransfer() public {
        vm.prank(admin);
        token.mint(100 ether);

        vm.prank(admin);
        pauseManager.pauseToken(address(token));

        vm.prank(admin);
        vm.expectRevert();
        token.transfer(user1, 1 ether);
    }

    function test_GlobalPauseBlocksTransfer() public {
        vm.prank(admin);
        token.mint(100 ether);

        vm.prank(admin);
        pauseManager.pauseAllTokens();

        vm.prank(admin);
        vm.expectRevert();
        token.transfer(user1, 1 ether);
    }

    function test_UnpauseRestoresTransfer() public {
        vm.startPrank(admin);
        token.mint(100 ether);
        pauseManager.pauseToken(address(token));
        pauseManager.unpauseToken(address(token));
        token.transfer(user1, 1 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(user1), 1 ether);
    }

    // ═══════════════════════════════════════════════
    //                  Compliance
    // ═══════════════════════════════════════════════

    function test_BlocklistBlocksTransfer() public {
        vm.prank(admin);
        token.mint(100 ether);

        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(admin);
        compliance.addToBlocklist(address(token), list);

        vm.prank(admin);
        vm.expectRevert(Compliance.UserBlocked.selector);
        token.transfer(user1, 1 ether);

        // Removing from blocklist restores transfer
        vm.prank(admin);
        compliance.removeFromBlocklist(address(token), list);
        vm.prank(admin);
        token.transfer(user1, 1 ether);
        assertEq(token.balanceOf(user1), 1 ether);
    }

    function test_SanctionsBlockTransfer() public {
        vm.prank(admin);
        token.mint(100 ether);

        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(admin);
        compliance.addToSanctionsList(list);

        vm.prank(admin);
        vm.expectRevert(Compliance.UserSanctioned.selector);
        token.transfer(user1, 1 ether);
    }

    function test_SanctionsResetClearsAll() public {
        address[] memory list = new address[](2);
        list[0] = user1;
        list[1] = user2;
        vm.prank(admin);
        compliance.addToSanctionsList(list);
        assertTrue(compliance.sanctionedAddresses(user1));
        assertTrue(compliance.sanctionedAddresses(user2));

        vm.prank(admin);
        compliance.resetSanctionedAddresses();
        assertFalse(compliance.sanctionedAddresses(user1));
        assertFalse(compliance.sanctionedAddresses(user2));
    }

    function test_BlocklistIsTokenScoped() public {
        // Block user1 only for THIS token — they remain free on another token
        vm.prank(admin);
        token.mint(100 ether);

        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(admin);
        compliance.addToBlocklist(address(token), list);

        assertTrue(compliance.blockedAddresses(address(token), user1));
        // Same user, different token key → not blocked
        assertFalse(compliance.blockedAddresses(address(0xBEEF), user1));
    }

    // ═══════════════════════════════════════════════
    //                  UI multiplier
    // ═══════════════════════════════════════════════

    function test_AdminCanScheduleMultiplier() public {
        uint256 effective = block.timestamp + 1 hours;
        vm.prank(admin);
        token.setUIMultiplier(2 ether, effective);

        assertEq(token.newUIMultiplier(), 2 ether);
        assertEq(token.effectiveAt(), effective);
        assertTrue(token.hasPendingMultiplier());
    }

    function test_OperatorCanScheduleMultiplier() public {
        uint256 effective = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2 ether, effective);
        assertEq(token.newUIMultiplier(), 2 ether);
    }

    function test_IssuerCannotScheduleMultiplier() public {
        // ISSUER_ROLE is for mint/burn, NOT multiplier
        uint256 effective = block.timestamp + 1 hours;
        vm.prank(issuer);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2 ether, effective);
    }

    function test_StrangerCannotScheduleMultiplier() public {
        vm.prank(stranger);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2 ether, block.timestamp + 1 hours);
    }

    function test_MultiplierActivatesAfterEffectiveAt() public {
        uint256 effective = block.timestamp + 1 hours;
        vm.prank(admin);
        token.setUIMultiplier(2 ether, effective);

        // Before activation: live multiplier still old
        assertEq(token.uiMultiplier(), 1 ether);

        vm.warp(effective);
        assertEq(token.uiMultiplier(), 2 ether);
        assertFalse(token.hasPendingMultiplier());
    }

    function test_MultiplierBelowMinReverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("SecuritiesToken: multiplier below minimum (1e-9x)"));
        token.setUIMultiplier(1e9 - 1, block.timestamp + 1 hours);
    }

    function test_MultiplierAboveMaxReverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("SecuritiesToken: multiplier above maximum (1e9x)"));
        token.setUIMultiplier(1e27 + 1, block.timestamp + 1 hours);
    }

    function test_MultiplierBeyond365DaysReverts() public {
        vm.prank(admin);
        vm.expectRevert(bytes("SecuritiesToken: effective time too far in future"));
        token.setUIMultiplier(2 ether, block.timestamp + 366 days);
    }

    function test_MultiplierPastTimestampReverts() public {
        vm.warp(1_000_000);
        vm.prank(admin);
        vm.expectRevert(bytes("ERC8056: effective time must be in future"));
        token.setUIMultiplier(2 ether, block.timestamp);
    }

    function test_PendingMultiplierOverwriteEmitsAndUpdates() public {
        uint256 firstAt = block.timestamp + 1 hours;
        vm.prank(admin);
        token.setUIMultiplier(2 ether, firstAt);

        // Overwrite with a different schedule (still pending — not yet active)
        uint256 secondAt = block.timestamp + 2 hours;
        vm.prank(admin);
        token.setUIMultiplier(3 ether, secondAt);

        assertEq(token.newUIMultiplier(), 3 ether);
        assertEq(token.effectiveAt(), secondAt);
    }

    function test_ToUIAmountScalesWithMultiplier() public {
        uint256 raw = 100 ether;
        assertEq(token.toUIAmount(raw), raw); // 1.0x

        vm.prank(admin);
        token.setUIMultiplier(2 ether, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours);
        assertEq(token.toUIAmount(raw), raw * 2); // 2.0x

        // fromUIAmount is inverse
        assertEq(token.fromUIAmount(raw * 2), raw);
    }

    function test_BalanceOfUIReflectsMultiplier() public {
        vm.prank(admin);
        token.mint(100 ether);

        vm.prank(admin);
        token.setUIMultiplier(2 ether, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours);

        assertEq(token.balanceOfUI(admin), 200 ether);
        assertEq(token.totalSupplyUI(), 200 ether);
    }

    // ═══════════════════════════════════════════════
    //                  Roles
    // ═══════════════════════════════════════════════

    function test_AdminCanGrantAndRevokeIssuer() public {
        vm.prank(admin);
        token.grantRole(ISSUER_ROLE, user1);
        assertTrue(token.hasRole(ISSUER_ROLE, user1));

        vm.prank(admin);
        token.revokeRole(ISSUER_ROLE, user1);
        assertFalse(token.hasRole(ISSUER_ROLE, user1));
    }

    function test_AdminCanGrantAndRevokeOperator() public {
        vm.prank(admin);
        token.grantRole(OPS_ROLE, user1);
        assertTrue(token.hasRole(OPS_ROLE, user1));

        // User can now schedule a multiplier change
        vm.prank(user1);
        token.setUIMultiplier(2 ether, block.timestamp + 1 hours);

        vm.prank(admin);
        token.revokeRole(OPS_ROLE, user1);

        // Now they can't anymore
        vm.prank(user1);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.setUIMultiplier(3 ether, block.timestamp + 2 hours);
    }

    function test_NonAdminCannotGrantRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        token.grantRole(ISSUER_ROLE, user1);
    }

    // ═══════════════════════════════════════════════
    //                  Factory
    // ═══════════════════════════════════════════════

    function test_FactoryRejectsDuplicateSymbol() public {
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SecuritiesTokenFactory.TokenSymbolAlreadyExists.selector, "AAPL")
        );
        factory.deployToken("Apple v2", "AAPL", "ID2", admin, empty, empty);
    }

    function test_FactoryRegistersDeployedToken() public {
        assertEq(factory.tokenBySymbol("AAPL"), address(token));
        assertEq(factory.deployedTokenCount(), 1);
    }

    function test_FactoryRejectsInvalidSymbol() public {
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SecuritiesTokenFactory.InvalidSymbol.selector, "AAPL!")
        );
        factory.deployToken("X", "AAPL!", "ID3", admin, empty, empty);
    }
}
