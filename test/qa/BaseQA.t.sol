// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {SecuritiesTokenFactory} from "../../src/securitiesToken/SecuritiesTokenFactory.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {PauseManager} from "../../src/pauseManager/PauseManager.sol";
import {OperatorWallet} from "../../src/OperatorWallet/OperatorWallet.sol";

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
    Compliance internal compliance;
    PauseManager internal pauseManager;
    SecuritiesTokenFactory internal factory;
    SecuritiesToken internal token;
    OperatorWallet internal wallet;

    // ── accounts ──
    address internal admin = makeAddr("admin");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal issuer;
    address internal operator = makeAddr("operator");
    address internal complianceOps = makeAddr("complianceOps");
    address internal pauseOps = makeAddr("pauseOps");
    address internal walletOps = makeAddr("walletOps");
    address internal hotWallet1 = makeAddr("hotWallet1");
    address internal hotWallet2 = makeAddr("hotWallet2");
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal stranger = makeAddr("stranger");

    // ── role hashes ──
    bytes32 internal ISSUER_ROLE;
    bytes32 internal OPS_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE_HASH;
    bytes32 internal COMPLIANCE_OPS_ROLE;
    bytes32 internal PAUSE_MANAGER_OPS_ROLE;
    bytes32 internal WALLET_OPS_ROLE;

    function setUp() public virtual {
        vm.startPrank(admin);

        compliance = new Compliance(admin);
        pauseManager = new PauseManager(admin);
        factory = new SecuritiesTokenFactory(address(compliance), address(pauseManager), admin, proxyAdmin);

        OperatorWallet impl = new OperatorWallet();
        bytes memory initData = abi.encodeWithSelector(OperatorWallet.initialize.selector, admin);
        wallet = OperatorWallet(payable(address(new ERC1967Proxy(address(impl), initData))));
        wallet.grantRole(wallet.OPS_ROLE(), walletOps);
        wallet.addHotWallet(hotWallet1);
        wallet.addHotWallet(hotWallet2);

        address[] memory issuers = new address[](1);
        issuers[0] = address(wallet);
        address[] memory operators = new address[](1);
        operators[0] = operator;

        address proxy = factory.deployToken("Apple Inc.", "AAPL", "US0378331005", admin, issuers, operators);
        token = SecuritiesToken(proxy);

        compliance.grantRole(compliance.OPS_ROLE(), complianceOps);
        pauseManager.grantRole(pauseManager.OPS_ROLE(), pauseOps);

        vm.stopPrank();

        issuer = address(wallet);
        ISSUER_ROLE = token.ISSUER_ROLE();
        OPS_ROLE = token.OPS_ROLE();
        DEFAULT_ADMIN_ROLE_HASH = 0x00;
        COMPLIANCE_OPS_ROLE = compliance.OPS_ROLE();
        PAUSE_MANAGER_OPS_ROLE = pauseManager.OPS_ROLE();
        WALLET_OPS_ROLE = wallet.OPS_ROLE();
    }

    function _mintAndTransfer(address recipient, uint256 amount) internal {
        vm.prank(walletOps);
        wallet.mint(address(token), hotWallet1, amount);
        vm.prank(hotWallet1);
        token.transfer(recipient, amount);
    }

    function _issuerMint(uint256 amount) internal {
        vm.prank(issuer);
        token.mint(amount);
    }
}
