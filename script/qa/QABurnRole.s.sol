// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev On-chain helper: a contract that can hold BURN_ROLE (code.length > 0).
contract OnChainBurner {
    function doBurn(ScaledToken t, uint256 amount) external {
        t.burn(amount);
    }

    function doMint(ScaledToken t, uint256 amount) external {
        t.mint(amount);
    }
}

contract QABurnRole is BaseQAScript {
    OnChainBurner internal burner;
    bytes32 internal BURN_ROLE;
    bool internal _burnerDeployed;

    function _init() internal {
        _loadEnv();
        if (_burnerDeployed) return;
        _burnerDeployed = true;
        _deployBurner();
    }

    function run() external {
        _init();

        test_BR01();
        test_BR02();
        test_BR03();
        test_BR04();
        test_BR05();
    }

    function _deployBurner() internal {
        BURN_ROLE = token.BURN_ROLE();

        vm.broadcast(adminPk);
        burner = new OnChainBurner();

        vm.broadcast(adminPk);
        token.grantRole(BURN_ROLE, address(burner));
        _assertEq(token.hasRole(BURN_ROLE, address(burner)), true, "burner has BURN_ROLE");
    }

    // ── QA-BR-01: BURN_ROLE 可 burn 不可 mint ──
    function test_BR01() public {
        _init();
        _logCase("QA-BR-01", unicode"BURN_ROLE 可 burn 不可 mint");

        _step("[Step 1] mint tokens to burner (via hot wallet transfer)");
        _mintToHotWallet(100e18);
        vm.broadcast(hotWalletPk);
        token.transfer(address(burner), 100e18);
        _assertEq(token.balanceOf(address(burner)), 100e18, "burner balance");

        _step("[Step 2] burner burns via BURN_ROLE");
        vm.broadcast(adminPk);
        burner.doBurn(token, 50e18);
        _assertEq(token.balanceOf(address(burner)), 50e18, "burner balance after burn");
        _step("  burn succeeded");

        _step("[Step 3] burner tries to mint - should revert UnauthorizedRole");
        _expectRevert(
            address(burner),
            abi.encodeWithSelector(OnChainBurner.doMint.selector, address(token), 1e18),
            ScaledToken.UnauthorizedRole.selector
        );
        _step("  PASS: BURN_ROLE can burn but cannot mint");

        _logPass();
    }

    // ── QA-BR-02: ISSUER_ROLE 仍可 mint+burn（回归） ──
    function test_BR02() public {
        _init();
        _logCase("QA-BR-02", unicode"ISSUER_ROLE 仍可 mint+burn（回归）");

        _step("[Step 1] walletOps mints via ISSUER_ROLE");
        _requireNotPaused();
        _requireRole(address(vault), WALLET_OPS_ROLE, walletOps, "walletOps");
        _requireRole(address(token), ISSUER_ROLE, address(vault), "vault ISSUER");

        uint256 hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), hotWallet, 100e18);
        _assertDiff(hotBefore, token.balanceOf(hotWallet), 100e18, "mint +100e18");
        _step("  mint succeeded");

        _step("[Step 2] walletOps burns via ISSUER_ROLE");
        vm.broadcast(hotWalletPk);
        token.approve(address(vault), 40e18);
        uint256 hotBefore2 = token.balanceOf(hotWallet);
        vm.broadcast(walletOpsPk);
        vault.burn(address(token), hotWallet, 40e18);
        _assertDiff(hotBefore2, token.balanceOf(hotWallet), -40e18, "burn -40e18");
        _step("  PASS: ISSUER_ROLE mint + burn both work (additive, not replaced)");

        _logPass();
    }

    // ── QA-BR-03: BURN_ROLE 不能授予 EOA ──
    function test_BR03() public {
        _init();
        _logCase("QA-BR-03", unicode"BURN_ROLE 不能授予 EOA");

        _step("[Step 1] admin tries grantRole(BURN_ROLE, EOA)");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, BURN_ROLE, userA),
            ScaledToken.IssuerNotContract.selector
        );
        _step("  PASS: revert IssuerNotContract");

        _logPass();
    }

    // ── QA-BR-04: burnAllowed=false 时 BURN_ROLE 也不能 burn ──
    function test_BR04() public {
        _init();
        _logCase("QA-BR-04", unicode"burnAllowed=false 时 BURN_ROLE 也不能 burn");

        _step("[Step 1] mint tokens to burner");
        _mintToHotWallet(10e18);
        vm.broadcast(hotWalletPk);
        token.transfer(address(burner), 10e18);

        _step("[Step 2] tokenOps disables burn via OPS_ROLE");
        _requireRole(address(token), TOKEN_OPS_ROLE, tokenOps, "tokenOps");
        vm.broadcast(tokenOpsPk);
        token.setBurnAllowed(false);
        _assertEq(token.burnAllowed(), false, "burnAllowed disabled");

        _step("[Step 3] burner tries to burn - should revert BurnNotAllowed");
        _expectRevert(
            address(burner),
            abi.encodeWithSelector(OnChainBurner.doBurn.selector, address(token), 1e18),
            ScaledToken.BurnNotAllowed.selector
        );
        _step("  PASS: BurnNotAllowed even with BURN_ROLE");

        _step("[Step 4] cleanup: re-enable burn");
        vm.broadcast(tokenOpsPk);
        token.setBurnAllowed(true);
        _assertEq(token.burnAllowed(), true, "burnAllowed restored");

        _logPass();
    }

    // ── QA-BR-05: revoke BURN_ROLE 后不能 burn ──
    function test_BR05() public {
        _init();
        _logCase("QA-BR-05", unicode"revoke BURN_ROLE 后不能 burn");

        _step("[Step 1] mint tokens to burner");
        _mintToHotWallet(10e18);
        vm.broadcast(hotWalletPk);
        token.transfer(address(burner), 10e18);

        _step("[Step 2] admin revokes BURN_ROLE from burner");
        vm.broadcast(adminPk);
        token.revokeRole(BURN_ROLE, address(burner));
        _assertEq(token.hasRole(BURN_ROLE, address(burner)), false, "burner BURN_ROLE revoked");

        _step("[Step 3] burner tries to burn - should revert UnauthorizedRole");
        _expectRevert(
            address(burner),
            abi.encodeWithSelector(OnChainBurner.doBurn.selector, address(token), 1e18),
            ScaledToken.UnauthorizedRole.selector
        );
        _step("  PASS: revoked BURN_ROLE cannot burn");

        _logPass();
    }

    // ── helper: find PK for a known address ──
    function _findPkFor(address target) internal view returns (uint256) {
        if (target == admin) return adminPk;
        if (target == complianceOps) return complianceOpsPk;
        if (target == pauseOps) return pauseOpsPk;
        if (target == walletOps) return walletOpsPk;
        if (target == tokenOps) return tokenOpsPk;
        if (target == factoryOps) return factoryOpsPk;
        if (target == hotWallet) return hotWalletPk;
        if (target == userA) return userAPk;
        if (target == userB) return userBPk;
        revert("_findPkFor: unknown address");
    }
}
