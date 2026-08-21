// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract DummyContract {}

contract FactoryQA is BaseQA {
    string constant MODULE = "Factory";

    // ═══════════════════════════════════════════════
    //      FT-INIT — 构造
    // ═══════════════════════════════════════════════

    // ── FT-INIT-01 ──
    function test_FTINIT01_ConstructorDeploysBeacon() public {
        _logCase("FT-INIT-01", unicode"构造部署 beacon");

        _step("[Step 1] check beacon is non-zero and admin has role");
        assertTrue(address(factory.beacon()) != address(0));
        _step("  PASS: beacon address non-zero");
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
        _step("  PASS: admin has DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── FT-INIT-02 ──
    function test_FTINIT02_ZeroCompliance() public {
        _logCase("FT-INIT-02", unicode"零地址 compliance");

        _step("[Step 1] new Factory(address(0), pm, admin, proxyAdmin)");
        vm.expectRevert(ScaledTokenFactory.InvalidComplianceContract.selector);
        new ScaledTokenFactory(address(0), address(pauseManager), admin, proxyAdmin, MIN_MULTIPLIER_NOTICE);
        _step("  PASS: reverted InvalidComplianceContract()");

        _logPass();
    }

    // ── FT-INIT-03 ──
    function test_FTINIT03_ZeroPauseManager() public {
        _logCase("FT-INIT-03", unicode"零地址 pauseManager");

        _step("[Step 1] new Factory(compliance, address(0), admin, proxyAdmin)");
        vm.expectRevert(ScaledTokenFactory.InvalidPauseManagerContract.selector);
        new ScaledTokenFactory(address(compliance), address(0), admin, proxyAdmin, MIN_MULTIPLIER_NOTICE);
        _step("  PASS: reverted InvalidPauseManagerContract()");

        _logPass();
    }

    // ── FT-INIT-04 ──
    function test_FTINIT04_ZeroOwner() public {
        _logCase("FT-INIT-04", unicode"零地址 owner");

        _step("[Step 1] new Factory(c, pm, address(0), proxyAdmin)");
        vm.expectRevert(ScaledTokenFactory.ZeroAddress.selector);
        new ScaledTokenFactory(address(compliance), address(pauseManager), address(0), proxyAdmin, MIN_MULTIPLIER_NOTICE);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── FT-INIT-05 ──
    function test_FTINIT05_ZeroProxyAdmin() public {
        _logCase("FT-INIT-05", unicode"零地址 proxyAdmin");

        _step("[Step 1] new Factory(c, pm, admin, address(0))");
        vm.expectRevert(ScaledTokenFactory.ZeroAddress.selector);
        new ScaledTokenFactory(address(compliance), address(pauseManager), admin, address(0), MIN_MULTIPLIER_NOTICE);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── FT-INIT-06 ──
    function test_FTINIT06_InvalidComplianceContract() public {
        _logCase("FT-INIT-06", unicode"无效 compliance 合约");

        _step("[Step 1] new Factory(dummyContract, pm, admin, proxyAdmin)");
        address dummy = address(new DummyContract());
        vm.expectRevert(ScaledTokenFactory.InvalidComplianceContract.selector);
        new ScaledTokenFactory(dummy, address(pauseManager), admin, proxyAdmin, MIN_MULTIPLIER_NOTICE);
        _step("  PASS: reverted InvalidComplianceContract()");

        _logPass();
    }

    // ── FT-INIT-07 ──
    function test_FTINIT07_InvalidPauseManagerContract() public {
        _logCase("FT-INIT-07", unicode"无效 pauseManager 合约");

        _step("[Step 1] new Factory(compliance, dummyContract, admin, proxyAdmin)");
        address dummy = address(new DummyContract());
        vm.expectRevert(ScaledTokenFactory.InvalidPauseManagerContract.selector);
        new ScaledTokenFactory(address(compliance), dummy, admin, proxyAdmin, MIN_MULTIPLIER_NOTICE);
        _step("  PASS: reverted InvalidPauseManagerContract()");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      FT-DEP — 部署
    // ═══════════════════════════════════════════════

    // ── FT-DEP-01 ──
    function test_FTDEP01_AdminCanDeploy() public {
        _logCase("FT-DEP-01", unicode"admin 可部署");

        _step("[Step 1] admin deploys a new token");
        uint256 countBefore = factory.tokenCount();
        address[] memory empty = new address[](0);
        vm.prank(admin);
        factory.createToken("Tesla", "TSLA", "US88160R1014", admin, empty, empty);
        assertEq(factory.tokenCount(), countBefore + 1);
        _step("  PASS: tokenCount increased by 1");

        _logPass();
    }

    // ── FT-DEP-02 ──
    function test_FTDEP02_NonAdminCannotDeploy() public {
        _logCase("FT-DEP-02", unicode"非 admin 不能部署");

        _step("[Step 1] stranger tries createToken");
        address[] memory empty = new address[](0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, FACTORY_OPS_ROLE));
        factory.createToken("Tesla", "TSLA", "US88160R1014", admin, empty, empty);
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── FT-DEP-03 ──
    function test_FTDEP03_DuplicateSymbolReverts() public {
        _logCase("FT-DEP-03", unicode"重复 symbol");

        _step("[Step 1] deploy AAPL again (already exists from setUp)");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ScaledTokenFactory.TokenSymbolAlreadyExists.selector, "AAPL"));
        factory.createToken("Apple 2", "AAPL", "ID", admin, empty, empty);
        _step("  PASS: reverted TokenSymbolAlreadyExists(AAPL)");

        _logPass();
    }

    // ── FT-DEP-04 ──
    function test_FTDEP04_InvalidSymbolSpecialChars() public {
        _logCase("FT-DEP-04", unicode"无效 symbol（特殊字符）");

        _step("[Step 1] createToken with symbol = 'AAPL!'");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ScaledTokenFactory.InvalidSymbol.selector, "AAPL!"));
        factory.createToken("Name", "AAPL!", "ID", admin, empty, empty);
        _step("  PASS: reverted InvalidSymbol");

        _logPass();
    }

    // ── FT-DEP-05 ──
    function test_FTDEP05_InvalidSymbolSpace() public {
        _logCase("FT-DEP-05", unicode"无效 symbol（空格）");

        _step("[Step 1] createToken with symbol = 'AA PL'");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ScaledTokenFactory.InvalidSymbol.selector, "AA PL"));
        factory.createToken("Name", "AA PL", "ID", admin, empty, empty);
        _step("  PASS: reverted InvalidSymbol");

        _logPass();
    }

    // ── FT-DEP-06 ──
    function test_FTDEP06_SymbolTooLong() public {
        _logCase("FT-DEP-06", unicode"symbol 超 32 字符");

        _step("[Step 1] createToken with 33-char symbol");
        string memory longSym = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567";
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ScaledTokenFactory.InvalidSymbol.selector, longSym));
        factory.createToken("Name", longSym, "ID", admin, empty, empty);
        _step("  PASS: reverted InvalidSymbol");

        _logPass();
    }

    // ── FT-DEP-07 ──
    function test_FTDEP07_ValidSymbolVariants() public {
        _logCase("FT-DEP-07", unicode"合法 symbol 变体");

        _step("[Step 1] deploy with 'BTC-USD', 'TOKEN123', 'aapl'");
        address[] memory empty = new address[](0);
        vm.startPrank(admin);
        factory.createToken("N1", "BTC-USD", "ID1", admin, empty, empty);
        _step("  PASS: BTC-USD accepted");
        factory.createToken("N2", "TOKEN123", "ID2", admin, empty, empty);
        _step("  PASS: TOKEN123 accepted");
        factory.createToken("N3", "aapl", "ID3", admin, empty, empty);
        _step("  PASS: aapl accepted (case-sensitive, different from AAPL)");
        vm.stopPrank();

        _logPass();
    }

    // ── FT-DEP-08 ──
    function test_FTDEP08_EmptyName() public {
        _logCase("FT-DEP-08", unicode"空 name");

        _step("[Step 1] createToken with name=''");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.EmptyString.selector);
        factory.createToken("", "NEWT", "ID", admin, empty, empty);
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── FT-DEP-09 ──
    function test_FTDEP09_EmptyIdentifier() public {
        _logCase("FT-DEP-09", unicode"空 identifier");

        _step("[Step 1] createToken with identifier=''");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.EmptyString.selector);
        factory.createToken("Name", "NEWT", "", admin, empty, empty);
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── FT-DEP-10 ──
    function test_FTDEP10_ZeroAdmin() public {
        _logCase("FT-DEP-10", unicode"零地址 admin");

        _step("[Step 1] createToken with admin=address(0)");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.ZeroAddress.selector);
        factory.createToken("Name", "NEWT", "ID", address(0), empty, empty);
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── FT-DEP-11 ──
    function test_FTDEP11_PostDeployStateCorrect() public {
        _logCase("FT-DEP-11", unicode"部署后初始化验证");

        _step("[Step 1] deploy and verify state");
        address issuerC = address(new TokenIssuer());
        address op = makeAddr("newOp");
        address[] memory issuers = new address[](1);
        issuers[0] = issuerC;
        address[] memory ops = new address[](1);
        ops[0] = op;

        vm.prank(admin);
        address proxy = factory.createToken("Meta", "META", "US30303M1027", admin, issuers, ops);
        ScaledToken t = ScaledToken(proxy);

        assertEq(t.name(), "Meta");
        assertEq(t.symbol(), "META");
        assertEq(t.assetCode(), "US30303M1027");
        assertTrue(t.hasRole(DEFAULT_ADMIN_ROLE_HASH, admin));
        assertTrue(t.hasRole(ISSUER_ROLE, issuerC));
        assertTrue(t.hasRole(MULTIPLIER_SCHEDULER_ROLE, op));
        assertEq(t.totalSupply(), 0);
        assertTrue(t.mintAllowed());
        assertTrue(t.burnAllowed());
        _step("  PASS: all initial state matches parameters");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      FT-REG — 注册
    // ═══════════════════════════════════════════════

    // ── FT-REG-01 ──
    function test_FTREG01_TokenBySymbol() public {
        _logCase("FT-REG-01", unicode"tokenBySymbol");

        _step("[Step 1] query tokenBySymbol('AAPL')");
        assertEq(factory.tokenBySymbol("AAPL"), address(token));
        _step("  PASS: returns token proxy address");

        _logPass();
    }

    // ── FT-REG-02 ──
    function test_FTREG02_DeployedTokenCount() public {
        _logCase("FT-REG-02", unicode"tokenCount");

        _step("[Step 1] deploy 2 more tokens (AAPL already exists)");
        address[] memory empty = new address[](0);
        vm.startPrank(admin);
        factory.createToken("N1", "GOOG", "ID1", admin, empty, empty);
        factory.createToken("N2", "TSLA", "ID2", admin, empty, empty);
        vm.stopPrank();

        assertEq(factory.tokenCount(), 3);
        _step("  PASS: count == 3");

        _logPass();
    }

    // ── FT-REG-03 ──
    function test_FTREG03_GetAllDeployedTokens() public {
        _logCase("FT-REG-03", unicode"getAllTokens");

        _step("[Step 1] deploy 2 more, then getAllTokens");
        address[] memory empty = new address[](0);
        vm.startPrank(admin);
        factory.createToken("N1", "GOOG", "ID1", admin, empty, empty);
        factory.createToken("N2", "TSLA", "ID2", admin, empty, empty);
        vm.stopPrank();

        address[] memory all = factory.getAllTokens();
        assertEq(all.length, 3);
        _step("  PASS: length == 3");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      FT-PAG — 分页
    // ═══════════════════════════════════════════════

    function _deployFiveTokens() internal {
        address[] memory empty = new address[](0);
        vm.startPrank(admin);
        factory.createToken("N1", "GOOG", "ID1", admin, empty, empty);
        factory.createToken("N2", "TSLA", "ID2", admin, empty, empty);
        factory.createToken("N3", "MSFT", "ID3", admin, empty, empty);
        factory.createToken("N4", "AMZN", "ID4", admin, empty, empty);
        vm.stopPrank();
        // total = 5 (AAPL from setUp + 4 above)
    }

    // ── FT-PAG-01 ──
    function test_FTPAG01_PaginationNormal() public {
        _logCase("FT-PAG-01", unicode"分页正常");

        _step("[Step 1] deploy 5 tokens total, getTokens(0,2)");
        _deployFiveTokens();
        address[] memory page = factory.getTokens(0, 2);
        assertEq(page.length, 2);
        _step("  PASS: returned 2 tokens");

        _logPass();
    }

    // ── FT-PAG-02 ──
    function test_FTPAG02_LastPageShort() public {
        _logCase("FT-PAG-02", unicode"末页不足量");

        _step("[Step 1] deploy 5 tokens, getTokens(4,10)");
        _deployFiveTokens();
        address[] memory page = factory.getTokens(4, 10);
        assertEq(page.length, 1);
        _step("  PASS: returned 1 token (only tokens[4])");

        _logPass();
    }

    // ── FT-PAG-03 ──
    function test_FTPAG03_OffsetBeyondRange() public {
        _logCase("FT-PAG-03", unicode"offset 超出");

        _step("[Step 1] deploy 5, getTokens(10,2)");
        _deployFiveTokens();
        address[] memory page = factory.getTokens(10, 2);
        assertEq(page.length, 0);
        _step("  PASS: empty array");

        _logPass();
    }

    // ── FT-PAG-04 ──
    function test_FTPAG04_LimitZero() public {
        _logCase("FT-PAG-04", unicode"limit 为零");

        _step("[Step 1] getTokens(0,0)");
        _deployFiveTokens();
        address[] memory page = factory.getTokens(0, 0);
        assertEq(page.length, 0);
        _step("  PASS: empty array");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      FT-SYM — Symbol 更新
    // ═══════════════════════════════════════════════

    // ── FT-SYM-01 ──
    function test_FTSYM01_UpdateSymbol() public {
        _logCase("FT-SYM-01", unicode"renameSymbol");

        _step("[Step 1] token.updateSymbol first, then factory.renameSymbol");
        vm.prank(tokenOps);
        token.updateSymbol("AAPL2");
        vm.prank(admin);
        factory.renameSymbol(address(token), "AAPL", "AAPL2");
        assertEq(factory.tokenBySymbol("AAPL2"), address(token));
        assertEq(factory.tokenBySymbol("AAPL"), address(0));
        _step("  PASS: mapping updated");

        _logPass();
    }

    // ── FT-SYM-02 ──
    function test_FTSYM02_NonAdminCannotUpdate() public {
        _logCase("FT-SYM-02", unicode"非 admin 不能更新");

        _step("[Step 1] stranger tries updateSymbol");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, FACTORY_OPS_ROLE));
        factory.renameSymbol(address(token), "AAPL", "AAPL2");
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ── FT-SYM-03 ──
    function test_FTSYM03_OldSymbolMismatch() public {
        _logCase("FT-SYM-03", unicode"旧 symbol 不匹配");

        _step("[Step 1] renameSymbol with wrong oldSymbol");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ScaledTokenFactory.TokenNotRegisteredUnderSymbol.selector, address(token), "WRONG"));
        factory.renameSymbol(address(token), "WRONG", "NEW");
        _step("  PASS: reverted TokenNotRegisteredUnderSymbol");

        _logPass();
    }

    // ── FT-SYM-04 ──
    function test_FTSYM04_NewSymbolAlreadyTaken() public {
        _logCase("FT-SYM-04", unicode"新 symbol 已占用");

        _step("[Step 1] deploy GOOG, update token symbol to GOOG, then renameSymbol hits duplicate");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        factory.createToken("Google", "GOOG", "ID", admin, empty, empty);
        vm.prank(tokenOps);
        token.updateSymbol("GOOG");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ScaledTokenFactory.TokenSymbolAlreadyExists.selector, "GOOG"));
        factory.renameSymbol(address(token), "AAPL", "GOOG");
        _step("  PASS: reverted TokenSymbolAlreadyExists(GOOG)");

        _logPass();
    }

    // ── FT-SYM-05 ──
    function test_FTSYM05_EmptyNewSymbol() public {
        _logCase("FT-SYM-05", unicode"空新 symbol");

        _step("[Step 1] updateSymbol with newSymbol=''");
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.EmptyString.selector);
        factory.renameSymbol(address(token), "AAPL", "");
        _step("  PASS: reverted EmptyString()");

        _logPass();
    }

    // ── FT-SYM-06 ──
    function test_FTSYM06_InvalidNewSymbol() public {
        _logCase("FT-SYM-06", unicode"无效新 symbol");

        _step("[Step 1] updateSymbol with newSymbol='AA!!'");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ScaledTokenFactory.InvalidSymbol.selector, "AA!!"));
        factory.renameSymbol(address(token), "AAPL", "AA!!");
        _step("  PASS: reverted InvalidSymbol");

        _logPass();
    }

    // ── FT-SYM-07 ──
    function test_FTSYM07_SetSymbolWithoutFactorySync() public {
        _logCase("FT-SYM-07", unicode"updateSymbol 后 factory 不同步");

        _step("[Step 1] token.updateSymbol('NEW') without calling factory.renameSymbol");
        vm.prank(tokenOps);
        token.updateSymbol("NEW");

        assertEq(factory.tokenBySymbol("AAPL"), address(token));
        _step("  PASS: factory still maps AAPL -> token (not synced)");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      FT-CFG — 配置
    // ═══════════════════════════════════════════════

    // ── FT-CFG-01 ──
    function test_FTCFG01_UpdateCompliance() public {
        _logCase("FT-CFG-01", unicode"更新 compliance");

        _step("[Step 1] deploy new ComplianceRegistry, setDefaultCompliance on factory");
        ComplianceRegistry newC = new ComplianceRegistry(admin);
        vm.prank(admin);
        factory.setDefaultCompliance(address(newC));
        assertEq(factory.defaultCompliance(), address(newC));
        _step("  PASS: compliance updated");

        _logPass();
    }

    // ── FT-CFG-02 ──
    function test_FTCFG02_UpdatePauseManager() public {
        _logCase("FT-CFG-02", unicode"更新 pauseManager");

        _step("[Step 1] deploy new PauseRegistry, setDefaultPauseManager on factory");
        PauseRegistry newPM = new PauseRegistry(admin);
        vm.prank(admin);
        factory.setDefaultPauseManager(address(newPM));
        assertEq(factory.defaultPauseManager(), address(newPM));
        _step("  PASS: pauseManager updated");

        _logPass();
    }

    // ── FT-CFG-03 ──
    function test_FTCFG03_ZeroAddressComplianceReverts() public {
        _logCase("FT-CFG-03", unicode"零地址回滚");

        _step("[Step 1] setDefaultCompliance(address(0))");
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.ZeroAddress.selector);
        factory.setDefaultCompliance(address(0));
        _step("  PASS: reverted ZeroAddress()");

        _logPass();
    }

    // ── FT-CFG-04 ──
    function test_FTCFG04_InvalidComplianceReverts() public {
        _logCase("FT-CFG-04", unicode"无效合约回滚");

        _step("[Step 1] setDefaultCompliance(random contract)");
        address dummy = address(new DummyContract());
        vm.prank(admin);
        vm.expectRevert(ScaledTokenFactory.InvalidComplianceContract.selector);
        factory.setDefaultCompliance(dummy);
        _step("  PASS: reverted InvalidComplianceContract()");

        _logPass();
    }

    // ── FT-CFG-05 ──
    function test_FTCFG05_NonAdminCannotUpdateConfig() public {
        _logCase("FT-CFG-05", unicode"非 admin 不能更新");

        _step("[Step 1] stranger tries setDefaultCompliance");
        ComplianceRegistry newC = new ComplianceRegistry(admin);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, DEFAULT_ADMIN_ROLE_HASH));
        factory.setDefaultCompliance(address(newC));
        _step("  PASS: reverted (AccessControl)");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      FT-AC — AssetCode 唯一性 + renameAssetCode
    // ═══════════════════════════════════════════════

    // ── FT-AC-01 ──
    function test_FTAC01_DuplicateAssetCodeReverts() public {
        _logCase("FT-AC-01", unicode"重复 assetCode 回滚");

        _step("[Step 1] create token with same assetCode as AAPL (US0378331005)");
        address[] memory empty = new address[](0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ScaledTokenFactory.AssetCodeAlreadyExists.selector, "US0378331005"));
        factory.createToken("Apple2", "AAPL2", "US0378331005", admin, empty, empty);
        _step("  PASS: reverted AssetCodeAlreadyExists");

        _logPass();
    }

    // ── FT-AC-02 ──
    function test_FTAC02_TokenByAssetCode() public {
        _logCase("FT-AC-02", unicode"tokenByAssetCode 正确返回");

        _step("[Step 1] query tokenByAssetCode('US0378331005')");
        assertEq(factory.tokenByAssetCode("US0378331005"), address(token));
        _step("  PASS: returns token proxy address");

        _logPass();
    }

    // ── FT-AC-03 ──
    function test_FTAC03_RenameAssetCode() public {
        _logCase("FT-AC-03", unicode"renameAssetCode 成功");

        _step("[Step 1] token.updateAssetCode first, then factory.renameAssetCode");
        vm.prank(tokenOps);
        token.updateAssetCode("NEWCODE");
        vm.prank(admin);
        factory.renameAssetCode(address(token), "US0378331005", "NEWCODE");
        assertEq(factory.tokenByAssetCode("NEWCODE"), address(token));
        assertEq(factory.tokenByAssetCode("US0378331005"), address(0));
        _step("  PASS: mapping updated");

        _logPass();
    }

    // ── FT-AC-04 ──
    function test_FTAC04_RenameAssetCodeWrongOld() public {
        _logCase("FT-AC-04", unicode"renameAssetCode 旧值不匹配回滚");

        _step("[Step 1] renameAssetCode with wrong oldAssetCode");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ScaledTokenFactory.TokenNotRegisteredUnderAssetCode.selector, address(token), "WRONG"));
        factory.renameAssetCode(address(token), "WRONG", "NEW");
        _step("  PASS: reverted TokenNotRegisteredUnderAssetCode");

        _logPass();
    }
}
