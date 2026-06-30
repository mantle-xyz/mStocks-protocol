// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {PauseManager} from "../../src/pauseManager/PauseManager.sol";
import {SecuritiesTokenFactory} from "../../src/securitiesToken/SecuritiesTokenFactory.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {OperatorWallet} from "../../src/OperatorWallet/OperatorWallet.sol";

contract DeployQA is Test {
    string constant MODULE = unicode"部署";

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
        Compliance c = new Compliance(deployer);
        assertTrue(address(c) != address(0));
        _step("  Compliance deployed");

        _step("[Step 2] deployPauseManager");
        PauseManager pm = new PauseManager(deployer);
        assertTrue(address(pm) != address(0));
        _step("  PauseManager deployed");

        _step("[Step 3] deployFactory");
        SecuritiesTokenFactory f = new SecuritiesTokenFactory(address(c), address(pm), deployer, proxyAdmin);
        assertTrue(address(f) != address(0));
        _step("  Factory deployed");

        _step("[Step 4] deployToken");
        address issuerContract = address(new OperatorWallet());
        address[] memory issuers = new address[](1);
        issuers[0] = issuerContract;
        address[] memory operators = new address[](0);
        address proxy = f.deployToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, operators);
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
        Compliance c = new Compliance(deployer);
        PauseManager pm = new PauseManager(deployer);
        SecuritiesTokenFactory f = new SecuritiesTokenFactory(address(c), address(pm), deployer, proxyAdmin);
        address issuerContract = address(new OperatorWallet());
        address[] memory issuers = new address[](1);
        issuers[0] = issuerContract;
        address[] memory operators = new address[](0);
        address proxy = f.deployToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, operators);
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
        Compliance c = new Compliance(deployer);
        PauseManager pm = new PauseManager(deployer);
        SecuritiesTokenFactory f = new SecuritiesTokenFactory(address(c), address(pm), deployer, proxyAdmin);
        address issuerContract = address(new OperatorWallet());
        address[] memory issuers = new address[](1);
        issuers[0] = issuerContract;
        address[] memory operators = new address[](0);
        address proxy = f.deployToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, operators);
        vm.stopPrank();

        SecuritiesToken t = SecuritiesToken(proxy);
        assertEq(t.name(), "Apple Inc.");
        assertEq(t.symbol(), "AAPL");
        assertEq(t.identifier(), "US0378331005");
        _step("  PASS: name/symbol/identifier match config values");

        _logPass();
    }

    // ── DPL-04 ──
    function test_DPL04_DeployerAsAdmin() public {
        _logCase("DPL-04", unicode"部署者作为 admin 持有 DEFAULT_ADMIN_ROLE");

        _step("[Step 1] deploy with deployer as admin");
        vm.startPrank(deployer);
        Compliance c = new Compliance(deployer);
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
        address issuerContract = address(new OperatorWallet());
        address oper = makeAddr("tokenOperator");

        vm.startPrank(deployer);
        Compliance c = new Compliance(deployer);
        c.grantRole(c.OPS_ROLE(), cOps);
        PauseManager pm = new PauseManager(deployer);
        pm.grantRole(pm.OPS_ROLE(), pmOps);
        SecuritiesTokenFactory f = new SecuritiesTokenFactory(address(c), address(pm), deployer, proxyAdmin);
        address[] memory issuers = new address[](1);
        issuers[0] = issuerContract;
        address[] memory operators = new address[](1);
        operators[0] = oper;
        address proxy = f.deployToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, operators);
        vm.stopPrank();

        SecuritiesToken t = SecuritiesToken(proxy);
        assertTrue(c.hasRole(c.OPS_ROLE(), cOps));
        assertTrue(pm.hasRole(pm.OPS_ROLE(), pmOps));
        assertTrue(t.hasRole(t.ISSUER_ROLE(), issuerContract));
        assertTrue(t.hasRole(t.OPS_ROLE(), oper));
        _step("  PASS: all roles assigned correctly");

        _logPass();
    }

    // ── DPL-06 ──
    function test_DPL06_OperatorWalletDeploy() public {
        _logCase("DPL-06", unicode"OperatorWallet 部署");

        _step("[Step 1] deploy OperatorWallet proxy, grant OPS, add hot wallets");
        address owOps = makeAddr("walletOps");
        address hw1 = makeAddr("hw1");
        address hw2 = makeAddr("hw2");

        vm.startPrank(deployer);
        OperatorWallet impl = new OperatorWallet();
        bytes memory initData = abi.encodeWithSelector(OperatorWallet.initialize.selector, deployer);
        OperatorWallet w = OperatorWallet(payable(address(new ERC1967Proxy(address(impl), initData))));
        w.grantRole(w.OPS_ROLE(), owOps);
        w.addHotWallet(hw1);
        w.addHotWallet(hw2);
        vm.stopPrank();

        assertTrue(w.hasRole(w.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(w.hasRole(w.OPS_ROLE(), owOps));
        assertTrue(w.isHotWallet(hw1));
        assertTrue(w.isHotWallet(hw2));
        assertEq(w.numOfHotWallets(), 2);
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE, OPS granted, hot wallets added");

        _logPass();
    }

    // ── DPL-07 ──
    function test_DPL07_OperatorWalletGrantedIssuerRole() public {
        _logCase("DPL-07", unicode"OperatorWallet 获得 ISSUER_ROLE");

        _step("[Step 1] deploy full stack + OperatorWallet, grant ISSUER_ROLE on token");
        vm.startPrank(deployer);
        Compliance c = new Compliance(deployer);
        PauseManager pm = new PauseManager(deployer);
        SecuritiesTokenFactory f = new SecuritiesTokenFactory(address(c), address(pm), deployer, proxyAdmin);
        address[] memory issuers = new address[](0);
        address[] memory operators = new address[](0);
        address proxy = f.deployToken("Apple Inc.", "AAPL", "US0378331005", deployer, issuers, operators);
        SecuritiesToken t = SecuritiesToken(proxy);

        OperatorWallet impl2 = new OperatorWallet();
        bytes memory initData2 = abi.encodeWithSelector(OperatorWallet.initialize.selector, deployer);
        OperatorWallet w = OperatorWallet(payable(address(new ERC1967Proxy(address(impl2), initData2))));

        t.grantRole(t.ISSUER_ROLE(), address(w));
        vm.stopPrank();

        assertTrue(t.hasRole(t.ISSUER_ROLE(), address(w)));
        _step("  PASS: wallet holds ISSUER_ROLE on token");

        _logPass();
    }
}
