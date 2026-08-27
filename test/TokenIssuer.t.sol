// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TokenIssuer} from "../src/tokenIssuer/TokenIssuer.sol";
import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../src/pauseRegistry/PauseRegistry.sol";

contract TokenIssuerTest is Test {
    TokenIssuer internal issuer;
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
    address internal tokenOps = makeAddr("tokenOps");

    bytes32 internal OPS_ROLE;

    /// @dev Factory is deployed behind an ERC1967Proxy in tests (production uses
    ///      TransparentUpgradeableProxy — see Deploy.s.sol) so tests can call implementation
    ///      functions directly without the transparent-admin caller restriction.
    function _deployFactory(uint256 minMultiplierNotice) internal returns (ScaledTokenFactory) {
        ScaledTokenFactory impl = new ScaledTokenFactory();
        bytes memory initData = abi.encodeWithSelector(
            ScaledTokenFactory.initialize.selector,
            address(compliance),
            address(pauseManager),
            admin,
            proxyAdmin,
            minMultiplierNotice
        );
        return ScaledTokenFactory(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    function setUp() public {
        vm.startPrank(admin);
        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = _deployFactory(24 hours);
        // Factory self-grant is blocked, so admin delegates factory OPS to the test contract.
        factory.grantRole(factory.OPS_ROLE(), address(this));
        vm.stopPrank();

        address[] memory empty = new address[](0);
        token = ScaledToken(factory.createToken("Apple Inc.", "AAPL", "US0378331005", admin, empty, empty, empty));

        vm.startPrank(admin);
        token.grantRole(token.OPS_ROLE(), tokenOps); // token metadata / mint-burn switches

        TokenIssuer impl = new TokenIssuer();
        bytes memory initData = abi.encodeWithSelector(TokenIssuer.initialize.selector, admin);
        issuer = TokenIssuer(payable(address(new ERC1967Proxy(address(impl), initData))));

        // Admin's only job: hand out roles. Self-grant guard blocks grant-to-self, so use `ops`.
        issuer.grantRole(issuer.OPS_ROLE(), ops);
        // Issuer needs ISSUER_ROLE on the token to mint.
        token.grantRole(token.ISSUER_ROLE(), address(issuer));
        vm.stopPrank();

        OPS_ROLE = issuer.OPS_ROLE();
    }

    function test_AdminHoldsDefaultAdminRole() public view {
        assertTrue(issuer.hasRole(0x00, admin));
    }

    function test_InitializerCannotBeCalledTwice() public {
        vm.expectRevert();
        issuer.initialize(admin);
    }

    function test_OpsHoldsOpsRole() public view {
        assertTrue(issuer.hasRole(OPS_ROLE, ops));
    }

    function test_StrangerHoldsNothing() public view {
        assertFalse(issuer.hasRole(0x00, stranger));
        assertFalse(issuer.hasRole(OPS_ROLE, stranger));
    }

    function test_AdminCanAddApprovedRecipient() public {
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);
        assertTrue(issuer.isApprovedRecipient(recipient1));
        assertEq(issuer.numApprovedRecipients(), 1);
    }

    function test_NonAdminCannotAddApprovedRecipient() public {
        vm.prank(ops);
        vm.expectRevert();
        issuer.addApprovedRecipient(recipient1);
    }

    function test_AddZeroApprovedRecipientReverts() public {
        vm.prank(admin);
        vm.expectRevert(TokenIssuer.ZeroAddress.selector);
        issuer.addApprovedRecipient(address(0));
    }

    function test_AddDuplicateApprovedRecipientReverts() public {
        vm.startPrank(admin);
        issuer.addApprovedRecipient(recipient1);
        vm.expectRevert(TokenIssuer.RecipientAlreadyApproved.selector);
        issuer.addApprovedRecipient(recipient1);
        vm.stopPrank();
    }

    function test_AddSelfAsApprovedRecipientReverts() public {
        vm.prank(admin);
        vm.expectRevert(TokenIssuer.CannotBeSelf.selector);
        issuer.addApprovedRecipient(address(issuer));
    }

    function test_AdminCanRemoveApprovedRecipient() public {
        vm.startPrank(admin);
        issuer.addApprovedRecipient(recipient1);
        issuer.addApprovedRecipient(recipient2);
        issuer.removeApprovedRecipient(recipient1);
        vm.stopPrank();
        assertFalse(issuer.isApprovedRecipient(recipient1));
        assertTrue(issuer.isApprovedRecipient(recipient2));
        assertEq(issuer.numApprovedRecipients(), 1);
    }

    function test_RemoveUnknownApprovedRecipientReverts() public {
        vm.prank(admin);
        vm.expectRevert(TokenIssuer.RecipientNotApproved.selector);
        issuer.removeApprovedRecipient(recipient1);
    }

    function test_AdminCanPauseAndUnpause() public {
        vm.startPrank(admin);
        issuer.pause();
        vm.expectRevert();
        issuer.addApprovedRecipient(recipient1);
        issuer.unpause();
        issuer.addApprovedRecipient(recipient1);
        vm.stopPrank();
        assertTrue(issuer.isApprovedRecipient(recipient1));
    }

    function test_NonAdminCannotPause() public {
        vm.prank(ops);
        vm.expectRevert();
        issuer.pause();
    }

    function test_OpsCanMintToApprovedRecipient() public {
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);

        vm.prank(ops);
        issuer.mint(address(token), recipient1, 100 ether);

        assertEq(token.balanceOf(recipient1), 100 ether);
        assertEq(token.balanceOf(address(issuer)), 0);
        assertEq(token.totalSupply(), 100 ether);
    }

    function test_MintEmitsMintedEvent() public {
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);

        vm.expectEmit(true, true, true, true, address(issuer));
        emit TokenIssuer.Minted(address(issuer), address(token), recipient1, 100 ether);

        vm.prank(ops);
        issuer.mint(address(token), recipient1, 100 ether);
    }

    function test_MintToSelfEmitsMintedEventWithIssuerAsRecipient() public {
        vm.expectEmit(true, true, true, true, address(issuer));
        emit TokenIssuer.Minted(address(issuer), address(token), address(issuer), 50 ether);

        vm.prank(ops);
        issuer.mint(address(token), address(issuer), 50 ether);
    }

    function test_OpsCanMintToSelf() public {
        vm.prank(ops);
        issuer.mint(address(token), address(issuer), 50 ether);

        assertEq(token.balanceOf(address(issuer)), 50 ether);
        assertEq(token.totalSupply(), 50 ether);
    }

    function test_MintToUnapprovedRecipientReverts() public {
        vm.prank(ops);
        vm.expectRevert(TokenIssuer.RecipientNotApproved.selector);
        issuer.mint(address(token), stranger, 1 ether);
    }

    function test_AdminCannotMint() public {
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);

        vm.prank(admin);
        vm.expectRevert();
        issuer.mint(address(token), recipient1, 1 ether);
    }

    function test_OpsCanTransfer() public {
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);

        vm.startPrank(ops);
        issuer.mint(address(token), address(issuer), 50 ether);
        issuer.transfer(address(token), recipient1, 30 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(recipient1), 30 ether);
        assertEq(token.balanceOf(address(issuer)), 20 ether);
    }

    function test_TransferEmitsTransferredEvent() public {
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);

        vm.prank(ops);
        issuer.mint(address(token), address(issuer), 50 ether);

        vm.expectEmit(true, true, true, true, address(issuer));
        emit TokenIssuer.Transferred(address(issuer), address(token), recipient1, 30 ether);
        vm.prank(ops);
        issuer.transfer(address(token), recipient1, 30 ether);
    }

    function test_TransferToUnapprovedRecipientReverts() public {
        vm.prank(ops);
        issuer.mint(address(token), address(issuer), 50 ether);

        vm.prank(ops);
        vm.expectRevert(TokenIssuer.RecipientNotApproved.selector);
        issuer.transfer(address(token), stranger, 1 ether);
    }

    function test_IssuerWithoutRoleMintReverts() public {
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(issuer));
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);

        vm.prank(ops);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        issuer.mint(address(token), recipient1, 1 ether);
    }

    /// @dev Without ISSUER_ROLE, ScaledToken.mint reverts inside the nested call and the
    ///      entire outer transaction rolls back — no supply / balance change.
    function test_MintRevertsAtomicallyWithoutIssuerRole() public {
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(issuer));
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(ops);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        issuer.mint(address(token), recipient1, 1 ether);
        assertEq(token.totalSupply(), supplyBefore);
    }

    /// Helper: mint tokens to recipient1 and have it approve the issuer so subsequent
    /// burn tests can pull from it.
    function _seedRecipientForBurn() internal returns (uint256 minted) {
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);
        vm.prank(ops);
        issuer.mint(address(token), recipient1, 100 ether);
        vm.prank(recipient1);
        token.approve(address(issuer), type(uint256).max);
        minted = 100 ether;
    }

    function test_OpsCanBurn() public {
        _seedRecipientForBurn();
        uint256 supplyBefore = token.totalSupply();

        vm.prank(ops);
        issuer.burn(address(token), recipient1, 40 ether);

        assertEq(token.balanceOf(recipient1), 60 ether);
        assertEq(token.balanceOf(address(issuer)), 0);
        assertEq(token.totalSupply(), supplyBefore - 40 ether);
    }

    function test_BurnEmitsBurnedEvent() public {
        _seedRecipientForBurn();

        vm.expectEmit(true, true, true, true, address(issuer));
        emit TokenIssuer.Burned(address(issuer), address(token), recipient1, 40 ether);

        vm.prank(ops);
        issuer.burn(address(token), recipient1, 40 ether);
    }

    function test_BurnFromSelfEmitsBurnedEventWithIssuerAsFrom() public {
        vm.prank(ops);
        issuer.mint(address(token), address(issuer), 100 ether);

        vm.expectEmit(true, true, true, true, address(issuer));
        emit TokenIssuer.Burned(address(issuer), address(token), address(issuer), 30 ether);

        vm.prank(ops);
        issuer.burn(address(token), address(issuer), 30 ether);
    }

    function test_AdminCannotBurn() public {
        _seedRecipientForBurn();
        vm.prank(admin);
        vm.expectRevert();
        issuer.burn(address(token), recipient1, 1 ether);
    }

    function test_StrangerCannotBurn() public {
        _seedRecipientForBurn();
        vm.prank(stranger);
        vm.expectRevert();
        issuer.burn(address(token), recipient1, 1 ether);
    }

    function test_BurnWithoutApprovalReverts() public {
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);
        vm.prank(ops);
        issuer.mint(address(token), recipient1, 100 ether);

        vm.prank(ops);
        vm.expectRevert();
        issuer.burn(address(token), recipient1, 10 ether);
    }

    function test_BurnWithoutBalanceReverts() public {
        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);
        vm.prank(recipient1);
        token.approve(address(issuer), type(uint256).max);

        vm.prank(ops);
        vm.expectRevert();
        issuer.burn(address(token), recipient1, 10 ether);
    }

    function test_IssuerWithoutRoleBurnReverts() public {
        _seedRecipientForBurn();
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(issuer));

        vm.prank(ops);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        issuer.burn(address(token), recipient1, 10 ether);
    }

    /// @dev Without ISSUER_ROLE, the token.burn nested call reverts and the outer tx
    ///      rolls back, so the pulled tokens are restored and supply is unchanged.
    function test_BurnRevertsAtomicallyWithoutIssuerRole() public {
        _seedRecipientForBurn();
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(issuer));

        uint256 holderBefore = token.balanceOf(recipient1);
        uint256 issuerBefore = token.balanceOf(address(issuer));

        vm.prank(ops);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        issuer.burn(address(token), recipient1, 10 ether);

        assertEq(token.balanceOf(recipient1), holderBefore);
        assertEq(token.balanceOf(address(issuer)), issuerBefore);
    }

    function test_BurnPausedIssuerReverts() public {
        _seedRecipientForBurn();
        vm.prank(admin);
        issuer.pause();

        vm.prank(ops);
        vm.expectRevert();
        issuer.burn(address(token), recipient1, 1 ether);
    }

    function test_BurnNotAllowedOnTokenReverts() public {
        _seedRecipientForBurn();
        vm.prank(tokenOps);
        token.setBurnAllowed(false);

        vm.prank(ops);
        vm.expectRevert(ScaledToken.BurnNotAllowed.selector);
        issuer.burn(address(token), recipient1, 1 ether);
    }

    function test_BurnFromUnapprovedRecipientReverts() public {
        address holder = makeAddr("ordinaryHolder");
        vm.prank(admin);
        issuer.addApprovedRecipient(holder);
        vm.prank(ops);
        issuer.mint(address(token), holder, 50 ether);
        vm.prank(admin);
        issuer.removeApprovedRecipient(holder);
        vm.prank(holder);
        token.approve(address(issuer), type(uint256).max);

        vm.prank(ops);
        vm.expectRevert(TokenIssuer.FromNotApproved.selector);
        issuer.burn(address(token), holder, 20 ether);
        assertEq(token.balanceOf(holder), 50 ether);
    }

    function test_BurnFromSelf() public {
        vm.prank(ops);
        issuer.mint(address(token), address(issuer), 100 ether);
        assertEq(token.balanceOf(address(issuer)), 100 ether);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(ops);
        issuer.burn(address(token), address(issuer), 30 ether);

        assertEq(token.balanceOf(address(issuer)), 70 ether);
        assertEq(token.totalSupply(), supplyBefore - 30 ether);
    }

    function test_AdminCanWithdrawERC20() public {
        vm.prank(ops);
        issuer.mint(address(token), address(issuer), 100 ether);

        vm.prank(admin);
        issuer.withdraw(address(token));

        assertEq(token.balanceOf(admin), 100 ether);
        assertEq(token.balanceOf(address(issuer)), 0);
    }

    function test_NonAdminCannotWithdraw() public {
        vm.prank(ops);
        vm.expectRevert();
        issuer.withdraw(address(token));
    }

    function test_WithdrawRejectsZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(TokenIssuer.ZeroAddress.selector);
        issuer.withdraw(address(0));
    }

    function test_IssuerDoesNotAcceptNative() public {
        // TokenIssuer intentionally omits receive() — plain native sends must revert.
        vm.deal(address(this), 1 ether);
        (bool ok,) = payable(address(issuer)).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(issuer).balance, 0);
    }

    function test_AdminCannotSelfGrant() public {
        vm.prank(admin);
        vm.expectRevert(TokenIssuer.SelfGrantNotAllowed.selector);
        issuer.grantRole(OPS_ROLE, admin);
    }

    function test_AdminCanGrantOpsToOthers() public {
        address newOps = makeAddr("newOps");
        vm.prank(admin);
        issuer.grantRole(OPS_ROLE, newOps);
        assertTrue(issuer.hasRole(OPS_ROLE, newOps));
    }

    function test_AdminCanRevokeOps() public {
        vm.prank(admin);
        issuer.revokeRole(OPS_ROLE, ops);
        assertFalse(issuer.hasRole(OPS_ROLE, ops));

        vm.prank(admin);
        issuer.addApprovedRecipient(recipient1);
        vm.prank(ops);
        vm.expectRevert();
        issuer.mint(address(token), recipient1, 1 ether);
    }

    function test_LastAdminCannotRenounce() public {
        vm.prank(admin);
        vm.expectRevert(TokenIssuer.CannotRenounceLastAdmin.selector);
        issuer.renounceRole(0x00, admin);
    }

    function test_NonLastAdminCanRenounce() public {
        vm.prank(admin);
        issuer.grantRole(0x00, stranger);

        vm.prank(admin);
        issuer.renounceRole(0x00, admin);

        assertFalse(issuer.hasRole(0x00, admin));
        assertTrue(issuer.hasRole(0x00, stranger));
    }
}
