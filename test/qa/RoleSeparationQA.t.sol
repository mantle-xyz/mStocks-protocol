// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract RoleSeparationQA is BaseQA {
    string constant MODULE = unicode"角色职责分离";

    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        pauseManager.grantRole(pauseManager.PAUSE_ROLE(), pauser);
        pauseManager.grantRole(pauseManager.UNPAUSE_ROLE(), unpauser);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════
    //      PauseRegistry PAUSE/UNPAUSE 分离
    // ═══════════════════════════════════════════════

    // ── RS-PM-01 ──
    function test_RSPM01_PauserCannotUnpause() public {
        _logCase("RS-PM-01", unicode"PAUSE_ROLE 持有者不能 unpauseToken");

        _step("[Step 1] pauser pauses token");
        vm.prank(pauser);
        pauseManager.pauseToken(address(token));

        _step("[Step 2] pauser tries to unpause -> revert MissingUnpauseRole");
        vm.prank(pauser);
        vm.expectRevert(PauseRegistry.MissingUnpauseRole.selector);
        pauseManager.unpauseToken(address(token));
        _step("  PASS: reverted MissingUnpauseRole");

        _logPass();
    }

    // ── RS-PM-02 ──
    function test_RSPM02_UnpauserCannotPause() public {
        _logCase("RS-PM-02", unicode"UNPAUSE_ROLE 持有者不能 pauseToken");

        _step("[Step 1] unpauser tries to pause -> revert MissingPauseRole");
        vm.prank(unpauser);
        vm.expectRevert(PauseRegistry.MissingPauseRole.selector);
        pauseManager.pauseToken(address(token));
        _step("  PASS: reverted MissingPauseRole");

        _logPass();
    }

    // ── RS-PM-03 ──
    function test_RSPM03_SplitRolesCompose() public {
        _logCase("RS-PM-03", unicode"pauser 暂停 + unpauser 解除 -> 正常");

        _step("[Step 1] mint to userA");
        _issuerMint(100e18);
        vm.prank(issuer);
        token.transfer(userA, 100e18);

        _step("[Step 2] pauser pauses token");
        vm.prank(pauser);
        pauseManager.pauseToken(address(token));
        assertTrue(pauseManager.isTokenPaused(address(token)));
        _step("  token is paused");

        _step("[Step 3] unpauser unpauses token");
        vm.prank(unpauser);
        pauseManager.unpauseToken(address(token));
        assertFalse(pauseManager.isTokenPaused(address(token)));
        _step("  token is unpaused");

        _step("[Step 4] transfer succeeds after unpause");
        vm.prank(userA);
        token.transfer(userB, 50e18);
        assertEq(token.balanceOf(userB), 50e18);
        _step("  PASS: split roles compose correctly");

        _logPass();
    }

    // ── RS-PM-04 ──
    function test_RSPM04_PauserCannotUnpauseGlobally() public {
        _logCase("RS-PM-04", unicode"PAUSE_ROLE 持有者不能 unpauseGlobally");

        _step("[Step 1] pauser pauseGlobally");
        vm.prank(pauser);
        pauseManager.pauseGlobally();

        _step("[Step 2] pauser tries unpauseGlobally -> revert");
        vm.prank(pauser);
        vm.expectRevert(PauseRegistry.MissingUnpauseRole.selector);
        pauseManager.unpauseGlobally();
        _step("  PASS: reverted MissingUnpauseRole");

        _logPass();
    }

    // ── RS-PM-05 ──
    function test_RSPM05_UnpauserCannotPauseGlobally() public {
        _logCase("RS-PM-05", unicode"UNPAUSE_ROLE 持有者不能 pauseGlobally");

        _step("[Step 1] unpauser tries pauseGlobally -> revert");
        vm.prank(unpauser);
        vm.expectRevert(PauseRegistry.MissingPauseRole.selector);
        pauseManager.pauseGlobally();
        _step("  PASS: reverted MissingPauseRole");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      ScaledToken OPS_ROLE 分离
    // ═══════════════════════════════════════════════

    // ── RS-TK-01 ──
    function test_RSTK01_AdminWithoutOpsCannotUpdateName() public {
        _logCase("RS-TK-01", unicode"admin(无 OPS) 不能 updateName");

        _step("[Step 1] admin tries updateName -> revert");
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, TOKEN_OPS_ROLE)
        );
        token.updateName("Hacked");
        _step("  PASS: reverted AccessControlUnauthorizedAccount(admin, OPS_ROLE)");

        _logPass();
    }

    // ── RS-TK-02 ──
    function test_RSTK02_AdminWithoutOpsCannotSetMintAllowed() public {
        _logCase("RS-TK-02", unicode"admin(无 OPS) 不能 setMintAllowed");

        _step("[Step 1] admin tries setMintAllowed(false) -> revert");
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, TOKEN_OPS_ROLE)
        );
        token.setMintAllowed(false);
        _step("  PASS: reverted AccessControlUnauthorizedAccount(admin, OPS_ROLE)");

        _logPass();
    }

    // ── RS-TK-03 ──
    function test_RSTK03_OpsCanDoAllMetadataAndSwitches() public {
        _logCase("RS-TK-03", unicode"tokenOps 可执行全部 metadata 和开关操作");

        _step("[Step 1] tokenOps updateName");
        vm.startPrank(tokenOps);
        token.updateName("New Name");
        assertEq(token.name(), "New Name");
        _step("  PASS: updateName succeeded");

        _step("[Step 2] tokenOps updateSymbol");
        token.updateSymbol("NEWT");
        assertEq(token.symbol(), "NEWT");
        _step("  PASS: updateSymbol succeeded");

        _step("[Step 3] tokenOps updateAssetCode");
        token.updateAssetCode("US9999999999");
        assertEq(token.assetCode(), "US9999999999");
        _step("  PASS: updateAssetCode succeeded");

        _step("[Step 4] tokenOps setMintAllowed(false) then true");
        token.setMintAllowed(false);
        assertFalse(token.mintAllowed());
        token.setMintAllowed(true);
        assertTrue(token.mintAllowed());
        _step("  PASS: setMintAllowed succeeded");

        _step("[Step 5] tokenOps setBurnAllowed(false) then true");
        token.setBurnAllowed(false);
        assertFalse(token.burnAllowed());
        token.setBurnAllowed(true);
        assertTrue(token.burnAllowed());
        _step("  PASS: setBurnAllowed succeeded");

        vm.stopPrank();

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      ScaledTokenFactory OPS_ROLE 分离
    // ═══════════════════════════════════════════════

    // ── RS-FT-01 ──
    function test_RSFT01_AdminWithoutOpsCannotCreateToken() public {
        _logCase("RS-FT-01", unicode"admin(无 OPS) 不能 createToken");

        _step("[Step 1] deploy fresh factory, do NOT grant OPS_ROLE to admin");
        address freshAdmin = makeAddr("freshAdmin");
        vm.startPrank(freshAdmin);
        ScaledTokenFactory f2 = new ScaledTokenFactory(
            address(compliance), address(pauseManager), freshAdmin, proxyAdmin, MIN_MULTIPLIER_NOTICE
        );

        _step("[Step 2] freshAdmin tries createToken -> revert");
        address[] memory empty = new address[](0);
        bytes32 f2OpsRole = f2.OPS_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, freshAdmin, f2OpsRole)
        );
        f2.createToken("Test", "TST", "ID001", freshAdmin, empty, empty, empty);
        vm.stopPrank();
        _step("  PASS: reverted AccessControlUnauthorizedAccount(freshAdmin, OPS_ROLE)");

        _logPass();
    }

    // ── RS-FT-02 ──
    function test_RSFT02_AdminWithoutOpsCannotRename() public {
        _logCase("RS-FT-02", unicode"admin(无 OPS) 不能 renameSymbol");

        _step("[Step 1] deploy fresh factory, grant OPS to a factoryOps, create token");
        address freshAdmin = makeAddr("freshAdmin");
        address factoryOps = makeAddr("factoryOps");
        vm.startPrank(freshAdmin);
        ScaledTokenFactory f2 = new ScaledTokenFactory(
            address(compliance), address(pauseManager), freshAdmin, proxyAdmin, MIN_MULTIPLIER_NOTICE
        );
        f2.grantRole(f2.OPS_ROLE(), factoryOps);
        vm.stopPrank();

        vm.prank(factoryOps);
        address[] memory empty = new address[](0);
        address proxy = f2.createToken("Test", "TST", "ID001", freshAdmin, empty, empty, empty);

        _step("[Step 2] freshAdmin tries renameSymbol -> revert");
        bytes32 f2OpsRole = f2.OPS_ROLE();
        vm.prank(freshAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, freshAdmin, f2OpsRole)
        );
        f2.renameSymbol(proxy, "TST", "NEWT");
        _step("  PASS: reverted AccessControlUnauthorizedAccount(freshAdmin, OPS_ROLE)");

        _logPass();
    }

    // ── RS-FT-03 ──
    function test_RSFT03_OpsCanCreateAndRename() public {
        _logCase("RS-FT-03", unicode"factoryOps 可 createToken + renameSymbol + renameAssetCode");

        _step("[Step 1] deploy fresh factory, grant OPS to factoryOps");
        address freshAdmin = makeAddr("freshAdmin");
        address factoryOps = makeAddr("factoryOps");
        vm.startPrank(freshAdmin);
        ScaledTokenFactory f2 = new ScaledTokenFactory(
            address(compliance), address(pauseManager), freshAdmin, proxyAdmin, MIN_MULTIPLIER_NOTICE
        );
        f2.grantRole(f2.OPS_ROLE(), factoryOps);
        vm.stopPrank();

        _step("[Step 2] factoryOps createToken");
        vm.prank(factoryOps);
        address[] memory empty = new address[](0);
        address proxy = f2.createToken("Test", "TST", "ID001", freshAdmin, empty, empty, empty);
        assertTrue(proxy != address(0));
        _step("  PASS: createToken succeeded");

        _step("[Step 3] grant token OPS_ROLE to factoryOps, updateSymbol, then renameSymbol");
        ScaledToken t = ScaledToken(proxy);
        bytes32 tokenOpsRole = t.OPS_ROLE();
        vm.prank(freshAdmin);
        t.grantRole(tokenOpsRole, factoryOps);

        vm.startPrank(factoryOps);
        t.updateSymbol("NEWT");
        f2.renameSymbol(proxy, "TST", "NEWT");
        assertEq(t.symbol(), "NEWT");
        _step("  PASS: renameSymbol succeeded");

        _step("[Step 4] updateAssetCode then renameAssetCode");
        t.updateAssetCode("US1111111111");
        f2.renameAssetCode(proxy, "ID001", "US1111111111");
        assertEq(t.assetCode(), "US1111111111");
        _step("  PASS: renameAssetCode succeeded");

        vm.stopPrank();

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      OPS_ROLE admin 关系验证
    // ═══════════════════════════════════════════════

    // ── RS-TK-04 ──
    function test_RSTK04_OpsRoleAdminIsDefaultAdmin() public {
        _logCase("RS-TK-04", unicode"token.getRoleAdmin(OPS_ROLE) == DEFAULT_ADMIN_ROLE");

        _step("[Step 1] query getRoleAdmin(OPS_ROLE)");
        bytes32 roleAdmin = token.getRoleAdmin(TOKEN_OPS_ROLE);
        assertEq(roleAdmin, DEFAULT_ADMIN_ROLE_HASH);
        _step("  PASS: OPS_ROLE admin is DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── RS-FT-04 ──
    function test_RSFT04_OpsRoleAdminIsDefaultAdmin() public {
        _logCase("RS-FT-04", unicode"factory.getRoleAdmin(OPS_ROLE) == DEFAULT_ADMIN_ROLE");

        _step("[Step 1] query getRoleAdmin(OPS_ROLE)");
        bytes32 roleAdmin = factory.getRoleAdmin(FACTORY_OPS_ROLE);
        assertEq(roleAdmin, DEFAULT_ADMIN_ROLE_HASH);
        _step("  PASS: factory OPS_ROLE admin is DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      OPS 不能越权 admin 功能（双向隔离）
    // ═══════════════════════════════════════════════

    // ── RS-TK-05 ──
    function test_RSTK05_OpsCannotUpdateCompliance() public {
        _logCase("RS-TK-05", unicode"tokenOps 不能 updateCompliance (admin-only)");

        _step("[Step 1] tokenOps tries updateCompliance -> revert");
        vm.prank(tokenOps);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, tokenOps, DEFAULT_ADMIN_ROLE_HASH)
        );
        token.updateCompliance(address(compliance));
        _step("  PASS: reverted AccessControlUnauthorizedAccount(tokenOps, DEFAULT_ADMIN_ROLE)");

        _logPass();
    }

    // ── RS-TK-06 ──
    function test_RSTK06_OpsCannotUpdatePauseManager() public {
        _logCase("RS-TK-06", unicode"tokenOps 不能 updatePauseManager (admin-only)");

        _step("[Step 1] tokenOps tries updatePauseManager -> revert");
        vm.prank(tokenOps);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, tokenOps, DEFAULT_ADMIN_ROLE_HASH)
        );
        token.updatePauseManager(address(pauseManager));
        _step("  PASS: reverted AccessControlUnauthorizedAccount(tokenOps, DEFAULT_ADMIN_ROLE)");

        _logPass();
    }

    // ── RS-FT-05 ──
    function test_RSFT05_OpsCannotSetDefaultCompliance() public {
        _logCase("RS-FT-05", unicode"factoryOps 不能 setDefaultCompliance (admin-only)");

        _step("[Step 1] grant OPS to a factoryOps on existing factory");
        address factoryOps = makeAddr("factoryOps");
        vm.prank(admin);
        factory.grantRole(FACTORY_OPS_ROLE, factoryOps);

        _step("[Step 2] factoryOps tries setDefaultCompliance -> revert");
        vm.prank(factoryOps);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, factoryOps, DEFAULT_ADMIN_ROLE_HASH)
        );
        factory.setDefaultCompliance(address(compliance));
        _step("  PASS: reverted AccessControlUnauthorizedAccount(factoryOps, DEFAULT_ADMIN_ROLE)");

        _logPass();
    }

    // ── RS-FT-06 ──
    function test_RSFT06_OpsCannotSetDefaultPauseManager() public {
        _logCase("RS-FT-06", unicode"factoryOps 不能 setDefaultPauseManager (admin-only)");

        _step("[Step 1] grant OPS to a factoryOps on existing factory");
        address factoryOps = makeAddr("factoryOps");
        vm.prank(admin);
        factory.grantRole(FACTORY_OPS_ROLE, factoryOps);

        _step("[Step 2] factoryOps tries setDefaultPauseManager -> revert");
        vm.prank(factoryOps);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, factoryOps, DEFAULT_ADMIN_ROLE_HASH)
        );
        factory.setDefaultPauseManager(address(pauseManager));
        _step("  PASS: reverted AccessControlUnauthorizedAccount(factoryOps, DEFAULT_ADMIN_ROLE)");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      PauseRegistry roleAdmin 验证
    // ═══════════════════════════════════════════════

    // ── RS-PM-06 ──
    function test_RSPM06_PauseRoleAdminIsDefaultAdmin() public {
        _logCase("RS-PM-06", unicode"pauseManager.getRoleAdmin(PAUSE_ROLE) == DEFAULT_ADMIN_ROLE");

        _step("[Step 1] query getRoleAdmin(PAUSE_ROLE)");
        bytes32 roleAdmin = pauseManager.getRoleAdmin(PAUSE_MANAGER_PAUSE_ROLE);
        assertEq(roleAdmin, DEFAULT_ADMIN_ROLE_HASH);
        _step("  PASS: PAUSE_ROLE admin is DEFAULT_ADMIN_ROLE");

        _logPass();
    }

    // ── RS-PM-07 ──
    function test_RSPM07_UnpauseRoleAdminIsDefaultAdmin() public {
        _logCase("RS-PM-07", unicode"pauseManager.getRoleAdmin(UNPAUSE_ROLE) == DEFAULT_ADMIN_ROLE");

        _step("[Step 1] query getRoleAdmin(UNPAUSE_ROLE)");
        bytes32 roleAdmin = pauseManager.getRoleAdmin(PAUSE_MANAGER_UNPAUSE_ROLE);
        assertEq(roleAdmin, DEFAULT_ADMIN_ROLE_HASH);
        _step("  PASS: UNPAUSE_ROLE admin is DEFAULT_ADMIN_ROLE");

        _logPass();
    }
}
