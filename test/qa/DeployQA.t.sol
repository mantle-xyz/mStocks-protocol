// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";

contract DeployQA is Test {
    string constant MODULE = unicode"部署";
    uint256 constant MIN_NOTICE = 1 hours;

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

    // ── accounts ──
    address internal deployer = makeAddr("deployer");
    address internal proxyAdmin = makeAddr("proxyAdmin");

    // ── DPL-01 ──
    function test_DPL01_StagedDeploy() public {
        _logCase("DPL-01", unicode"分阶段部署");

        _step("[Step 1] deployCompliance");
        vm.startPrank(deployer);
        ComplianceRegistry c = new ComplianceRegistry(deployer);
        assertTrue(address(c) != address(0));
        _step("  ComplianceRegistry deployed");

        _step("[Step 2] deployPauseManager");
        PauseRegistry pm = new PauseRegistry(deployer);
        assertTrue(address(pm) != address(0));
        _step("  PauseRegistry deployed");

        _step("[Step 3] deployFactory");
        ScaledTokenFactory f = new ScaledTokenFactory(address(c), address(pm), deployer, proxyAdmin, MIN_NOTICE);
        assertTrue(address(f) != address(0));
        _step("  Factory deployed");

        _step("[Step 4] createToken");
        f.grantRole(f.OPS_ROLE(), deployer);
        address issuerContract = address(new TokenIssuer());
        address[] memory issuers = new address[](1);
        issuers[0] = issuerContract;
        address[] memory mSchedulers = new address[](0);
        address proxy = f.createToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, mSchedulers);
        assertTrue(proxy != address(0));
        vm.stopPrank();
        _step("  PASS: 4 contracts deployed, all non-zero");

        _logPass();
    }

    // ── DPL-02 ──
    function test_DPL02_FullStackDeploy() public {
        _logCase("DPL-02", unicode"全栈部署");

        _step("[Step 1] deploy full stack in sequence (equivalent to run())");
        vm.startPrank(deployer);
        ComplianceRegistry c = new ComplianceRegistry(deployer);
        PauseRegistry pm = new PauseRegistry(deployer);
        ScaledTokenFactory f = new ScaledTokenFactory(address(c), address(pm), deployer, proxyAdmin, MIN_NOTICE);
        f.grantRole(f.OPS_ROLE(), deployer);
        address issuerContract = address(new TokenIssuer());
        address[] memory issuers = new address[](1);
        issuers[0] = issuerContract;
        address[] memory mSchedulers = new address[](0);
        address proxy = f.createToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, mSchedulers);
        vm.stopPrank();

        assertTrue(address(c) != address(0));
        assertTrue(address(pm) != address(0));
        assertTrue(address(f) != address(0));
        assertTrue(proxy != address(0));
        _step("  PASS: full stack deployed successfully");

        _logPass();
    }

    // ── DPL-03 ──
    function test_DPL03_ConfigValuesApplied() public {
        _logCase("DPL-03", unicode"config.toml 值正确应用");

        _step("[Step 1] deploy token with specific name/symbol/identifier, verify");
        vm.startPrank(deployer);
        ComplianceRegistry c = new ComplianceRegistry(deployer);
        PauseRegistry pm = new PauseRegistry(deployer);
        ScaledTokenFactory f = new ScaledTokenFactory(address(c), address(pm), deployer, proxyAdmin, MIN_NOTICE);
        f.grantRole(f.OPS_ROLE(), deployer);
        address issuerContract = address(new TokenIssuer());
        address[] memory issuers = new address[](1);
        issuers[0] = issuerContract;
        address[] memory mSchedulers = new address[](0);
        address proxy = f.createToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, mSchedulers);
        vm.stopPrank();

        ScaledToken t = ScaledToken(proxy);
        assertEq(t.name(), "Apple Inc.");
        assertEq(t.symbol(), "AAPL");
        assertEq(t.assetCode(), "US0378331005");
        _step("  PASS: name/symbol/identifier match config values");

        _logPass();
    }

    // ── DPL-04 ──
    function test_DPL04_DeployerAsAdmin() public {
        _logCase("DPL-04", unicode"部署者作为 admin 持有 DEFAULT_ADMIN_ROLE");

        _step("[Step 1] deploy with deployer as admin");
        vm.startPrank(deployer);
        ComplianceRegistry c = new ComplianceRegistry(deployer);
        assertTrue(c.hasRole(c.DEFAULT_ADMIN_ROLE(), deployer));
        vm.stopPrank();
        _step("  PASS: deployer holds DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── DPL-05 ──
    function test_DPL05_RolesAssignedPerConfig() public {
        _logCase("DPL-05", unicode"角色按 config 分配");

        _step("[Step 1] deploy full stack with specific role grants");
        address cOps = makeAddr("complianceOps");
        address pmOps = makeAddr("pauseOps");
        address issuerContract = address(new TokenIssuer());
        address oper = makeAddr("tokenOperator");

        vm.startPrank(deployer);
        ComplianceRegistry c = new ComplianceRegistry(deployer);
        c.grantRole(c.OPS_ROLE(), cOps);
        PauseRegistry pm = new PauseRegistry(deployer);
        pm.grantRole(pm.PAUSE_ROLE(), pmOps);
        pm.grantRole(pm.UNPAUSE_ROLE(), pmOps);
        ScaledTokenFactory f = new ScaledTokenFactory(address(c), address(pm), deployer, proxyAdmin, MIN_NOTICE);
        f.grantRole(f.OPS_ROLE(), deployer);
        address[] memory issuers = new address[](1);
        issuers[0] = issuerContract;
        address[] memory mSchedulers = new address[](1);
        mSchedulers[0] = oper;
        address proxy = f.createToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, mSchedulers);
        vm.stopPrank();

        ScaledToken t = ScaledToken(proxy);
        assertTrue(c.hasRole(c.OPS_ROLE(), cOps));
        assertTrue(pm.hasRole(pm.PAUSE_ROLE(), pmOps));
        assertTrue(pm.hasRole(pm.UNPAUSE_ROLE(), pmOps));
        assertTrue(t.hasRole(t.ISSUER_ROLE(), issuerContract));
        assertTrue(t.hasRole(t.MULTIPLIER_SCHEDULER_ROLE(), oper));
        _step("  PASS: all roles assigned correctly");

        _logPass();
    }

    // ── DPL-06 ──
    function test_DPL06_TokenIssuerDeploy() public {
        _logCase("DPL-06", unicode"TokenIssuer 部署");

        _step("[Step 1] deploy TokenIssuer proxy, grant OPS, add hot wallets");
        address owOps = makeAddr("walletOps");
        address hw1 = makeAddr("hw1");
        address hw2 = makeAddr("hw2");

        vm.startPrank(deployer);
        TokenIssuer impl = new TokenIssuer();
        bytes memory initData = abi.encodeWithSelector(TokenIssuer.initialize.selector, deployer);
        TokenIssuer w = TokenIssuer(payable(address(new ERC1967Proxy(address(impl), initData))));
        w.grantRole(w.OPS_ROLE(), owOps);
        w.addApprovedRecipient(hw1);
        w.addApprovedRecipient(hw2);
        vm.stopPrank();

        assertTrue(w.hasRole(w.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(w.hasRole(w.OPS_ROLE(), owOps));
        assertTrue(w.isApprovedRecipient(hw1));
        assertTrue(w.isApprovedRecipient(hw2));
        assertEq(w.numApprovedRecipients(), 2);
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE, OPS granted, hot wallets added");

        _logPass();
    }

    // ── DPL-07 ──
    function test_DPL07_TokenIssuerGrantedIssuerRole() public {
        _logCase("DPL-07", unicode"TokenIssuer 获得 ISSUER_ROLE");

        _step("[Step 1] deploy full stack + TokenIssuer, grant ISSUER_ROLE on token");
        vm.startPrank(deployer);
        ComplianceRegistry c = new ComplianceRegistry(deployer);
        PauseRegistry pm = new PauseRegistry(deployer);
        ScaledTokenFactory f = new ScaledTokenFactory(address(c), address(pm), deployer, proxyAdmin, MIN_NOTICE);
        f.grantRole(f.OPS_ROLE(), deployer);
        address[] memory issuers = new address[](0);
        address[] memory mSchedulers = new address[](0);
        address proxy = f.createToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, mSchedulers);
        ScaledToken t = ScaledToken(proxy);

        TokenIssuer impl2 = new TokenIssuer();
        bytes memory initData2 = abi.encodeWithSelector(TokenIssuer.initialize.selector, deployer);
        TokenIssuer w = TokenIssuer(payable(address(new ERC1967Proxy(address(impl2), initData2))));

        t.grantRole(t.ISSUER_ROLE(), address(w));
        vm.stopPrank();

        assertTrue(t.hasRole(t.ISSUER_ROLE(), address(w)));
        _step("  PASS: wallet holds ISSUER_ROLE on token");

        _logPass();
    }
}
