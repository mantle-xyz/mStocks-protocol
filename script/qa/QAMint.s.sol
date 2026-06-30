// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {OperatorWallet} from "../../src/OperatorWallet/OperatorWallet.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract QAMint is BaseQAScript {
    function run() external {
        _loadEnv();

        test_MINT01();
        test_MINT02();
        test_MINT03();
        test_MINT04();
        test_MINT05();
        test_MINT06();
        test_MINT07();
        test_MINT08();
        test_BURN01();
        test_BURN02();
        test_BURN03();
        test_BURN04();
    }

    // ── QA-MINT-01: admin 不能铸造 ──
    function test_MINT01() public {
        _logCase("QA-MINT-01", unicode"admin 不能铸造");

        _step("[Step 1] precondition: admin has DEFAULT_ADMIN_ROLE but NOT ISSUER_ROLE");
        _requireRole(address(token), DEFAULT_ADMIN_ROLE_HASH, admin, "admin");
        _assertEq(token.hasRole(ISSUER_ROLE, admin), false, "admin should not have ISSUER_ROLE");

        _step("[Step 2] admin calls token.mint(1000e18)");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(SecuritiesToken.mint.selector, 1000e18),
            SecuritiesToken.UnauthorizedRole.selector
        );
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── QA-MINT-02: 通过 OperatorWallet 铸造到热钱包 ──
    function test_MINT02() public {
        _logCase("QA-MINT-02", unicode"通过 OperatorWallet 铸造到热钱包");

        _step("[Step 1] preconditions");
        _requireNotPaused();
        _requireRole(address(wallet), WALLET_OPS_ROLE, walletOps, "walletOps");
        _requireRole(address(token), ISSUER_ROLE, address(wallet), "wallet ISSUER");
        _assertEq(token.mintEnabled(), true, "mintEnabled");

        _step("[Step 2] record before balances");
        uint256 hotBefore = token.balanceOf(hotWallet);
        uint256 walletBefore = token.balanceOf(address(wallet));
        uint256 supplyBefore = token.totalSupply();

        _step("[Step 3] walletOps mints 500e18 to hotWallet");
        vm.broadcast(walletOpsPk);
        wallet.mint(address(token), hotWallet, 500e18);

        _step("[Step 4] verify diffs");
        _assertDiff(hotBefore, token.balanceOf(hotWallet), 500e18, "hotWallet balance diff");
        _step("  PASS: hotWallet +500e18");

        _assertEq(token.balanceOf(address(wallet)), walletBefore, "wallet balance unchanged");
        _step("  PASS: wallet balance unchanged");

        _assertDiff(supplyBefore, token.totalSupply(), 500e18, "totalSupply diff");
        _step("  PASS: totalSupply +500e18");

        _logPass();
    }

    // ── QA-MINT-03: 普通用户不能铸造 ──
    function test_MINT03() public {
        _logCase("QA-MINT-03", unicode"普通用户不能铸造");

        _step("[Step 1] precondition: userA has no ISSUER_ROLE");
        _assertEq(token.hasRole(ISSUER_ROLE, userA), false, "userA no ISSUER_ROLE");

        _step("[Step 2] userA calls token.mint(1e18)");
        _expectRevertFrom(
            userA,
            address(token),
            abi.encodeWithSelector(SecuritiesToken.mint.selector, 1e18),
            SecuritiesToken.UnauthorizedRole.selector
        );
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── QA-MINT-04: operator 不能铸造 ──
    function test_MINT04() public {
        _logCase("QA-MINT-04", unicode"operator (OPS_ROLE) 不能铸造");

        _step("[Step 1] precondition: find an OPS_ROLE member");
        address opsHolder = token.getRoleMember(TOKEN_OPS_ROLE, 0);
        _assertEq(token.hasRole(TOKEN_OPS_ROLE, opsHolder), true, "opsHolder has OPS_ROLE");
        _assertEq(token.hasRole(ISSUER_ROLE, opsHolder), false, "opsHolder no ISSUER_ROLE");

        _step("[Step 2] opsHolder calls token.mint(1e18)");
        _expectRevertFrom(
            opsHolder,
            address(token),
            abi.encodeWithSelector(SecuritiesToken.mint.selector, 1e18),
            SecuritiesToken.UnauthorizedRole.selector
        );
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── QA-MINT-05: mint 开关关闭 ──
    function test_MINT05() public {
        _logCase("QA-MINT-05", unicode"mint 开关关闭后铸造失败");

        _step("[Step 1] precondition: mintEnabled == true");
        _assertEq(token.mintEnabled(), true, "mintEnabled before");

        _step("[Step 2] admin disables mint");
        vm.broadcast(adminPk);
        token.setMintEnabled(false);
        _assertEq(token.mintEnabled(), false, "mintEnabled after disable");

        _step("[Step 3] walletOps tries to mint via wallet (from walletOps addr)");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(OperatorWallet.mint.selector, address(token), hotWallet, 1e18),
            SecuritiesToken.MintDisabled.selector
        );
        _step("  PASS: reverted MintDisabled()");

        _step("[Step 4] cleanup: re-enable mint");
        vm.broadcast(adminPk);
        token.setMintEnabled(true);
        _assertEq(token.mintEnabled(), true, "mintEnabled restored");
        _step("  PASS: mintEnabled restored");

        _logPass();
    }

    // ── QA-MINT-06: mint 开关重新开启 ──
    function test_MINT06() public {
        _logCase("QA-MINT-06", unicode"mint 开关重新开启后铸造成功");

        _step("[Step 1] admin disables then re-enables mint");
        vm.broadcast(adminPk);
        token.setMintEnabled(false);
        _assertEq(token.mintEnabled(), false, "disabled");

        vm.broadcast(adminPk);
        token.setMintEnabled(true);
        _assertEq(token.mintEnabled(), true, "re-enabled");

        _step("[Step 2] walletOps mints to hotWallet");
        uint256 hotBefore = token.balanceOf(hotWallet);
        vm.broadcast(walletOpsPk);
        wallet.mint(address(token), hotWallet, 100e18);

        _assertDiff(hotBefore, token.balanceOf(hotWallet), 100e18, "hotWallet balance diff");
        _step("  PASS: mint succeeded after re-enable");

        _logPass();
    }

    // ── QA-MINT-07: EOA 不能获得 ISSUER_ROLE ──
    function test_MINT07() public {
        _logCase("QA-MINT-07", unicode"EOA 不能获得 ISSUER_ROLE");

        _step("[Step 1] precondition: admin has DEFAULT_ADMIN_ROLE (can call grantRole)");
        _requireRole(address(token), DEFAULT_ADMIN_ROLE_HASH, admin, "admin");

        _step("[Step 2] admin grants ISSUER_ROLE to EOA (userA)");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(IAccessControl.grantRole.selector, ISSUER_ROLE, userA),
            SecuritiesToken.IssuerMustBeContract.selector
        );
        _step("  PASS: reverted IssuerMustBeContract()");

        _logPass();
    }

    // ── QA-MINT-08: 铸造到非热钱包回滚 ──
    function test_MINT08() public {
        _logCase("QA-MINT-08", unicode"铸造到非热钱包回滚");

        _step("[Step 1] precondition: walletOps has OPS_ROLE, userA is not hotWallet");
        _requireRole(address(wallet), WALLET_OPS_ROLE, walletOps, "walletOps");
        _assertEq(wallet.isHotWallet(userA), false, "userA is not hotWallet");

        _step("[Step 2] walletOps mints to userA (not a hotWallet)");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(OperatorWallet.mint.selector, address(token), userA, 1e18),
            OperatorWallet.RecipientNotHotWallet.selector
        );
        _step("  PASS: reverted RecipientNotHotWallet()");

        _logPass();
    }

    // ── QA-BURN-01: admin 不能销毁 ──
    function test_BURN01() public {
        _logCase("QA-BURN-01", unicode"admin 不能销毁");

        _step("[Step 1] precondition: admin has no ISSUER_ROLE");
        _assertEq(token.hasRole(ISSUER_ROLE, admin), false, "admin no ISSUER_ROLE");

        _step("[Step 2] admin calls token.burn(1e18)");
        _expectRevertFrom(
            admin,
            address(token),
            abi.encodeWithSelector(SecuritiesToken.burn.selector, 1e18),
            SecuritiesToken.UnauthorizedRole.selector
        );
        _step("  PASS: reverted UnauthorizedRole()");

        _logPass();
    }

    // ── QA-BURN-02: 通过 OperatorWallet 销毁 ──
    function test_BURN02() public {
        _logCase("QA-BURN-02", unicode"通过 OperatorWallet 销毁");

        _step("[Step 1] preconditions");
        _requireNotPaused();
        _requireRole(address(wallet), WALLET_OPS_ROLE, walletOps, "walletOps");
        _requireRole(address(token), ISSUER_ROLE, address(wallet), "wallet ISSUER");

        _step("[Step 2] mint 1000e18 to hotWallet for burn test");
        vm.broadcast(walletOpsPk);
        wallet.mint(address(token), hotWallet, 1000e18);

        _step("[Step 3] hotWallet approves wallet for burn");
        vm.broadcast(hotWalletPk);
        token.approve(address(wallet), type(uint256).max);

        _step("[Step 4] record before, walletOps burns 400e18");
        uint256 hotBefore = token.balanceOf(hotWallet);
        uint256 supplyBefore = token.totalSupply();

        vm.broadcast(walletOpsPk);
        wallet.burn(address(token), hotWallet, 400e18);

        _step("[Step 5] verify diffs");
        _assertDiff(hotBefore, token.balanceOf(hotWallet), -400e18, "hotWallet balance diff");
        _step("  PASS: hotWallet -400e18");

        _assertDiff(supplyBefore, token.totalSupply(), -400e18, "totalSupply diff");
        _step("  PASS: totalSupply -400e18");

        _logPass();
    }

    // ── QA-BURN-03: burn 开关关闭 ──
    function test_BURN03() public {
        _logCase("QA-BURN-03", unicode"burn 开关关闭后销毁失败");

        _step("[Step 1] precondition: burnEnabled == true");
        _assertEq(token.burnEnabled(), true, "burnEnabled before");

        _step("[Step 2] admin disables burn");
        vm.broadcast(adminPk);
        token.setBurnEnabled(false);
        _assertEq(token.burnEnabled(), false, "burnEnabled after disable");

        _step("[Step 3] walletOps tries to burn (from walletOps addr)");
        _expectRevertFrom(
            walletOps,
            address(wallet),
            abi.encodeWithSelector(OperatorWallet.burn.selector, address(token), hotWallet, 1e18),
            SecuritiesToken.BurnDisabled.selector
        );
        _step("  PASS: reverted BurnDisabled()");

        _step("[Step 4] cleanup: re-enable burn");
        vm.broadcast(adminPk);
        token.setBurnEnabled(true);
        _assertEq(token.burnEnabled(), true, "burnEnabled restored");
        _step("  PASS: burnEnabled restored");

        _logPass();
    }

    // ── QA-BURN-04: 非 admin 不能切换开关 ──
    function test_BURN04() public {
        _logCase("QA-BURN-04", unicode"非 admin 不能切换开关");

        _step("[Step 1] precondition: userA has no DEFAULT_ADMIN_ROLE");
        _assertEq(token.hasRole(DEFAULT_ADMIN_ROLE_HASH, userA), false, "userA no admin");

        _step("[Step 2] userA calls setMintEnabled(false)");
        _expectRevertFrom(
            userA,
            address(token),
            abi.encodeWithSelector(token.setMintEnabled.selector, false),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: reverted AccessControlUnauthorizedAccount");

        _logPass();
    }
}
