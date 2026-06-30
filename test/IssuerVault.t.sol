// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IssuerVault} from "../src/issuerVault/IssuerVault.sol";
import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../src/pauseRegistry/PauseRegistry.sol";

contract IssuerVaultTest is Test {
    IssuerVault internal vault;
    ScaledToken internal token;
    ComplianceRegistry internal compliance;
    PauseRegistry internal pauseManager;
    ScaledTokenFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal ops = makeAddr("ops");
    address internal recipient1 = makeAddr("recipient1");
    address internal recipient2 = makeAddr("recipient2");
    address internal stranger = makeAddr("stranger");

    bytes32 internal OPS_ROLE;

    function setUp() public {
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = new ScaledTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin);
        address[] memory empty = new address[](0);
        token = ScaledToken(
            factory.createToken("Apple Inc.", "AAPL", "US0378331005", admin, empty, empty)
        );

        IssuerVault impl = new IssuerVault();
        bytes memory initData = abi.encodeWithSelector(IssuerVault.initialize.selector, admin);
        vault = IssuerVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        // Admin's only job: hand out roles. Self-grant guard blocks grant-to-self, so use `ops`.
        vault.grantRole(vault.OPS_ROLE(), ops);
        // Vault needs ISSUER_ROLE on the token to mint.
        token.grantRole(token.ISSUER_ROLE(), address(vault));
        vm.stopPrank();

        OPS_ROLE = vault.OPS_ROLE();
    }

    function test_AdminHoldsDefaultAdminRole() public view {
        assertTrue(vault.hasRole(0x00, admin));
    }

    function test_InitializerCannotBeCalledTwice() public {
        vm.expectRevert();
        vault.initialize(admin);
    }

    function test_OpsHoldsOpsRole() public view {
        assertTrue(vault.hasRole(OPS_ROLE, ops));
    }

    function test_StrangerHoldsNothing() public view {
        assertFalse(vault.hasRole(0x00, stranger));
        assertFalse(vault.hasRole(OPS_ROLE, stranger));
    }

    function test_AdminCanAddApprovedRecipient() public {
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);
        assertTrue(vault.isApprovedRecipient(recipient1));
        assertEq(vault.numApprovedRecipients(), 1);
    }

    function test_NonAdminCannotAddApprovedRecipient() public {
        vm.prank(ops);
        vm.expectRevert();
        vault.addApprovedRecipient(recipient1);
    }

    function test_AddZeroApprovedRecipientReverts() public {
        vm.prank(admin);
        vm.expectRevert(IssuerVault.ZeroAddress.selector);
        vault.addApprovedRecipient(address(0));
    }

    function test_AddDuplicateApprovedRecipientReverts() public {
        vm.startPrank(admin);
        vault.addApprovedRecipient(recipient1);
        vm.expectRevert(IssuerVault.RecipientAlreadyApproved.selector);
        vault.addApprovedRecipient(recipient1);
        vm.stopPrank();
    }

    function test_AddSelfAsApprovedRecipientReverts() public {
        vm.prank(admin);
        vm.expectRevert(IssuerVault.CannotBeSelf.selector);
        vault.addApprovedRecipient(address(vault));
    }

    function test_AdminCanRemoveApprovedRecipient() public {
        vm.startPrank(admin);
        vault.addApprovedRecipient(recipient1);
        vault.addApprovedRecipient(recipient2);
        vault.removeApprovedRecipient(recipient1);
        vm.stopPrank();
        assertFalse(vault.isApprovedRecipient(recipient1));
        assertTrue(vault.isApprovedRecipient(recipient2));
        assertEq(vault.numApprovedRecipients(), 1);
    }

    function test_RemoveUnknownApprovedRecipientReverts() public {
        vm.prank(admin);
        vm.expectRevert(IssuerVault.RecipientNotApproved.selector);
        vault.removeApprovedRecipient(recipient1);
    }

    function test_AdminCanPauseAndUnpause() public {
        vm.startPrank(admin);
        vault.pause();
        vm.expectRevert();
        vault.addApprovedRecipient(recipient1);
        vault.unpause();
        vault.addApprovedRecipient(recipient1);
        vm.stopPrank();
        assertTrue(vault.isApprovedRecipient(recipient1));
    }

    function test_NonAdminCannotPause() public {
        vm.prank(ops);
        vm.expectRevert();
        vault.pause();
    }

    function test_OpsCanMintToApprovedRecipient() public {
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);

        vm.prank(ops);
        vault.mint(address(token), recipient1, 100 ether);

        assertEq(token.balanceOf(recipient1), 100 ether);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.totalSupply(), 100 ether);
    }

    function test_MintEmitsMintedEvent() public {
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IssuerVault.Minted(address(vault), address(token), recipient1, 100 ether);

        vm.prank(ops);
        vault.mint(address(token), recipient1, 100 ether);
    }

    function test_MintToSelfEmitsMintedEventWithVaultAsRecipient() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit IssuerVault.Minted(address(vault), address(token), address(vault), 50 ether);

        vm.prank(ops);
        vault.mint(address(token), address(vault), 50 ether);
    }

    function test_OpsCanMintToSelf() public {
        vm.prank(ops);
        vault.mint(address(token), address(vault), 50 ether);

        assertEq(token.balanceOf(address(vault)), 50 ether);
        assertEq(token.totalSupply(), 50 ether);
    }

    function test_MintToUnapprovedRecipientReverts() public {
        vm.prank(ops);
        vm.expectRevert(IssuerVault.RecipientNotApproved.selector);
        vault.mint(address(token), stranger, 1 ether);
    }

    function test_AdminCannotMint() public {
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);

        vm.prank(admin);
        vm.expectRevert();
        vault.mint(address(token), recipient1, 1 ether);
    }

    function test_OpsCanTransfer() public {
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);

        vm.startPrank(ops);
        vault.mint(address(token), address(vault), 50 ether);
        vault.transfer(address(token), recipient1, 30 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(recipient1), 30 ether);
        assertEq(token.balanceOf(address(vault)), 20 ether);
    }

    function test_TransferToUnapprovedRecipientReverts() public {
        vm.prank(ops);
        vault.mint(address(token), address(vault), 50 ether);

        vm.prank(ops);
        vm.expectRevert(IssuerVault.RecipientNotApproved.selector);
        vault.transfer(address(token), stranger, 1 ether);
    }

    function test_VaultWithoutIssuerRoleMintReverts() public {
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(vault));
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);

        vm.prank(ops);
        vm.expectRevert(IssuerVault.MissingIssuerRole.selector);
        vault.mint(address(token), recipient1, 1 ether);
    }

    function test_MintIssuerRoleCheckRunsBeforeMintCall() public {
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(vault));
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(ops);
        vm.expectRevert(IssuerVault.MissingIssuerRole.selector);
        vault.mint(address(token), recipient1, 1 ether);
        assertEq(token.totalSupply(), supplyBefore);
    }

    /// Helper: mint tokens to recipient1 and have it approve the vault so subsequent
    /// burn tests can pull from it.
    function _seedRecipientForBurn() internal returns (uint256 minted) {
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);
        vm.prank(ops);
        vault.mint(address(token), recipient1, 100 ether);
        vm.prank(recipient1);
        token.approve(address(vault), type(uint256).max);
        minted = 100 ether;
    }

    function test_OpsCanBurn() public {
        _seedRecipientForBurn();
        uint256 supplyBefore = token.totalSupply();

        vm.prank(ops);
        vault.burn(address(token), recipient1, 40 ether);

        assertEq(token.balanceOf(recipient1), 60 ether);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.totalSupply(), supplyBefore - 40 ether);
    }

    function test_BurnEmitsBurnedEvent() public {
        _seedRecipientForBurn();

        vm.expectEmit(true, true, true, true, address(vault));
        emit IssuerVault.Burned(address(vault), address(token), recipient1, 40 ether);

        vm.prank(ops);
        vault.burn(address(token), recipient1, 40 ether);
    }

    function test_BurnFromSelfEmitsBurnedEventWithVaultAsFrom() public {
        vm.prank(ops);
        vault.mint(address(token), address(vault), 100 ether);

        vm.expectEmit(true, true, true, true, address(vault));
        emit IssuerVault.Burned(address(vault), address(token), address(vault), 30 ether);

        vm.prank(ops);
        vault.burn(address(token), address(vault), 30 ether);
    }

    function test_AdminCannotBurn() public {
        _seedRecipientForBurn();
        vm.prank(admin);
        vm.expectRevert();
        vault.burn(address(token), recipient1, 1 ether);
    }

    function test_StrangerCannotBurn() public {
        _seedRecipientForBurn();
        vm.prank(stranger);
        vm.expectRevert();
        vault.burn(address(token), recipient1, 1 ether);
    }

    function test_BurnWithoutApprovalReverts() public {
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);
        vm.prank(ops);
        vault.mint(address(token), recipient1, 100 ether);

        vm.prank(ops);
        vm.expectRevert();
        vault.burn(address(token), recipient1, 10 ether);
    }

    function test_BurnWithoutBalanceReverts() public {
        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);
        vm.prank(recipient1);
        token.approve(address(vault), type(uint256).max);

        vm.prank(ops);
        vm.expectRevert();
        vault.burn(address(token), recipient1, 10 ether);
    }

    function test_VaultWithoutIssuerRoleBurnReverts() public {
        _seedRecipientForBurn();
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(vault));

        vm.prank(ops);
        vm.expectRevert(IssuerVault.MissingIssuerRole.selector);
        vault.burn(address(token), recipient1, 10 ether);
    }

    function test_BurnIssuerRoleCheckRunsBeforeTokenPull() public {
        _seedRecipientForBurn();
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(vault));

        uint256 holderBefore = token.balanceOf(recipient1);
        uint256 vaultBefore = token.balanceOf(address(vault));

        vm.prank(ops);
        vm.expectRevert(IssuerVault.MissingIssuerRole.selector);
        vault.burn(address(token), recipient1, 10 ether);

        assertEq(token.balanceOf(recipient1), holderBefore);
        assertEq(token.balanceOf(address(vault)), vaultBefore);
    }

    function test_BurnPausedVaultReverts() public {
        _seedRecipientForBurn();
        vm.prank(admin);
        vault.pause();

        vm.prank(ops);
        vm.expectRevert();
        vault.burn(address(token), recipient1, 1 ether);
    }

    function test_BurnNotAllowedOnTokenReverts() public {
        _seedRecipientForBurn();
        vm.prank(admin);
        token.setBurnAllowed(false);

        vm.prank(ops);
        vm.expectRevert(ScaledToken.BurnNotAllowed.selector);
        vault.burn(address(token), recipient1, 1 ether);
    }

    function test_BurnFromUnapprovedRecipientReverts() public {
        address holder = makeAddr("ordinaryHolder");
        vm.prank(admin);
        vault.addApprovedRecipient(holder);
        vm.prank(ops);
        vault.mint(address(token), holder, 50 ether);
        vm.prank(admin);
        vault.removeApprovedRecipient(holder);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);

        vm.prank(ops);
        vm.expectRevert(IssuerVault.FromNotApproved.selector);
        vault.burn(address(token), holder, 20 ether);
        assertEq(token.balanceOf(holder), 50 ether);
    }

    function test_BurnFromSelf() public {
        vm.prank(ops);
        vault.mint(address(token), address(vault), 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(ops);
        vault.burn(address(token), address(vault), 30 ether);

        assertEq(token.balanceOf(address(vault)), 70 ether);
        assertEq(token.totalSupply(), supplyBefore - 30 ether);
    }

    function test_AdminCanWithdrawNative() public {
        vm.deal(address(vault), 1 ether);
        uint256 balBefore = admin.balance;

        vm.prank(admin);
        vault.withdraw(address(0));

        assertEq(address(vault).balance, 0);
        assertEq(admin.balance, balBefore + 1 ether);
    }

    function test_AdminCanWithdrawERC20() public {
        vm.prank(ops);
        vault.mint(address(token), address(vault), 100 ether);

        vm.prank(admin);
        vault.withdraw(address(token));

        assertEq(token.balanceOf(admin), 100 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_NonAdminCannotWithdraw() public {
        vm.prank(ops);
        vm.expectRevert();
        vault.withdraw(address(0));
    }

    function test_AdminCannotSelfGrant() public {
        vm.prank(admin);
        vm.expectRevert(IssuerVault.SelfGrantNotAllowed.selector);
        vault.grantRole(OPS_ROLE, admin);
    }

    function test_AdminCanGrantOpsToOthers() public {
        address newOps = makeAddr("newOps");
        vm.prank(admin);
        vault.grantRole(OPS_ROLE, newOps);
        assertTrue(vault.hasRole(OPS_ROLE, newOps));
    }

    function test_AdminCanRevokeOps() public {
        vm.prank(admin);
        vault.revokeRole(OPS_ROLE, ops);
        assertFalse(vault.hasRole(OPS_ROLE, ops));

        vm.prank(admin);
        vault.addApprovedRecipient(recipient1);
        vm.prank(ops);
        vm.expectRevert();
        vault.mint(address(token), recipient1, 1 ether);
    }
}
