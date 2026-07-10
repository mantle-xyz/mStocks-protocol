// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ScaledToken} from "../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../src/pauseRegistry/PauseRegistry.sol";

/// Minimal contract used wherever the tests need an ISSUER_ROLE holder. The token
/// rejects EOA issuers (must be a contract with non-empty code) so we deploy this
/// stub to play the role.
contract IssuerStub {}

contract ScaledTokenTest is Test {
    ScaledTokenFactory internal factory;
    ComplianceRegistry internal compliance;
    PauseRegistry internal pauseManager;
    ScaledToken internal token;

    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal issuer;
    address internal operator = makeAddr("operator");
    address internal complianceOps = makeAddr("complianceOps");
    address internal pauseOps = makeAddr("pauseOps");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");
    address internal stranger = makeAddr("stranger");

    bytes32 internal ISSUER_ROLE;
    bytes32 internal SCHEDULER_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE;
    bytes32 internal COMPLIANCE_OPS_ROLE;
    bytes32 internal PAUSE_OPS_ROLE;

    function setUp() public {
        // ISSUER_ROLE must be a contract — deploy a stub outside the prank so msg.sender
        // doesn't get spoofed during construction.
        issuer = address(new IssuerStub());

        vm.startPrank(admin);

        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = new ScaledTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin);

        address[] memory issuers = new address[](1);
        issuers[0] = issuer;
        address[] memory schedulers = new address[](1);
        schedulers[0] = operator;

        address proxy = factory.createToken("Apple Inc.", "AAPL", "US0378331005", admin, issuers, schedulers);
        token = ScaledToken(proxy);

        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        pauseManager.grantRole(pauseManager.OPS_ROLE(), pauseOps);

        vm.stopPrank();

        ISSUER_ROLE = token.ISSUER_ROLE();
        SCHEDULER_ROLE = token.MULTIPLIER_SCHEDULER_ROLE();
        COMPLIANCE_OPS_ROLE = compliance.OPS_ROLE();
        PAUSE_OPS_ROLE = pauseManager.OPS_ROLE();
        DEFAULT_ADMIN_ROLE = 0x00;
    }

    function test_InitialState() public view {
        assertEq(token.name(), "Apple Inc.");
        assertEq(token.symbol(), "AAPL");
        assertEq(token.assetCode(), "US0378331005");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
        assertEq(token.uiMultiplier(), 1 ether);
        assertTrue(token.mintAllowed());
        assertTrue(token.burnAllowed());
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(token.hasRole(ISSUER_ROLE, issuer));
        assertTrue(token.hasRole(SCHEDULER_ROLE,operator));
    }

    function test_AdminCanRenameAndReSymbol() public {
        vm.startPrank(admin);
        token.updateName("Apple Inc. v2");
        token.updateSymbol("AAPL2");
        token.updateAssetCode("NEWID123");
        vm.stopPrank();

        assertEq(token.name(), "Apple Inc. v2");
        assertEq(token.symbol(), "AAPL2");
        assertEq(token.assetCode(), "NEWID123");
    }

    function test_NonAdminCannotRename() public {
        vm.prank(stranger);
        vm.expectRevert();
        token.updateName("X");
    }

    function test_AdminCannotMint() public {
        vm.prank(admin);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.mint(1_000 ether);
    }

    function test_IssuerCanMint() public {
        vm.prank(issuer);
        token.mint(500 ether);
        assertEq(token.balanceOf(issuer), 500 ether);
        assertEq(token.totalSupply(), 500 ether);
    }

    function test_StrangerCannotMint() public {
        vm.prank(stranger);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.mint(1 ether);
    }

    function test_OperatorCannotMint() public {
        vm.prank(operator);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.mint(1 ether);
    }

    function test_MintNotAllowedBlocksMint() public {
        vm.prank(admin);
        token.setMintAllowed(false);
        vm.prank(issuer);
        vm.expectRevert(ScaledToken.MintNotAllowed.selector);
        token.mint(1 ether);
    }

    function test_IssuerCanBurn() public {
        vm.startPrank(issuer);
        token.mint(1_000 ether);
        token.burn(400 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(issuer), 600 ether);
        assertEq(token.totalSupply(), 600 ether);
    }

    function test_AdminCannotBurn() public {
        vm.prank(issuer);
        token.mint(100 ether);
        vm.prank(admin);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.burn(1 ether);
    }

    function test_BurnNotAllowedBlocksBurn() public {
        vm.prank(issuer);
        token.mint(1 ether);
        vm.prank(admin);
        token.setBurnAllowed(false);
        vm.prank(issuer);
        vm.expectRevert(ScaledToken.BurnNotAllowed.selector);
        token.burn(1 ether);
    }

    function test_TransferHappyPath() public {
        vm.startPrank(issuer);
        token.mint(1_000 ether);
        token.transfer(user1, 400 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(issuer), 600 ether);
        assertEq(token.balanceOf(user1), 400 ether);

        vm.prank(user1);
        token.transfer(user2, 150 ether);
        assertEq(token.balanceOf(user1), 250 ether);
        assertEq(token.balanceOf(user2), 150 ether);
    }

    function test_ApproveAndTransferFrom() public {
        vm.startPrank(issuer);
        token.mint(1_000 ether);
        token.transfer(user1, 500 ether);
        vm.stopPrank();

        vm.prank(user1);
        token.approve(user2, 200 ether);
        assertEq(token.allowance(user1, user2), 200 ether);

        vm.prank(user2);
        token.transferFrom(user1, user2, 200 ether);
        assertEq(token.balanceOf(user1), 300 ether);
        assertEq(token.balanceOf(user2), 200 ether);
        assertEq(token.allowance(user1, user2), 0);
    }

    function test_PausedTokenBlocksTransfer() public {
        vm.prank(issuer);
        token.mint(100 ether);

        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        vm.prank(issuer);
        vm.expectRevert();
        token.transfer(user1, 1 ether);
    }

    function test_GlobalPauseBlocksTransfer() public {
        vm.prank(issuer);
        token.mint(100 ether);

        vm.prank(pauseOps);
        pauseManager.pauseGlobally();

        vm.prank(issuer);
        vm.expectRevert();
        token.transfer(user1, 1 ether);
    }

    function test_UnpauseRestoresTransfer() public {
        vm.prank(issuer);
        token.mint(100 ether);
        vm.startPrank(pauseOps);
        pauseManager.pauseToken(address(token));
        pauseManager.unpauseToken(address(token));
        vm.stopPrank();
        vm.prank(issuer);
        token.transfer(user1, 1 ether);
        assertEq(token.balanceOf(user1), 1 ether);
    }

    function test_AdminCannotPause() public {
        vm.prank(admin);
        vm.expectRevert(PauseRegistry.MissingOpsRole.selector);
        pauseManager.pauseToken(address(token));
    }

    function test_BlocklistBlocksTransfer() public {
        vm.prank(issuer);
        token.mint(100 ether);

        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(complianceOps);
        compliance.blockUsers(address(token), list);

        vm.prank(issuer);
        vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
        token.transfer(user1, 1 ether);

        vm.prank(complianceOps);
        compliance.unblockUsers(address(token), list);
        vm.prank(issuer);
        token.transfer(user1, 1 ether);
        assertEq(token.balanceOf(user1), 1 ether);
    }

    function test_SanctionsBlockTransfer() public {
        vm.prank(issuer);
        token.mint(100 ether);

        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(complianceOps);
        compliance.sanctionUsers(list);

        vm.prank(issuer);
        vm.expectRevert(ComplianceRegistry.UserSanctioned.selector);
        token.transfer(user1, 1 ether);
    }

    function test_SanctionsResetClearsAll() public {
        address[] memory list = new address[](2);
        list[0] = user1;
        list[1] = user2;
        vm.prank(complianceOps);
        compliance.sanctionUsers(list);
        assertTrue(compliance.isSanctioned(user1));
        assertTrue(compliance.isSanctioned(user2));

        vm.prank(complianceOps);
        compliance.clearSanctions();
        assertFalse(compliance.isSanctioned(user1));
        assertFalse(compliance.isSanctioned(user2));
    }

    function test_BlocklistIsTokenScoped() public {
        vm.prank(issuer);
        token.mint(100 ether);

        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(complianceOps);
        compliance.blockUsers(address(token), list);

        assertTrue(compliance.isBlocked(address(token), user1));
        assertFalse(compliance.isBlocked(address(0xBEEF), user1));
    }

    function test_AdminCannotManageBlocklist() public {
        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.MissingOpsRole.selector);
        compliance.blockUsers(address(token), list);
    }

    function test_AdminCannotScheduleMultiplier() public {
        uint256 effective = block.timestamp + 25 hours;
        vm.prank(admin);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2 ether, effective);
    }

    function test_OperatorCanScheduleMultiplier() public {
        uint256 effective = block.timestamp + 25 hours;
        vm.prank(operator);
        token.setUIMultiplier(2 ether, effective);
        assertEq(token.newUIMultiplier(), 2 ether);
        assertEq(token.effectiveAt(), effective);
        assertTrue(token.hasPendingMultiplier());
    }

    function test_IssuerCannotScheduleMultiplier() public {
        uint256 effective = block.timestamp + 25 hours;
        vm.prank(issuer);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2 ether, effective);
    }

    function test_StrangerCannotScheduleMultiplier() public {
        vm.prank(stranger);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2 ether, block.timestamp + 25 hours);
    }

    function test_MultiplierActivatesAfterEffectiveAt() public {
        uint256 effective = block.timestamp + 25 hours;
        vm.prank(operator);
        token.setUIMultiplier(2 ether, effective);

        assertEq(token.uiMultiplier(), 1 ether);

        vm.warp(effective);
        assertEq(token.uiMultiplier(), 2 ether);
        assertFalse(token.hasPendingMultiplier());
    }

    function test_MultiplierBelowMinReverts() public {
        vm.prank(operator);
        vm.expectRevert(bytes("ScaledToken: multiplier below minimum (1e-9x)"));
        token.setUIMultiplier(1e9 - 1, block.timestamp + 25 hours);
    }

    function test_MultiplierAboveMaxReverts() public {
        vm.prank(operator);
        vm.expectRevert(bytes("ScaledToken: multiplier above maximum (1e9x)"));
        token.setUIMultiplier(1e27 + 1, block.timestamp + 25 hours);
    }

    function test_MultiplierBelowMinNoticeReverts() public {
        vm.prank(operator);
        vm.expectRevert(bytes("ScaledToken: minimum notice period not met"));
        token.setUIMultiplier(2 ether, block.timestamp + 23 hours);
    }

    function test_MultiplierBeyond365DaysReverts() public {
        vm.prank(operator);
        vm.expectRevert(bytes("ScaledToken: effective time too far in future"));
        token.setUIMultiplier(2 ether, block.timestamp + 366 days);
    }

    function test_MultiplierPastTimestampReverts() public {
        // Current/past timestamps fall under MIN_MULTIPLIER_NOTICE now — the ScaledToken
        // check fires before the ERC8056 base "must be in future" check.
        vm.warp(1_000_000);
        vm.prank(operator);
        vm.expectRevert(bytes("ScaledToken: minimum notice period not met"));
        token.setUIMultiplier(2 ether, block.timestamp);
    }

    function test_PendingMultiplierOverwriteEmitsAndUpdates() public {
        uint256 firstAt = block.timestamp + 25 hours;
        vm.prank(operator);
        token.setUIMultiplier(2 ether, firstAt);

        uint256 secondAt = block.timestamp + 26 hours;
        vm.prank(operator);
        token.setUIMultiplier(3 ether, secondAt);

        assertEq(token.newUIMultiplier(), 3 ether);
        assertEq(token.effectiveAt(), secondAt);
    }

    function test_ToUIAmountScalesWithMultiplier() public {
        uint256 raw = 100 ether;
        assertEq(token.toUIAmount(raw), raw);

        vm.prank(operator);
        token.setUIMultiplier(2 ether, block.timestamp + 25 hours);
        vm.warp(block.timestamp + 25 hours);
        assertEq(token.toUIAmount(raw), raw * 2);

        assertEq(token.fromUIAmount(raw * 2), raw);
    }

    function test_BalanceOfUIReflectsMultiplier() public {
        vm.prank(issuer);
        token.mint(100 ether);

        vm.prank(operator);
        token.setUIMultiplier(2 ether, block.timestamp + 25 hours);
        vm.warp(block.timestamp + 25 hours);

        assertEq(token.balanceOfUI(issuer), 200 ether);
        assertEq(token.totalSupplyUI(), 200 ether);
    }

    function test_AdminCanGrantAndRevokeIssuer() public {
        address newIssuer = address(new IssuerStub());
        vm.prank(admin);
        token.grantRole(ISSUER_ROLE, newIssuer);
        assertTrue(token.hasRole(ISSUER_ROLE, newIssuer));

        vm.prank(admin);
        token.revokeRole(ISSUER_ROLE, newIssuer);
        assertFalse(token.hasRole(ISSUER_ROLE, newIssuer));
    }

    function test_GrantingIssuerRoleToEoaReverts() public {
        address eoa = makeAddr("someEoa");
        vm.prank(admin);
        vm.expectRevert(ScaledToken.IssuerNotContract.selector);
        token.grantRole(ISSUER_ROLE, eoa);
    }

    function test_GrantingOpsRoleToEoaIsAllowed() public {
        address eoa = makeAddr("opsEoa");
        vm.prank(admin);
        token.grantRole(SCHEDULER_ROLE,eoa);
        assertTrue(token.hasRole(SCHEDULER_ROLE,eoa));
    }

    function test_FactoryDeployTokenRejectsEoaIssuer() public {
        address eoa = makeAddr("eoaIssuer");
        address[] memory issuers = new address[](1);
        issuers[0] = eoa;
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(ScaledToken.IssuerNotContract.selector);
        factory.createToken("Tesla Inc.", "TSLA", "US88160R1014", admin, issuers, empty);
    }

    function test_AdminCanGrantAndRevokeOperator() public {
        address newOps = makeAddr("newOps");
        vm.prank(admin);
        token.grantRole(SCHEDULER_ROLE,newOps);
        assertTrue(token.hasRole(SCHEDULER_ROLE,newOps));

        vm.prank(newOps);
        token.setUIMultiplier(2 ether, block.timestamp + 25 hours);

        vm.prank(admin);
        token.revokeRole(SCHEDULER_ROLE,newOps);

        vm.prank(newOps);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.setUIMultiplier(3 ether, block.timestamp + 26 hours);
    }

    function test_NonAdminCannotGrantRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        token.grantRole(ISSUER_ROLE, user1);
    }

    function test_AdminCannotSelfGrantOnToken() public {
        vm.prank(admin);
        vm.expectRevert(ScaledToken.SelfGrantNotAllowed.selector);
        token.grantRole(ISSUER_ROLE, admin);
    }

    function test_AdminCannotSelfGrantOnCompliance() public {
        vm.prank(admin);
        vm.expectRevert(ComplianceRegistry.SelfGrantNotAllowed.selector);
        compliance.grantRole(COMPLIANCE_OPS_ROLE, admin);
    }

    function test_AdminCannotSelfGrantOnPauseManager() public {
        vm.prank(admin);
        vm.expectRevert(PauseRegistry.SelfGrantNotAllowed.selector);
        pauseManager.grantRole(PAUSE_OPS_ROLE, admin);
    }

    function test_AdminCanStillGrantToOthers() public {
        vm.prank(admin);
        token.grantRole(SCHEDULER_ROLE,user1);
        assertTrue(token.hasRole(SCHEDULER_ROLE,user1));
    }

    function test_InitialAdminRoleStillSetByConstructor() public view {
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(compliance.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(pauseManager.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_FactoryRejectsDuplicateSymbol() public {
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ScaledTokenFactory.TokenSymbolAlreadyExists.selector, "AAPL")
        );
        factory.createToken("Apple v2", "AAPL", "ID2", admin, empty, empty);
    }

    function test_FactoryRegistersDeployedToken() public {
        assertEq(factory.tokenBySymbol("AAPL"), address(token));
        assertEq(factory.tokenCount(), 1);
    }

    function test_FactoryRejectsInvalidSymbol() public {
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ScaledTokenFactory.InvalidSymbol.selector, "AAPL!")
        );
        factory.createToken("X", "AAPL!", "ID3", admin, empty, empty);
    }

    function test_FactoryRejectsDuplicateAssetCode() public {
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ScaledTokenFactory.AssetCodeAlreadyExists.selector, "US0378331005")
        );
        // Same assetCode as the setUp AAPL token; different name/symbol so we hit the
        // asset-code uniqueness check specifically.
        factory.createToken("Copycat", "COPY", "US0378331005", admin, empty, empty);
    }

    function test_FactoryRejectsInvalidAssetCode() public {
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ScaledTokenFactory.InvalidAssetCode.selector, "BAD CODE!")
        );
        factory.createToken("New", "NEW", "BAD CODE!", admin, empty, empty);
    }

    function test_FactoryRegistersAssetCodeMapping() public view {
        assertEq(factory.tokenByAssetCode("US0378331005"), address(token));
    }

    function test_RenameAssetCodeHappyPath() public {
        vm.prank(admin);
        token.updateAssetCode("US0378331006");

        vm.prank(admin);
        factory.renameAssetCode(address(token), "US0378331005", "US0378331006");

        assertEq(factory.tokenByAssetCode("US0378331005"), address(0));
        assertEq(factory.tokenByAssetCode("US0378331006"), address(token));
    }

    function test_RenameAssetCodeRevertsWhenTokenNotYetUpdated() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ScaledTokenFactory.AssetCodeMismatch.selector, "US0378331005", "US0378331006"
            )
        );
        factory.renameAssetCode(address(token), "US0378331005", "US0378331006");
    }

    function test_RenameAssetCodeRevertsIfTokenNotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ScaledTokenFactory.TokenNotRegisteredUnderAssetCode.selector, address(token), "WRONG"
            )
        );
        factory.renameAssetCode(address(token), "WRONG", "US0378331006");
    }

    function test_RenameAssetCodeRevertsOnZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.ZeroAddress.selector);
        factory.renameAssetCode(address(0), "US0378331005", "US0378331006");
    }

    function test_UpdateAssetCodeRejectsInvalidFormat() public {
        vm.prank(admin);
        vm.expectRevert(ScaledToken.InvalidAssetCode.selector);
        token.updateAssetCode("BAD CODE!");
    }

    function test_InitializeRejectsZeroAdmin() public {
        // Factory createToken has its own admin-zero check, but initialize is public on the impl
        // so any BeaconProxy pointing at the shared beacon could bypass the factory. Deploy a
        // BeaconProxy manually and assert the defense-in-depth check inside __scaledToken_init.
        address[] memory empty = new address[](0);
        bytes memory initData = abi.encodeWithSignature(
            "initialize(string,string,string,address,address,address,address[],address[])",
            "X", "X", "ID", address(compliance), address(pauseManager), address(0), empty, empty
        );
        address beaconAddr = address(factory.beacon());
        vm.expectRevert(ScaledToken.ZeroAddress.selector);
        new BeaconProxy(beaconAddr, initData);
    }

    function test_RenameSymbolHappyPath() public {
        vm.prank(admin);
        token.updateSymbol("AAPL2");

        vm.prank(admin);
        factory.renameSymbol(address(token), "AAPL", "AAPL2");

        assertEq(factory.tokenBySymbol("AAPL"), address(0));
        assertEq(factory.tokenBySymbol("AAPL2"), address(token));
    }

    function test_RenameSymbolRevertsWhenTokenSymbolNotYetUpdated() public {
        // Caller forgot to call token.updateSymbol first — on-token symbol is still "AAPL",
        // so renaming the factory registry to "AAPL2" must revert with SymbolMismatch.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ScaledTokenFactory.SymbolMismatch.selector, "AAPL", "AAPL2")
        );
        factory.renameSymbol(address(token), "AAPL", "AAPL2");
    }

    function test_RenameSymbolRevertsIfTokenNotRegisteredUnderOldSymbol() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                ScaledTokenFactory.TokenNotRegisteredUnderSymbol.selector,
                address(token),
                "WRONG"
            )
        );
        factory.renameSymbol(address(token), "WRONG", "AAPL2");
    }

    function test_RenameSymbolRevertsOnZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.ZeroAddress.selector);
        factory.renameSymbol(address(0), "AAPL", "AAPL2");
    }

    function _signTokenPermit(
        Vm.Wallet memory wallet,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        uint256 nonce = IERC20Permit(address(token)).nonces(wallet.addr);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, wallet.addr, spender, value, nonce, deadline));
        bytes32 domain = IERC20Permit(address(token)).DOMAIN_SEPARATOR();
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, structHash);
        (v, r, s) = vm.sign(wallet.privateKey, digest);
    }

    function test_PermitSetsAllowanceWithoutApprove() public {
        Vm.Wallet memory holder = vm.createWallet("permitHolder");
        address spender = makeAddr("permitSpender");
        uint256 amount = 200 ether;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signTokenPermit(holder, spender, amount, deadline);

        IERC20Permit(address(token)).permit(holder.addr, spender, amount, deadline, v, r, s);

        assertEq(token.allowance(holder.addr, spender), amount);
        assertEq(IERC20Permit(address(token)).nonces(holder.addr), 1);
    }

    function test_PermitEnablesTransferFromInOneTx() public {
        Vm.Wallet memory holder = vm.createWallet("permitHolder");
        address spender = makeAddr("permitSpender");

        vm.prank(issuer);
        token.mint(500 ether);
        vm.prank(issuer);
        token.transfer(holder.addr, 500 ether);

        uint256 amount = 200 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signTokenPermit(holder, spender, amount, deadline);

        IERC20Permit(address(token)).permit(holder.addr, spender, amount, deadline, v, r, s);
        vm.prank(spender);
        token.transferFrom(holder.addr, spender, amount);

        assertEq(token.balanceOf(holder.addr), 300 ether);
        assertEq(token.balanceOf(spender), amount);
        assertEq(token.allowance(holder.addr, spender), 0);
    }

    function test_PermitExpiredDeadlineReverts() public {
        Vm.Wallet memory holder = vm.createWallet("permitHolder");
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            _signTokenPermit(holder, user1, 100 ether, deadline);

        vm.expectRevert();
        IERC20Permit(address(token)).permit(holder.addr, user1, 100 ether, deadline, v, r, s);
    }

    function test_PermitWrongSignerReverts() public {
        Vm.Wallet memory owner = vm.createWallet("owner");
        Vm.Wallet memory imposter = vm.createWallet("imposter");
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        uint256 nonce = IERC20Permit(address(token)).nonces(owner.addr);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner.addr, user1, 100 ether, nonce, deadline));
        bytes32 domain = IERC20Permit(address(token)).DOMAIN_SEPARATOR();
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(imposter.privateKey, digest);

        vm.expectRevert();
        IERC20Permit(address(token)).permit(owner.addr, user1, 100 ether, deadline, v, r, s);
    }

    function test_PermitReplayReverts() public {
        Vm.Wallet memory holder = vm.createWallet("permitHolder");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signTokenPermit(holder, user1, 100 ether, deadline);

        IERC20Permit(address(token)).permit(holder.addr, user1, 100 ether, deadline, v, r, s);
        assertEq(IERC20Permit(address(token)).nonces(holder.addr), 1);

        vm.expectRevert();
        IERC20Permit(address(token)).permit(holder.addr, user1, 100 ether, deadline, v, r, s);
    }

    function test_EIP712DomainExposed() public view {
        (bool ok, bytes memory data) =
            address(token).staticcall(abi.encodeWithSignature("eip712Domain()"));
        require(ok, "eip712Domain call failed");
        (, string memory name,,,,,) =
            abi.decode(data, (bytes1, string, string, uint256, address, bytes32, uint256[]));
        assertEq(name, "Apple Inc.");
    }
}
