// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SecuritiesToken} from "../src/securitiesToken/SecuritiesToken.sol";
import {SecuritiesTokenFactory} from "../src/securitiesToken/SecuritiesTokenFactory.sol";
import {Compliance} from "../src/compliance/Compliance.sol";
import {PauseManager} from "../src/pauseManager/PauseManager.sol";

/// Minimal contract used wherever the tests need an ISSUER_ROLE holder. The token
/// rejects EOA issuers (must be a contract with non-empty code) so we deploy this
/// stub to play the role.
contract IssuerStub {}

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
    address internal issuer;                              // set in setUp — must be a contract
    address internal operator = makeAddr("operator");
    address internal complianceOps = makeAddr("complianceOps");
    address internal pauseOps = makeAddr("pauseOps");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");
    address internal stranger = makeAddr("stranger");

    bytes32 internal ISSUER_ROLE;
    bytes32 internal OPS_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE;
    bytes32 internal COMPLIANCE_OPS_ROLE;
    bytes32 internal PAUSE_MANAGER_OPS_ROLE;

    function setUp() public {
        // ISSUER_ROLE must be a contract — deploy a stub outside the prank so msg.sender
        // doesn't get spoofed during construction.
        issuer = address(new IssuerStub());

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

        // Admin's only operational role is granting OPS_ROLE on the auxiliary modules.
        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        pauseManager.grantRole(pauseManager.OPS_ROLE(), pauseOps);

        vm.stopPrank();

        ISSUER_ROLE = token.ISSUER_ROLE();
        OPS_ROLE = token.OPS_ROLE();
        COMPLIANCE_OPS_ROLE = compliance.OPS_ROLE();
        PAUSE_MANAGER_OPS_ROLE = pauseManager.OPS_ROLE();
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

    function test_AdminCannotMint() public {
        // Admin is now strictly a role-granting authority — no operational power.
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
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
        vm.prank(issuer);
        vm.expectRevert(SecuritiesToken.MintDisabled.selector);
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
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.burn(1 ether);
    }

    function test_BurnDisabledBlocksBurn() public {
        vm.prank(issuer);
        token.mint(1 ether);
        vm.prank(admin);
        token.setBurnEnabled(false);
        vm.prank(issuer);
        vm.expectRevert(SecuritiesToken.BurnDisabled.selector);
        token.burn(1 ether);
    }

    // ═══════════════════════════════════════════════
    //                  Transfer / approve
    // ═══════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════
    //                  Pause
    // ═══════════════════════════════════════════════

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
        pauseManager.pauseAllTokens();

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
        vm.expectRevert(PauseManager.MissingPauseRole.selector);
        pauseManager.pauseToken(address(token));
    }

    // ═══════════════════════════════════════════════
    //                  Compliance
    // ═══════════════════════════════════════════════

    function test_BlocklistBlocksTransfer() public {
        vm.prank(issuer);
        token.mint(100 ether);

        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), list);

        vm.prank(issuer);
        vm.expectRevert(Compliance.UserBlocked.selector);
        token.transfer(user1, 1 ether);

        // Removing from blocklist restores transfer
        vm.prank(complianceOps);
        compliance.removeFromBlocklist(address(token), list);
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
        compliance.addToSanctionsList(list);

        vm.prank(issuer);
        vm.expectRevert(Compliance.UserSanctioned.selector);
        token.transfer(user1, 1 ether);
    }

    function test_SanctionsResetClearsAll() public {
        address[] memory list = new address[](2);
        list[0] = user1;
        list[1] = user2;
        vm.prank(complianceOps);
        compliance.addToSanctionsList(list);
        assertTrue(compliance.sanctionedAddresses(user1));
        assertTrue(compliance.sanctionedAddresses(user2));

        vm.prank(complianceOps);
        compliance.resetSanctionedAddresses();
        assertFalse(compliance.sanctionedAddresses(user1));
        assertFalse(compliance.sanctionedAddresses(user2));
    }

    function test_BlocklistIsTokenScoped() public {
        vm.prank(issuer);
        token.mint(100 ether);

        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), list);

        assertTrue(compliance.blockedAddresses(address(token), user1));
        assertFalse(compliance.blockedAddresses(address(0xBEEF), user1));
    }

    function test_AdminCannotManageBlocklist() public {
        address[] memory list = new address[](1);
        list[0] = user1;
        vm.prank(admin);
        vm.expectRevert(Compliance.MissingBlocklistRole.selector);
        compliance.addToBlocklist(address(token), list);
    }

    // ═══════════════════════════════════════════════
    //                  UI multiplier
    // ═══════════════════════════════════════════════

    function test_AdminCannotScheduleMultiplier() public {
        uint256 effective = block.timestamp + 1 hours;
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2 ether, effective);
    }

    function test_OperatorCanScheduleMultiplier() public {
        uint256 effective = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2 ether, effective);
        assertEq(token.newUIMultiplier(), 2 ether);
        assertEq(token.effectiveAt(), effective);
        assertTrue(token.hasPendingMultiplier());
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
        vm.prank(operator);
        token.setUIMultiplier(2 ether, effective);

        // Before activation: live multiplier still old
        assertEq(token.uiMultiplier(), 1 ether);

        vm.warp(effective);
        assertEq(token.uiMultiplier(), 2 ether);
        assertFalse(token.hasPendingMultiplier());
    }

    function test_MultiplierBelowMinReverts() public {
        vm.prank(operator);
        vm.expectRevert(bytes("SecuritiesToken: multiplier below minimum (1e-9x)"));
        token.setUIMultiplier(1e9 - 1, block.timestamp + 1 hours);
    }

    function test_MultiplierAboveMaxReverts() public {
        vm.prank(operator);
        vm.expectRevert(bytes("SecuritiesToken: multiplier above maximum (1e9x)"));
        token.setUIMultiplier(1e27 + 1, block.timestamp + 1 hours);
    }

    function test_MultiplierBeyond365DaysReverts() public {
        vm.prank(operator);
        vm.expectRevert(bytes("SecuritiesToken: effective time too far in future"));
        token.setUIMultiplier(2 ether, block.timestamp + 366 days);
    }

    function test_MultiplierPastTimestampReverts() public {
        vm.warp(1_000_000);
        vm.prank(operator);
        vm.expectRevert(bytes("ERC8056: effective time must be in future"));
        token.setUIMultiplier(2 ether, block.timestamp);
    }

    function test_PendingMultiplierOverwriteEmitsAndUpdates() public {
        uint256 firstAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(2 ether, firstAt);

        uint256 secondAt = block.timestamp + 2 hours;
        vm.prank(operator);
        token.setUIMultiplier(3 ether, secondAt);

        assertEq(token.newUIMultiplier(), 3 ether);
        assertEq(token.effectiveAt(), secondAt);
    }

    function test_ToUIAmountScalesWithMultiplier() public {
        uint256 raw = 100 ether;
        assertEq(token.toUIAmount(raw), raw); // 1.0x

        vm.prank(operator);
        token.setUIMultiplier(2 ether, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours);
        assertEq(token.toUIAmount(raw), raw * 2);

        assertEq(token.fromUIAmount(raw * 2), raw);
    }

    function test_BalanceOfUIReflectsMultiplier() public {
        vm.prank(issuer);
        token.mint(100 ether);

        vm.prank(operator);
        token.setUIMultiplier(2 ether, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours);

        assertEq(token.balanceOfUI(issuer), 200 ether);
        assertEq(token.totalSupplyUI(), 200 ether);
    }

    // ═══════════════════════════════════════════════
    //                  Roles
    // ═══════════════════════════════════════════════

    function test_AdminCanGrantAndRevokeIssuer() public {
        // ISSUER_ROLE must be a contract — deploy a stub to grant to
        address newIssuer = address(new IssuerStub());
        vm.prank(admin);
        token.grantRole(ISSUER_ROLE, newIssuer);
        assertTrue(token.hasRole(ISSUER_ROLE, newIssuer));

        vm.prank(admin);
        token.revokeRole(ISSUER_ROLE, newIssuer);
        assertFalse(token.hasRole(ISSUER_ROLE, newIssuer));
    }

    function test_GrantingIssuerRoleToEoaReverts() public {
        // EOA can't hold ISSUER_ROLE — must be a contract
        address eoa = makeAddr("someEoa");
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.IssuerMustBeContract.selector);
        token.grantRole(ISSUER_ROLE, eoa);
    }

    function test_GrantingOpsRoleToEoaIsAllowed() public {
        // OPS_ROLE has no contract-only constraint — EOA is fine
        address eoa = makeAddr("opsEoa");
        vm.prank(admin);
        token.grantRole(OPS_ROLE, eoa);
        assertTrue(token.hasRole(OPS_ROLE, eoa));
    }

    function test_FactoryDeployTokenRejectsEoaIssuer() public {
        // Same check applies at init time via the factory
        address eoa = makeAddr("eoaIssuer");
        address[] memory issuers = new address[](1);
        issuers[0] = eoa;
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.IssuerMustBeContract.selector);
        factory.deployToken("Tesla Inc.", "TSLA", "US88160R1014", admin, issuers, empty);
    }

    function test_AdminCanGrantAndRevokeOperator() public {
        address newOps = makeAddr("newOps");
        vm.prank(admin);
        token.grantRole(OPS_ROLE, newOps);
        assertTrue(token.hasRole(OPS_ROLE, newOps));

        // User can now schedule a multiplier change
        vm.prank(newOps);
        token.setUIMultiplier(2 ether, block.timestamp + 1 hours);

        vm.prank(admin);
        token.revokeRole(OPS_ROLE, newOps);

        // Now they can't anymore
        vm.prank(newOps);
        vm.expectRevert(SecuritiesToken.UnauthorizedRole.selector);
        token.setUIMultiplier(3 ether, block.timestamp + 2 hours);
    }

    function test_NonAdminCannotGrantRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        token.grantRole(ISSUER_ROLE, user1);
    }

    // ═══════════════════════════════════════════════
    //                  Self-grant guard
    // ═══════════════════════════════════════════════

    function test_AdminCannotSelfGrantOnToken() public {
        vm.prank(admin);
        vm.expectRevert(SecuritiesToken.SelfGrantNotAllowed.selector);
        token.grantRole(ISSUER_ROLE, admin);
    }

    function test_AdminCannotSelfGrantOnCompliance() public {
        vm.prank(admin);
        vm.expectRevert(Compliance.SelfGrantNotAllowed.selector);
        compliance.grantRole(COMPLIANCE_OPS_ROLE, admin);
    }

    function test_AdminCannotSelfGrantOnPauseManager() public {
        vm.prank(admin);
        vm.expectRevert(PauseManager.SelfGrantNotAllowed.selector);
        pauseManager.grantRole(PAUSE_MANAGER_OPS_ROLE, admin);
    }

    function test_AdminCanStillGrantToOthers() public {
        // Sanity: the guard does NOT block grants to other accounts.
        vm.prank(admin);
        token.grantRole(OPS_ROLE, user1);
        assertTrue(token.hasRole(OPS_ROLE, user1));
    }

    function test_InitialAdminRoleStillSetByConstructor() public view {
        // The guard only affects public grantRole(); the constructor / initialize
        // uses the internal _grantRole and is unaffected.
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(compliance.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(pauseManager.hasRole(DEFAULT_ADMIN_ROLE, admin));
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

    // ═══════════════════════════════════════════════
    //                  EIP-2612 permit
    // ═══════════════════════════════════════════════

    /// Build an EIP-2612 permit signature for the security token.
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

        // Anyone can submit the permit (typically a relayer / the spender)
        IERC20Permit(address(token)).permit(holder.addr, spender, amount, deadline, v, r, s);

        assertEq(token.allowance(holder.addr, spender), amount);
        assertEq(IERC20Permit(address(token)).nonces(holder.addr), 1);
    }

    function test_PermitEnablesTransferFromInOneTx() public {
        // End-to-end: holder receives tokens, signs permit, spender pulls via transferFrom.
        // No separate approve tx needed.
        Vm.Wallet memory holder = vm.createWallet("permitHolder");
        address spender = makeAddr("permitSpender");

        vm.prank(issuer);
        token.mint(500 ether);
        vm.prank(issuer);
        token.transfer(holder.addr, 500 ether);

        uint256 amount = 200 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signTokenPermit(holder, spender, amount, deadline);

        // Spender's relayer submits permit + transferFrom together (simulated here as two
        // sequential calls — on-chain a router would do them atomically).
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

        vm.expectRevert();   // ERC2612ExpiredSignature
        IERC20Permit(address(token)).permit(holder.addr, user1, 100 ether, deadline, v, r, s);
    }

    function test_PermitWrongSignerReverts() public {
        Vm.Wallet memory owner = vm.createWallet("owner");
        Vm.Wallet memory imposter = vm.createWallet("imposter");
        uint256 deadline = block.timestamp + 1 hours;

        // imposter signs but the permit claims to be from `owner`
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        uint256 nonce = IERC20Permit(address(token)).nonces(owner.addr);
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner.addr, user1, 100 ether, nonce, deadline));
        bytes32 domain = IERC20Permit(address(token)).DOMAIN_SEPARATOR();
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(imposter.privateKey, digest);

        vm.expectRevert();   // ERC2612InvalidSigner
        IERC20Permit(address(token)).permit(owner.addr, user1, 100 ether, deadline, v, r, s);
    }

    function test_PermitReplayReverts() public {
        Vm.Wallet memory holder = vm.createWallet("permitHolder");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signTokenPermit(holder, user1, 100 ether, deadline);

        IERC20Permit(address(token)).permit(holder.addr, user1, 100 ether, deadline, v, r, s);
        assertEq(IERC20Permit(address(token)).nonces(holder.addr), 1);

        // Replay with same signature — nonce already consumed
        vm.expectRevert();
        IERC20Permit(address(token)).permit(holder.addr, user1, 100 ether, deadline, v, r, s);
    }

    function test_EIP712DomainExposed() public view {
        // Sanity: eip712Domain() returns the initial name so dapps can build signatures.
        // The function is provided by EIP712Upgradeable (which ERC20PermitUpgradeable inherits).
        (bool ok, bytes memory data) =
            address(token).staticcall(abi.encodeWithSignature("eip712Domain()"));
        require(ok, "eip712Domain call failed");
        (, string memory name,,,,,) =
            abi.decode(data, (bytes1, string, string, uint256, address, bytes32, uint256[]));
        // The cached name comes from the initial nameOverride_ passed to factory.deployToken.
        assertEq(name, "Apple Inc.");
    }
}
