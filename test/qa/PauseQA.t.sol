// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {PauseGuardUpgradeable} from "../../src/pauseRegistry/PauseGuardUpgradeable.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";

contract PauseQA is BaseQA {
    string constant MODULE = unicode"代币暂停";

    ScaledToken internal tokenB;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        address[] memory empty = new address[](0);
        tokenB = ScaledToken(factory.createToken("Google", "GOOG", "US02079K3059", admin, empty, empty));
        vm.stopPrank();
    }

    // ── ST-PSE-01 ──
    function test_STPSE01_PauseBlocksTransfer() public {
        _logCase("ST-PSE-01", unicode"单 token 暂停阻止转账");

        _step("[Step 1] issuer mints 100e18, transfers to userA");
        _issuerMint(100e18);
        vm.prank(issuer);
        token.transfer(userA, 100e18);

        _step("[Step 2] pauseOps pauses token");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        _step("[Step 3] userA tries to transfer");
        vm.prank(userA);
        vm.expectRevert(PauseGuardUpgradeable.TokenPaused.selector);
        token.transfer(userB, 50e18);
        _step("  PASS: reverted TokenPaused()");

        _logPass();
    }

    // ── ST-PSE-02 ──
    function test_STPSE02_PauseBlocksMint() public {
        _logCase("ST-PSE-02", unicode"暂停阻止铸造");

        _step("[Step 1] pauseOps pauses token");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        _step("[Step 2] issuer tries to mint");
        vm.prank(issuer);
        vm.expectRevert(PauseGuardUpgradeable.TokenPaused.selector);
        token.mint(100e18);
        _step("  PASS: reverted TokenPaused()");

        _logPass();
    }

    // ── ST-PSE-03 ──
    function test_STPSE03_PauseBlocksBurn() public {
        _logCase("ST-PSE-03", unicode"暂停阻止销毁");

        _step("[Step 1] issuer mints, then token is paused");
        _issuerMint(100e18);
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        _step("[Step 2] issuer tries to burn");
        vm.prank(issuer);
        vm.expectRevert(PauseGuardUpgradeable.TokenPaused.selector);
        token.burn(50e18);
        _step("  PASS: reverted TokenPaused()");

        _logPass();
    }

    // ── ST-PSE-04 ──
    function test_STPSE04_UnpauseRestoresTransfer() public {
        _logCase("ST-PSE-04", unicode"解除暂停后恢复");

        _step("[Step 1] mint to userA, pause then unpause");
        _issuerMint(100e18);
        vm.prank(issuer);
        token.transfer(userA, 100e18);

        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));
        vm.prank(pauseOps);
        pauseManager.unpauseToken(address(token));

        _step("[Step 2] userA transfers after unpause");
        vm.prank(userA);
        token.transfer(userB, 50e18);
        assertEq(token.balanceOf(userB), 50e18);
        _step("  PASS: transfer succeeded after unpause");

        _logPass();
    }

    // ── ST-PSE-05 ──
    function test_STPSE05_PauseAllBlocksTransfer() public {
        _logCase("ST-PSE-05", unicode"全局暂停");

        _step("[Step 1] mint to userA, pauseGlobally");
        _issuerMint(100e18);
        vm.prank(issuer);
        token.transfer(userA, 100e18);

        vm.prank(pauseOps);
        pauseManager.pauseGlobally();

        _step("[Step 2] userA tries to transfer");
        vm.prank(userA);
        vm.expectRevert(PauseGuardUpgradeable.TokenPaused.selector);
        token.transfer(userB, 50e18);
        _step("  PASS: reverted TokenPaused()");

        _logPass();
    }

    // ── ST-PSE-06 ──
    function test_STPSE06_UnpauseAllRestores() public {
        _logCase("ST-PSE-06", unicode"全局解除暂停");

        _step("[Step 1] mint to userA, pauseAll then unpauseAll");
        _issuerMint(100e18);
        vm.prank(issuer);
        token.transfer(userA, 100e18);

        vm.prank(pauseOps);
        pauseManager.pauseGlobally();
        vm.prank(pauseOps);
        pauseManager.unpauseGlobally();

        _step("[Step 2] userA transfers");
        vm.prank(userA);
        token.transfer(userB, 50e18);
        assertEq(token.balanceOf(userB), 50e18);
        _step("  PASS: transfer succeeded after unpauseAll");

        _logPass();
    }

    // ── ST-PSE-07 ──
    function test_STPSE07_PauseAllOverridesSingleUnpause() public {
        _logCase("ST-PSE-07", unicode"全局暂停覆盖单 token 解除");

        _step("[Step 1] pauseToken + pauseGlobally + unpauseToken");
        vm.startPrank(pauseOps);
        pauseManager.pauseToken(address(token));
        pauseManager.pauseGlobally();
        pauseManager.unpauseToken(address(token));
        vm.stopPrank();

        _step("[Step 2] isTokenPaused still true (global overrides)");
        assertTrue(pauseManager.isTokenPaused(address(token)));
        _step("  PASS: isTokenPaused == true");

        _step("[Step 3] mint reverts under global pause");
        vm.prank(issuer);
        vm.expectRevert(PauseGuardUpgradeable.TokenPaused.selector);
        token.mint(1e18);
        _step("  PASS: mint reverted under global pause despite single-token unpause");

        _logPass();
    }

    // ── ST-PSE-08 ──
    function test_STPSE08_PauseOneDoesNotAffectOther() public {
        _logCase("ST-PSE-08", unicode"暂停一个不影响其他");

        _step("[Step 1] grant issuer on tokenB, mint, transfer to userA");
        address tokenBIssuer = address(new TokenIssuer());
        vm.startPrank(admin);
        tokenB.grantRole(tokenB.ISSUER_ROLE(), tokenBIssuer);
        vm.stopPrank();
        vm.prank(tokenBIssuer);
        tokenB.mint(100e18);
        vm.prank(tokenBIssuer);
        tokenB.transfer(userA, 100e18);

        _step("[Step 2] pause token only");
        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));

        _step("[Step 3] tokenB transfer succeeds");
        assertFalse(pauseManager.isTokenPaused(address(tokenB)));
        vm.prank(userA);
        tokenB.transfer(userB, 50e18);
        assertEq(tokenB.balanceOf(userB), 50e18);
        _step("  PASS: tokenB transfer succeeded while token is paused");

        _logPass();
    }

    // ── ST-PSE-09 ──
    function test_STPSE09_AdminCannotPause() public {
        _logCase("ST-PSE-09", unicode"admin 不能暂停");

        _step("[Step 1] admin tries pauseToken");
        vm.prank(admin);
        vm.expectRevert(PauseRegistry.MissingPauseRole.selector);
        pauseManager.pauseToken(address(token));
        _step("  PASS: reverted MissingPauseRole()");

        _logPass();
    }
}
