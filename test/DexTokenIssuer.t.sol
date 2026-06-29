// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {DexTokenIssuer} from "../src/tokenIssuer/DexTokenIssuer.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";
import {SecuritiesTokenFactory} from "../src/securitiesToken/SecuritiesTokenFactory.sol";
import {Compliance} from "../src/compliance/Compliance.sol";
import {PauseManager} from "../src/pauseManager/PauseManager.sol";

/// In-memory stablecoin (no permit needed anymore; kept ERC20Permit for symmetry).
contract MockStable is ERC20, ERC20Permit {
    constructor() ERC20("Mock USD", "mUSD") ERC20Permit("Mock USD") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract DexTokenIssuerTest is Test {
    DexTokenIssuer internal op;
    MockStable internal stable;
    SecuritiesToken internal token;
    Compliance internal compliance;
    PauseManager internal pauseManager;
    SecuritiesTokenFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal ops = makeAddr("ops");
    address internal complianceOps = makeAddr("complianceOps");
    address internal pauseOps = makeAddr("pauseOps");
    address internal treasury = makeAddr("treasury");

    // alice = end user. Real wallet (private key known) so she could sign permit
    // (though purchase/sell don't take permit anymore — kept for compatibility).
    Vm.Wallet internal aliceWallet;
    address internal alice;

    // broker wallet whose private key signs all order EIP-712 digests in these tests.
    Vm.Wallet internal brokerWallet;
    address internal broker;

    bytes32 internal constant DISCLOSURE = keccak256("PROSPECTUS_v1");

    function setUp() public {
        aliceWallet = vm.createWallet("alice");
        alice = aliceWallet.addr;
        brokerWallet = vm.createWallet("broker");
        broker = brokerWallet.addr;

        vm.startPrank(admin);
        compliance = new Compliance(admin);
        pauseManager = new PauseManager(admin);
        factory = new SecuritiesTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin);
        address[] memory empty = new address[](0);
        token = SecuritiesToken(
            factory.deployToken("Apple Inc.", "AAPL", "US0378331005", admin, empty, empty)
        );

        op = new DexTokenIssuer(admin, treasury);
        op.grantRole(op.OPS_ROLE(), ops);
        op.grantRole(op.BROKER_ADMIN_ROLE(), broker);

        stable = new MockStable();
        op.setApprovedStable(address(stable), true);
        op.setApprovedToken(address(token), true);

        token.grantRole(token.ISSUER_ROLE(), address(op));
        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        pauseManager.grantRole(pauseManager.OPS_ROLE(), pauseOps);
        vm.stopPrank();

        // Alice pre-approves DexTokenIssuer for the stablecoin (purchase path)
        stable.mint(alice, 10_000 ether);
        vm.prank(alice);
        stable.approve(address(op), type(uint256).max);
    }

    // ═══════════════════════════════════════════════
    //              Order helpers
    // ═══════════════════════════════════════════════

    /// Build + sign a PurchaseOrder with the current alice nonce.
    function _purchaseOrder(uint256 stableAmount, uint256 tokenAmount)
        internal
        view
        returns (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig)
    {
        order = DexTokenIssuer.PurchaseOrder({
            user: alice,
            stable: address(stable),
            stableAmount: stableAmount,
            token: address(token),
            tokenAmount: tokenAmount,
            disclosureHash: DISCLOSURE,
            nonce: op.orderNonces(alice),
            deadline: block.timestamp + 1 hours
        });
        sig = _signPurchaseOrder(order, brokerWallet.privateKey);
    }

    function _sellOrder(uint256 tokenAmount, uint256 stableAmount)
        internal
        view
        returns (DexTokenIssuer.SellOrder memory order, bytes memory sig)
    {
        order = DexTokenIssuer.SellOrder({
            user: alice,
            token: address(token),
            tokenAmount: tokenAmount,
            stable: address(stable),
            stableAmount: stableAmount,
            disclosureHash: DISCLOSURE,
            nonce: op.orderNonces(alice),
            deadline: block.timestamp + 1 hours
        });
        sig = _signSellOrder(order, brokerWallet.privateKey);
    }

    function _signPurchaseOrder(DexTokenIssuer.PurchaseOrder memory order, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 PURCHASE_ORDER_TYPEHASH = keccak256(
            "PurchaseOrder(address user,address stable,uint256 stableAmount,address token,uint256 tokenAmount,bytes32 disclosureHash,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(
            PURCHASE_ORDER_TYPEHASH,
            order.user, order.stable, order.stableAmount,
            order.token, order.tokenAmount,
            order.disclosureHash, order.nonce, order.deadline
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(op.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSellOrder(DexTokenIssuer.SellOrder memory order, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 SELL_ORDER_TYPEHASH = keccak256(
            "SellOrder(address user,address token,uint256 tokenAmount,address stable,uint256 stableAmount,bytes32 disclosureHash,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(
            SELL_ORDER_TYPEHASH,
            order.user, order.token, order.tokenAmount,
            order.stable, order.stableAmount,
            order.disclosureHash, order.nonce, order.deadline
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(op.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ═══════════════════════════════════════════════
    //              Purchase — happy path
    // ═══════════════════════════════════════════════

    function test_PurchaseHappyPath() public {
        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);

        vm.prank(ops);
        op.purchase(order, sig);

        assertEq(stable.balanceOf(alice), 9_900 ether);
        assertEq(stable.balanceOf(treasury), 100 ether);
        assertEq(token.balanceOf(alice), 50 ether);
        assertEq(op.orderNonces(alice), 1);
    }

    function test_PurchaseEmitsPurchasedEvent() public {
        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);

        vm.expectEmit(true, true, true, true, address(op));
        emit DexTokenIssuer.Purchased(
            address(op), alice, address(token),
            address(stable), 100 ether, 50 ether,
            DISCLOSURE, 0, broker
        );
        vm.prank(ops);
        op.purchase(order, sig);
    }

    function test_PurchaseSequentialNonces() public {
        for (uint256 i = 0; i < 3; i++) {
            (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) =
                _purchaseOrder(10 ether, 5 ether);
            vm.prank(ops);
            op.purchase(order, sig);
        }
        assertEq(op.orderNonces(alice), 3);
        assertEq(token.balanceOf(alice), 15 ether);
    }

    // ═══════════════════════════════════════════════
    //         Purchase — permission / role checks
    // ═══════════════════════════════════════════════

    function test_NonOpsCannotPurchase() public {
        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);
        vm.prank(alice);
        vm.expectRevert();
        op.purchase(order, sig);
    }

    function test_AdminCannotPurchase() public {
        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);
        vm.prank(admin);
        vm.expectRevert();
        op.purchase(order, sig);
    }

    function test_AdminCannotSelfGrantOps() public {
        bytes32 opsRole = op.OPS_ROLE();
        vm.prank(admin);
        vm.expectRevert(DexTokenIssuer.SelfGrantNotAllowed.selector);
        op.grantRole(opsRole, admin);
    }

    function test_AdminCannotSelfGrantBrokerAdmin() public {
        bytes32 brokerRole = op.BROKER_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(DexTokenIssuer.SelfGrantNotAllowed.selector);
        op.grantRole(brokerRole, admin);
    }

    // ═══════════════════════════════════════════════
    //         Purchase — broker signature checks
    // ═══════════════════════════════════════════════

    function test_PurchaseWrongSignerReverts() public {
        Vm.Wallet memory imposter = vm.createWallet("imposter");
        (DexTokenIssuer.PurchaseOrder memory order,) = _purchaseOrder(100 ether, 50 ether);
        bytes memory badSig = _signPurchaseOrder(order, imposter.privateKey);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.InvalidBrokerSignature.selector);
        op.purchase(order, badSig);
    }

    function test_PurchaseExpiredDeadlineReverts() public {
        (DexTokenIssuer.PurchaseOrder memory order,) = _purchaseOrder(100 ether, 50 ether);
        order.deadline = block.timestamp - 1;
        bytes memory sig = _signPurchaseOrder(order, brokerWallet.privateKey);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.OrderExpired.selector);
        op.purchase(order, sig);
    }

    function test_PurchaseWrongNonceReverts() public {
        (DexTokenIssuer.PurchaseOrder memory order,) = _purchaseOrder(100 ether, 50 ether);
        order.nonce = 7;     // user's current nonce is 0
        bytes memory sig = _signPurchaseOrder(order, brokerWallet.privateKey);

        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(DexTokenIssuer.OrderNonceMismatch.selector, 0, 7));
        op.purchase(order, sig);
    }

    function test_PurchaseReplayReverts() public {
        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);

        vm.prank(ops);
        op.purchase(order, sig);

        // Re-submit: nonce now 1, order's nonce 0 → mismatch
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(DexTokenIssuer.OrderNonceMismatch.selector, 1, 0));
        op.purchase(order, sig);
    }

    // ═══════════════════════════════════════════════
    //         Purchase — input validation
    // ═══════════════════════════════════════════════

    function test_PurchaseZeroUserReverts() public {
        (DexTokenIssuer.PurchaseOrder memory order,) = _purchaseOrder(100 ether, 50 ether);
        order.user = address(0);
        bytes memory sig = _signPurchaseOrder(order, brokerWallet.privateKey);

        vm.prank(ops);
        // Nonce check happens before zero-address check — order's nonce reads
        // orderNonces[address(0)] = 0, which matches order.nonce = 0 (from before mutating user).
        // So we hit ZeroAddress in _purchase.
        vm.expectRevert(DexTokenIssuer.ZeroAddress.selector);
        op.purchase(order, sig);
    }

    function test_PurchaseZeroStableAmountReverts() public {
        (DexTokenIssuer.PurchaseOrder memory order,) = _purchaseOrder(0, 50 ether);
        bytes memory sig = _signPurchaseOrder(order, brokerWallet.privateKey);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.ZeroAmount.selector);
        op.purchase(order, sig);
    }

    function test_PurchaseZeroTokenAmountReverts() public {
        (DexTokenIssuer.PurchaseOrder memory order,) = _purchaseOrder(100 ether, 0);
        bytes memory sig = _signPurchaseOrder(order, brokerWallet.privateKey);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.ZeroAmount.selector);
        op.purchase(order, sig);
    }

    function test_PurchaseRejectsNonWhitelistedStable() public {
        MockStable rogue = new MockStable();
        (DexTokenIssuer.PurchaseOrder memory order,) = _purchaseOrder(100 ether, 50 ether);
        order.stable = address(rogue);
        bytes memory sig = _signPurchaseOrder(order, brokerWallet.privateKey);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.NotApprovedStable.selector);
        op.purchase(order, sig);
    }

    function test_PurchaseRejectsNonWhitelistedToken() public {
        vm.startPrank(admin);
        address[] memory empty = new address[](0);
        address otherToken = factory.deployToken("Tesla Inc.", "TSLA", "US88160R1014", admin, empty, empty);
        vm.stopPrank();
        (DexTokenIssuer.PurchaseOrder memory order,) = _purchaseOrder(100 ether, 50 ether);
        order.token = otherToken;
        bytes memory sig = _signPurchaseOrder(order, brokerWallet.privateKey);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.NotApprovedToken.selector);
        op.purchase(order, sig);
    }

    function test_PurchaseTreasuryNotSetReverts() public {
        vm.startPrank(admin);
        DexTokenIssuer op2 = new DexTokenIssuer(admin, address(0));
        op2.grantRole(op2.OPS_ROLE(), ops);
        op2.grantRole(op2.BROKER_ADMIN_ROLE(), broker);
        op2.setApprovedStable(address(stable), true);
        op2.setApprovedToken(address(token), true);
        token.grantRole(token.ISSUER_ROLE(), address(op2));
        vm.stopPrank();

        // Sign against op2's domain
        DexTokenIssuer.PurchaseOrder memory order = DexTokenIssuer.PurchaseOrder({
            user: alice, stable: address(stable), stableAmount: 100 ether,
            token: address(token), tokenAmount: 50 ether,
            disclosureHash: DISCLOSURE, nonce: 0, deadline: block.timestamp + 1 hours
        });
        bytes32 PURCHASE_ORDER_TYPEHASH = keccak256(
            "PurchaseOrder(address user,address stable,uint256 stableAmount,address token,uint256 tokenAmount,bytes32 disclosureHash,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(
            PURCHASE_ORDER_TYPEHASH,
            order.user, order.stable, order.stableAmount,
            order.token, order.tokenAmount,
            order.disclosureHash, order.nonce, order.deadline
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(op2.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(brokerWallet.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        stable.approve(address(op2), type(uint256).max);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.TreasuryNotSet.selector);
        op2.purchase(order, sig);
    }

    function test_PurchaseInsufficientApprovalReverts() public {
        address bob = makeAddr("bob");
        stable.mint(bob, 1_000 ether);
        // bob has NOT pre-approved DexTokenIssuer
        DexTokenIssuer.PurchaseOrder memory order = DexTokenIssuer.PurchaseOrder({
            user: bob, stable: address(stable), stableAmount: 100 ether,
            token: address(token), tokenAmount: 50 ether,
            disclosureHash: DISCLOSURE, nonce: 0, deadline: block.timestamp + 1 hours
        });
        bytes memory sig = _signPurchaseOrder(order, brokerWallet.privateKey);

        vm.prank(ops);
        vm.expectRevert();   // ERC20InsufficientAllowance
        op.purchase(order, sig);
    }

    function test_PurchaseBlockedUserReverts() public {
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), list);

        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);

        vm.prank(ops);
        vm.expectRevert(Compliance.UserBlocked.selector);
        op.purchase(order, sig);
    }

    function test_PurchasePausedTokenReverts() public {
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);

        vm.prank(ops);
        vm.expectRevert();   // TokenPaused
        op.purchase(order, sig);
    }

    function test_PurchaseDexTokenIssuerWithoutIssuerRoleReverts() public {
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(op));

        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.MissingIssuerRole.selector);
        op.purchase(order, sig);
    }

    // ═══════════════════════════════════════════════
    //              Sell — happy path + checks
    // ═══════════════════════════════════════════════

    /// Set up: alice owns 50 token (via a purchase) + alice approved op for token
    /// + treasury approved op for stable.
    function _setupForSell() internal {
        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);
        vm.prank(ops);
        op.purchase(order, sig);

        vm.prank(alice);
        token.approve(address(op), type(uint256).max);
        vm.prank(treasury);
        stable.approve(address(op), type(uint256).max);
    }

    function test_SellHappyPath() public {
        _setupForSell();
        (DexTokenIssuer.SellOrder memory order, bytes memory sig) = _sellOrder(20 ether, 40 ether);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(ops);
        op.sell(order, sig);

        assertEq(token.balanceOf(alice), 30 ether);
        assertEq(token.totalSupply(), supplyBefore - 20 ether);
        assertEq(stable.balanceOf(alice), 9_900 ether + 40 ether);
        assertEq(op.orderNonces(alice), 2);  // 1 from purchase + 1 from sell
    }

    function test_SellEmitsSoldEvent() public {
        _setupForSell();
        (DexTokenIssuer.SellOrder memory order, bytes memory sig) = _sellOrder(20 ether, 40 ether);

        vm.expectEmit(true, true, true, true, address(op));
        emit DexTokenIssuer.Sold(
            address(op), alice, address(token),
            address(stable), 20 ether, 40 ether,
            DISCLOSURE, op.orderNonces(alice), broker
        );
        vm.prank(ops);
        op.sell(order, sig);
    }

    function test_NonOpsCannotSell() public {
        _setupForSell();
        (DexTokenIssuer.SellOrder memory order, bytes memory sig) = _sellOrder(20 ether, 40 ether);
        vm.prank(alice);
        vm.expectRevert();
        op.sell(order, sig);
    }

    function test_SellWrongSignerReverts() public {
        _setupForSell();
        Vm.Wallet memory imposter = vm.createWallet("imposter");
        (DexTokenIssuer.SellOrder memory order,) = _sellOrder(20 ether, 40 ether);
        bytes memory badSig = _signSellOrder(order, imposter.privateKey);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.InvalidBrokerSignature.selector);
        op.sell(order, badSig);
    }

    function test_SellExpiredDeadlineReverts() public {
        _setupForSell();
        (DexTokenIssuer.SellOrder memory order,) = _sellOrder(20 ether, 40 ether);
        order.deadline = block.timestamp - 1;
        bytes memory sig = _signSellOrder(order, brokerWallet.privateKey);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.OrderExpired.selector);
        op.sell(order, sig);
    }

    function test_SellInsufficientApprovalReverts() public {
        // Skip user-side token.approve
        (DexTokenIssuer.PurchaseOrder memory purchaseO, bytes memory purchaseSig) =
            _purchaseOrder(100 ether, 50 ether);
        vm.prank(ops);
        op.purchase(purchaseO, purchaseSig);
        vm.prank(treasury);
        stable.approve(address(op), type(uint256).max);

        (DexTokenIssuer.SellOrder memory order, bytes memory sig) = _sellOrder(20 ether, 40 ether);

        vm.prank(ops);
        vm.expectRevert();   // ERC20InsufficientAllowance from token.transferFrom
        op.sell(order, sig);
    }

    function test_SellTreasuryNotApprovedReverts() public {
        // user owns + approves token, but treasury does NOT approve stable
        (DexTokenIssuer.PurchaseOrder memory purchaseO, bytes memory purchaseSig) =
            _purchaseOrder(100 ether, 50 ether);
        vm.prank(ops);
        op.purchase(purchaseO, purchaseSig);
        vm.prank(alice);
        token.approve(address(op), type(uint256).max);

        (DexTokenIssuer.SellOrder memory order, bytes memory sig) = _sellOrder(20 ether, 40 ether);

        vm.prank(ops);
        vm.expectRevert();   // treasury → user stable allowance missing
        op.sell(order, sig);
    }

    function test_SellPausedTokenReverts() public {
        _setupForSell();
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        (DexTokenIssuer.SellOrder memory order, bytes memory sig) = _sellOrder(20 ether, 40 ether);

        vm.prank(ops);
        vm.expectRevert();   // TokenPaused
        op.sell(order, sig);
    }

    function test_SellBlockedUserReverts() public {
        _setupForSell();
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), list);

        (DexTokenIssuer.SellOrder memory order, bytes memory sig) = _sellOrder(20 ether, 40 ether);

        vm.prank(ops);
        vm.expectRevert(Compliance.UserBlocked.selector);
        op.sell(order, sig);
    }

    function test_SellDexTokenIssuerWithoutIssuerRoleReverts() public {
        _setupForSell();
        bytes32 issuerRole = token.ISSUER_ROLE();
        vm.prank(admin);
        token.revokeRole(issuerRole, address(op));

        (DexTokenIssuer.SellOrder memory order, bytes memory sig) = _sellOrder(20 ether, 40 ether);

        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.MissingIssuerRole.selector);
        op.sell(order, sig);
    }

    function test_SellBurnDisabledReverts() public {
        _setupForSell();
        vm.prank(admin);
        token.setBurnEnabled(false);

        (DexTokenIssuer.SellOrder memory order, bytes memory sig) = _sellOrder(20 ether, 40 ether);

        vm.prank(ops);
        vm.expectRevert(SecuritiesToken.BurnDisabled.selector);
        op.sell(order, sig);
    }

    // ═══════════════════════════════════════════════
    //              Admin management
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

        (DexTokenIssuer.PurchaseOrder memory order, bytes memory sig) = _purchaseOrder(100 ether, 50 ether);
        vm.prank(ops);
        vm.expectRevert(DexTokenIssuer.NotApprovedStable.selector);
        op.purchase(order, sig);
    }
}
