// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";

abstract contract BaseQA is Test {
    // ── logging ──
    string internal _caseId;
    string internal _caseName;

    function _logCase(string memory id, string memory name) internal {
        _caseId = id;
        _caseName = name;
        console2.log("========================================");
        console2.log(string.concat("testcase id: ", id));
        console2.log(string.concat("testcase name: ", name));
        console2.log("========================================");
    }

    function _step(string memory msg_) internal pure {
        console2.log(msg_);
    }

    function _logPass() internal pure {
        console2.log("----------------------------------------");
        console2.log("test result: passed");
    }

    // ── protocol stack ──
    ComplianceRegistry internal compliance;
    PauseRegistry internal pauseManager;
    ScaledTokenFactory internal factory;
    ScaledToken internal token;
    TokenIssuer internal vault;

    // ── constants ──
    uint256 constant MIN_MULTIPLIER_NOTICE = 1 hours;

    // ── accounts ──
    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal issuer;
    address internal operator = makeAddr("operator");
    address internal complianceOps = makeAddr("complianceOps");
    address internal pauseOps = makeAddr("pauseOps");
    address internal tokenOps = makeAddr("tokenOps");
    address internal walletOps = makeAddr("walletOps");
    address internal hotWallet1 = makeAddr("hotWallet1");
    address internal hotWallet2 = makeAddr("hotWallet2");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal stranger = makeAddr("stranger");

    // ── role hashes ──
    bytes32 internal ISSUER_ROLE;
    bytes32 internal MULTIPLIER_SCHEDULER_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE_HASH;
    bytes32 internal COMPLIANCE_OPS_ROLE;
    bytes32 internal PAUSE_MANAGER_PAUSE_ROLE;
    bytes32 internal PAUSE_MANAGER_UNPAUSE_ROLE;
    bytes32 internal TOKEN_OPS_ROLE;
    bytes32 internal FACTORY_OPS_ROLE;
    bytes32 internal WALLET_OPS_ROLE;

    function setUp() public virtual {
        vm.startPrank(admin);

        compliance = new ComplianceRegistry(admin);
        pauseManager = new PauseRegistry(admin);
        factory = new ScaledTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin, MIN_MULTIPLIER_NOTICE);
        factory.grantRole(factory.OPS_ROLE(), address(this));
        vm.stopPrank();

        TokenIssuer impl = new TokenIssuer();
        vm.startPrank(admin);
        bytes memory initData = abi.encodeWithSelector(TokenIssuer.initialize.selector, admin);
        vault = TokenIssuer(payable(address(new ERC1967Proxy(address(impl), initData))));
        vault.grantRole(vault.OPS_ROLE(), walletOps);
        vault.addApprovedRecipient(hotWallet1);
        vault.addApprovedRecipient(hotWallet2);
        vm.stopPrank();

        address[] memory issuers = new address[](1);
        issuers[0] = address(vault);
        address[] memory multiplierSchedulers = new address[](1);
        multiplierSchedulers[0] = operator;
        address[] memory opsRoles = new address[](1);
        opsRoles[0] = tokenOps;

        address proxy = factory.createToken("Apple Inc.", "AAPL", "US0378331005", admin, issuers, multiplierSchedulers, opsRoles);
        token = ScaledToken(proxy);

        vm.startPrank(admin);

        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        pauseManager.grantRole(pauseManager.PAUSE_ROLE(), pauseOps);
        pauseManager.grantRole(pauseManager.UNPAUSE_ROLE(), pauseOps);

        vm.stopPrank();

        issuer = address(vault);
        ISSUER_ROLE = token.ISSUER_ROLE();
        MULTIPLIER_SCHEDULER_ROLE = token.MULTIPLIER_SCHEDULER_ROLE();
        DEFAULT_ADMIN_ROLE_HASH = 0x00;
        COMPLIANCE_OPS_ROLE = compliance.OPS_ROLE();
        PAUSE_MANAGER_PAUSE_ROLE = pauseManager.PAUSE_ROLE();
        PAUSE_MANAGER_UNPAUSE_ROLE = pauseManager.UNPAUSE_ROLE();
        TOKEN_OPS_ROLE = token.OPS_ROLE();
        FACTORY_OPS_ROLE = factory.OPS_ROLE();
        WALLET_OPS_ROLE = vault.OPS_ROLE();
    }

    function _mintAndTransfer(address recipient, uint256 amount) internal {
        vm.prank(walletOps);
        vault.mint(address(token), hotWallet1, amount);
        vm.prank(hotWallet1);
        token.transfer(recipient, amount);
    }

    function _issuerMint(uint256 amount) internal {
        vm.prank(issuer);
        token.mint(amount);
    }
}
