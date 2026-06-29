// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {OperatorWallet} from "../src/OperatorWallet/OperatorWallet.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";
import {SecuritiesTokenFactory} from "../src/securitiesToken/SecuritiesTokenFactory.sol";
import {Compliance} from "../src/compliance/Compliance.sol";
import {PauseManager} from "../src/pauseManager/PauseManager.sol";

contract OperatorWalletTest is Test {
    OperatorWallet internal wallet;
    SecuritiesToken internal token;
    Compliance internal compliance;
    PauseManager internal pauseManager;
    SecuritiesTokenFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal ops = makeAddr("ops");
    address internal hotwallet1 = makeAddr("hotwallet1");
    address internal hotwallet2 = makeAddr("hotwallet2");
    address internal stranger = makeAddr("stranger");

    bytes32 internal OPS_ROLE;

    function setUp() public {
        vm.startPrank(admin);
        compliance = new Compliance(admin);
        pauseManager = new PauseManager(admin);
        factory = new SecuritiesTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin);
        address[] memory empty = new address[](0);
        token = SecuritiesToken(
            factory.deployToken("Apple Inc.", "AAPL", "US0378331005", admin, empty, empty)
        );

        // Deploy OperatorWallet behind a proxy (it's upgradeable).
        OperatorWallet impl = new OperatorWallet();
        bytes memory initData = abi.encodeWithSelector(OperatorWallet.initialize.selector, admin);
        wallet = OperatorWallet(payable(address(new ERC1967Proxy(address(impl), initData))));

        // Admin's only job: hand out roles. Self-grant guard blocks grant-to-self, so use `ops`.
        wallet.grantRole(wallet.OPS_ROLE(), ops);
        // Operator wallet needs ISSUER_ROLE on the token to mint.
        token.grantRole(token.ISSUER_ROLE(), address(wallet));
        // Compliance + PauseManager OPS not needed here — wallet doesn't manage those.
        vm.stopPrank();

        OPS_ROLE = wallet.OPS_ROLE();
    }

    // ═══════════════════════════════════════════════
    //                  Init / roles
    // ═══════════════════════════════════════════════

    function test_AdminHoldsDefaultAdminRole() public view {
        assertTrue(wallet.hasRole(0x00, admin));
    }

    function test_InitializerCannotBeCalledTwice() public {
        vm.expectRevert();
        wallet.initialize(admin);
    }

    function test_OpsHoldsOpsRole() public view {
        assertTrue(wallet.hasRole(OPS_ROLE, ops));
    }

    function test_StrangerHoldsNothing() public view {
        assertFalse(wallet.hasRole(0x00, stranger));
        assertFalse(wallet.hasRole(OPS_ROLE, stranger));
    }

    // ═══════════════════════════════════════════════
    //                  Hot wallets
    // ═══════════════════════════════════════════════

    function test_AdminCanAddHotWallet() public {
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);
        assertTrue(wallet.isHotWallet(hotwallet1));
        assertEq(wallet.numOfHotWallets(), 1);
    }

    function test_NonAdminCannotAddHotWallet() public {
        vm.prank(ops);
        vm.expectRevert();
        wallet.addHotWallet(hotwallet1);
    }

    function test_AddZeroHotWalletReverts() public {
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.ZeroAddress.selector);
        wallet.addHotWallet(address(0));
    }

    function test_AddDuplicateHotWalletReverts() public {
        vm.startPrank(admin);
        wallet.addHotWallet(hotwallet1);
        vm.expectRevert(OperatorWallet.HotWalletAlreadyExists.selector);
        wallet.addHotWallet(hotwallet1);
        vm.stopPrank();
    }

    function test_AddSelfAsHotWalletReverts() public {
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.CannotBeSelf.selector);
        wallet.addHotWallet(address(wallet));
    }

    function test_AdminCanRemoveHotWallet() public {
        vm.startPrank(admin);
        wallet.addHotWallet(hotwallet1);
        wallet.addHotWallet(hotwallet2);
        wallet.removeHotWallet(hotwallet1);
        vm.stopPrank();
        assertFalse(wallet.isHotWallet(hotwallet1));
        assertTrue(wallet.isHotWallet(hotwallet2));
        assertEq(wallet.numOfHotWallets(), 1);
    }

    function test_RemoveUnknownHotWalletReverts() public {
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.HotWalletNotFound.selector);
        wallet.removeHotWallet(hotwallet1);
    }

    // ═══════════════════════════════════════════════
    //                  Pause
    // ═══════════════════════════════════════════════

    function test_AdminCanPauseAndUnpause() public {
        vm.startPrank(admin);
        wallet.pause();
        vm.expectRevert();   // EnforcedPause
        wallet.addHotWallet(hotwallet1);
        wallet.unpause();
        wallet.addHotWallet(hotwallet1);
        vm.stopPrank();
        assertTrue(wallet.isHotWallet(hotwallet1));
    }

    function test_NonAdminCannotPause() public {
        vm.prank(ops);
        vm.expectRevert();
        wallet.pause();
    }

    // ═══════════════════════════════════════════════
    //                  Mint / transfer
    // ═══════════════════════════════════════════════

    function test_OpsCanMintToHotWallet() public {
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);

        vm.prank(ops);
        wallet.mint(address(token), hotwallet1, 100 ether);

        assertEq(token.balanceOf(hotwallet1), 100 ether);
        assertEq(token.balanceOf(address(wallet)), 0);
        assertEq(token.totalSupply(), 100 ether);
    }

    function test_MintEmitsMintedEvent() public {
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);

        vm.expectEmit(true, true, true, true, address(wallet));
        emit OperatorWallet.Minted(address(wallet), address(token), hotwallet1, 100 ether);

        vm.prank(ops);
        wallet.mint(address(token), hotwallet1, 100 ether);
    }

    function test_MintToSelfEmitsMintedEventWithWalletAsRecipient() public {
        vm.expectEmit(true, true, true, true, address(wallet));
        emit OperatorWallet.Minted(address(wallet), address(token), address(wallet), 50 ether);

        vm.prank(ops);
        wallet.mint(address(token), address(wallet), 50 ether);
    }

    function test_OpsCanMintToSelf() public {
        // recipient = address(wallet) → token stays on the wallet
        vm.prank(ops);
        wallet.mint(address(token), address(wallet), 50 ether);

        assertEq(token.balanceOf(address(wallet)), 50 ether);
        assertEq(token.totalSupply(), 50 ether);
    }

    function test_MintToNonHotWalletReverts() public {
        vm.prank(ops);
        vm.expectRevert(OperatorWallet.RecipientNotHotWallet.selector);
        wallet.mint(address(token), stranger, 1 ether);
    }

    function test_AdminCannotMint() public {
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);

        vm.prank(admin);
        vm.expectRevert();
        wallet.mint(address(token), hotwallet1, 1 ether);
    }

    function test_OpsCanTransfer() public {
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);

        // Pre-mint to self, then transfer to hot wallet
        vm.startPrank(ops);
        wallet.mint(address(token), address(wallet), 50 ether);
        wallet.transfer(address(token), hotwallet1, 30 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(hotwallet1), 30 ether);
        assertEq(token.balanceOf(address(wallet)), 20 ether);
    }

    function test_TransferToNonHotWalletReverts() public {
        vm.prank(ops);
        wallet.mint(address(token), address(wallet), 50 ether);

        vm.prank(ops);
        vm.expectRevert(OperatorWallet.RecipientNotHotWallet.selector);
        wallet.transfer(address(token), stranger, 1 ether);
    }

    function test_WalletWithoutIssuerRoleMintReverts() public {
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(wallet));
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);

        vm.prank(ops);
        vm.expectRevert(OperatorWallet.MissingIssuerRole.selector);
        wallet.mint(address(token), hotwallet1, 1 ether);
    }

    function test_MintIssuerRoleCheckRunsBeforeMintCall() public {
        // If we lack ISSUER_ROLE, the explicit check fires — not the token's internal
        // UnauthorizedRole. Verifies the pre-flight is properly placed.
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(wallet));
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(ops);
        vm.expectRevert(OperatorWallet.MissingIssuerRole.selector);
        wallet.mint(address(token), hotwallet1, 1 ether);
        assertEq(token.totalSupply(), supplyBefore);  // no state changed
    }

    // ═══════════════════════════════════════════════
    //                       Burn
    // ═══════════════════════════════════════════════

    /// Helper: mint tokens to hotwallet1 and have it approve the OperatorWallet
    /// so subsequent burn tests can pull from it.
    function _seedHotWalletForBurn() internal returns (uint256 minted) {
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);
        vm.prank(ops);
        wallet.mint(address(token), hotwallet1, 100 ether);
        vm.prank(hotwallet1);
        token.approve(address(wallet), type(uint256).max);
        minted = 100 ether;
    }

    function test_OpsCanBurn() public {
        _seedHotWalletForBurn();
        uint256 supplyBefore = token.totalSupply();

        vm.prank(ops);
        wallet.burn(address(token), hotwallet1, 40 ether);

        assertEq(token.balanceOf(hotwallet1), 60 ether);
        assertEq(token.balanceOf(address(wallet)), 0);  // wallet pulled then burned
        assertEq(token.totalSupply(), supplyBefore - 40 ether);
    }

    function test_BurnEmitsBurnedEvent() public {
        _seedHotWalletForBurn();

        vm.expectEmit(true, true, true, true, address(wallet));
        emit OperatorWallet.Burned(address(wallet), address(token), hotwallet1, 40 ether);

        vm.prank(ops);
        wallet.burn(address(token), hotwallet1, 40 ether);
    }

    function test_BurnFromSelfEmitsBurnedEventWithWalletAsFrom() public {
        vm.prank(ops);
        wallet.mint(address(token), address(wallet), 100 ether);

        vm.expectEmit(true, true, true, true, address(wallet));
        emit OperatorWallet.Burned(address(wallet), address(token), address(wallet), 30 ether);

        vm.prank(ops);
        wallet.burn(address(token), address(wallet), 30 ether);
    }

    function test_AdminCannotBurn() public {
        _seedHotWalletForBurn();
        vm.prank(admin);
        vm.expectRevert();
        wallet.burn(address(token), hotwallet1, 1 ether);
    }

    function test_StrangerCannotBurn() public {
        _seedHotWalletForBurn();
        vm.prank(stranger);
        vm.expectRevert();
        wallet.burn(address(token), hotwallet1, 1 ether);
    }

    function test_BurnWithoutApprovalReverts() public {
        // Mint to hotwallet1 but DO NOT approve the wallet
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);
        vm.prank(ops);
        wallet.mint(address(token), hotwallet1, 100 ether);

        vm.prank(ops);
        vm.expectRevert();  // ERC20 insufficient allowance
        wallet.burn(address(token), hotwallet1, 10 ether);
    }

    function test_BurnWithoutBalanceReverts() public {
        // hotwallet1 has 0 token balance but pre-approved
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);
        vm.prank(hotwallet1);
        token.approve(address(wallet), type(uint256).max);

        vm.prank(ops);
        vm.expectRevert();  // ERC20 insufficient balance
        wallet.burn(address(token), hotwallet1, 10 ether);
    }

    function test_WalletWithoutIssuerRoleBurnReverts() public {
        _seedHotWalletForBurn();
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(wallet));

        vm.prank(ops);
        vm.expectRevert(OperatorWallet.MissingIssuerRole.selector);
        wallet.burn(address(token), hotwallet1, 10 ether);
    }

    function test_BurnIssuerRoleCheckRunsBeforeTokenPull() public {
        _seedHotWalletForBurn();
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(wallet));

        uint256 holderBefore = token.balanceOf(hotwallet1);
        uint256 walletBefore = token.balanceOf(address(wallet));

        vm.prank(ops);
        vm.expectRevert(OperatorWallet.MissingIssuerRole.selector);
        wallet.burn(address(token), hotwallet1, 10 ether);

        // No token movement happened (transferFrom would have pulled from hotwallet1)
        assertEq(token.balanceOf(hotwallet1), holderBefore);
        assertEq(token.balanceOf(address(wallet)), walletBefore);
    }

    function test_BurnPausedWalletReverts() public {
        _seedHotWalletForBurn();
        vm.prank(admin);
        wallet.pause();

        vm.prank(ops);
        vm.expectRevert();  // EnforcedPause from PausableUpgradeable
        wallet.burn(address(token), hotwallet1, 1 ether);
    }

    function test_BurnDisabledOnTokenReverts() public {
        _seedHotWalletForBurn();
        vm.prank(admin);
        token.setBurnEnabled(false);

        vm.prank(ops);
        vm.expectRevert(SecuritiesToken.BurnDisabled.selector);
        wallet.burn(address(token), hotwallet1, 1 ether);
    }

    function test_BurnFromNonHotWalletReverts() public {
        // burn() now requires `from` to be self OR a hot wallet — burning from an
        // arbitrary holder is explicitly disallowed.
        address holder = makeAddr("ordinaryHolder");
        vm.prank(admin);
        wallet.addHotWallet(holder);
        vm.prank(ops);
        wallet.mint(address(token), holder, 50 ether);
        vm.prank(admin);
        wallet.removeHotWallet(holder);  // no longer a hot wallet
        vm.prank(holder);
        token.approve(address(wallet), type(uint256).max);

        vm.prank(ops);
        vm.expectRevert(OperatorWallet.FromNotHotWallet.selector);
        wallet.burn(address(token), holder, 20 ether);
        // Holder's tokens untouched
        assertEq(token.balanceOf(holder), 50 ether);
    }

    function test_BurnFromSelf() public {
        // When from == address(this), burn() skips the transferFrom step and burns
        // tokens already held by the wallet directly. Verifies the self path works.
        vm.prank(ops);
        wallet.mint(address(token), address(wallet), 100 ether);
        assertEq(token.balanceOf(address(wallet)), 100 ether);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(ops);
        wallet.burn(address(token), address(wallet), 30 ether);

        assertEq(token.balanceOf(address(wallet)), 70 ether);
        assertEq(token.totalSupply(), supplyBefore - 30 ether);
    }

    // ═══════════════════════════════════════════════
    //                  Withdraw
    // ═══════════════════════════════════════════════

    function test_AdminCanWithdrawNative() public {
        vm.deal(address(wallet), 1 ether);
        uint256 balBefore = admin.balance;

        vm.prank(admin);
        wallet.withdraw(address(0));

        assertEq(address(wallet).balance, 0);
        assertEq(admin.balance, balBefore + 1 ether);
    }

    function test_AdminCanWithdrawERC20() public {
        vm.prank(ops);
        wallet.mint(address(token), address(wallet), 100 ether);

        vm.prank(admin);
        wallet.withdraw(address(token));

        assertEq(token.balanceOf(admin), 100 ether);
        assertEq(token.balanceOf(address(wallet)), 0);
    }

    function test_NonAdminCannotWithdraw() public {
        vm.prank(ops);
        vm.expectRevert();
        wallet.withdraw(address(0));
    }

    // ═══════════════════════════════════════════════
    //                  Self-grant guard
    // ═══════════════════════════════════════════════

    function test_AdminCannotSelfGrant() public {
        vm.prank(admin);
        vm.expectRevert(OperatorWallet.SelfGrantNotAllowed.selector);
        wallet.grantRole(OPS_ROLE, admin);
    }

    function test_AdminCanGrantOpsToOthers() public {
        address newOps = makeAddr("newOps");
        vm.prank(admin);
        wallet.grantRole(OPS_ROLE, newOps);
        assertTrue(wallet.hasRole(OPS_ROLE, newOps));
    }

    function test_AdminCanRevokeOps() public {
        vm.prank(admin);
        wallet.revokeRole(OPS_ROLE, ops);
        assertFalse(wallet.hasRole(OPS_ROLE, ops));

        // ops can no longer mint
        vm.prank(admin);
        wallet.addHotWallet(hotwallet1);
        vm.prank(ops);
        vm.expectRevert();
        wallet.mint(address(token), hotwallet1, 1 ether);
    }
}
