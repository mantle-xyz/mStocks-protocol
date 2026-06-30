// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";

contract QABlocklist is BaseQAScript {
    function run() external {
        _loadEnv();

        test_BLK01();
        test_BLK02();
        test_BLK03();
        test_BLK04();
        test_BLK05();
        test_BLK06();
        test_BLK07();
        test_BLK08();
        test_BLK09();
    }

    // ── helpers ──

    function _blockUser(address user) internal {
        address[] memory addrs = new address[](1);
        addrs[0] = user;
        vm.broadcast(complianceOpsPk);
        compliance.addToBlocklist(address(token), addrs);
    }

    function _unblockUser(address user) internal {
        address[] memory addrs = new address[](1);
        addrs[0] = user;
        vm.broadcast(complianceOpsPk);
        compliance.removeFromBlocklist(address(token), addrs);
    }

    // ── QA-BLK-01: 发行方转给被拉黑地址阻断 ──
    function test_BLK01() public {
        _logCase("QA-BLK-01", unicode"发行方转给被拉黑地址阻断");

        _step("[Step 1] preconditions: mint to hotWallet, ensure userA not blocked");
        _requireNotPaused();
        _mintToHotWallet(100e18);
        _requireBalance(hotWallet, 100e18, "hotWallet");

        _step("[Step 2] complianceOps blocks userA");
        _blockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), true, "userA blocked");
        _step("  userA is blocked");

        _step("[Step 3] hotWallet tries transfer to userA");
        _expectRevertFrom(
            hotWallet,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            Compliance.UserBlocked.selector
        );
        _step("  PASS: reverted UserBlocked()");

        _step("[Step 4] cleanup: unblock userA");
        _unblockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), false, "userA unblocked");
        _step("  PASS: userA unblocked");

        _logPass();
    }

    // ── QA-BLK-02: 二级市场转给被拉黑地址阻断 ──
    function test_BLK02() public {
        _logCase("QA-BLK-02", unicode"二级市场转给被拉黑地址阻断");

        _step("[Step 1] preconditions: distribute to userB, block userA");
        _requireNotPaused();
        _mintAndDistribute(userB, 200e18);
        _blockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), true, "userA blocked");

        _step("[Step 2] userB tries transfer to blocked userA");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 100e18),
            Compliance.UserBlocked.selector
        );
        _step("  PASS: reverted UserBlocked()");

        _step("[Step 3] cleanup: unblock userA");
        _unblockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), false, "userA unblocked");
        _step("  PASS: userA unblocked");

        _logPass();
    }

    // ── QA-BLK-03: 被拉黑地址转出阻断 ──
    function test_BLK03() public {
        _logCase("QA-BLK-03", unicode"被拉黑地址转出阻断");

        _step("[Step 1] preconditions: distribute to userA, then block userA");
        _requireNotPaused();
        _mintAndDistribute(userA, 200e18);
        _requireBalance(userA, 10e18, "userA");
        _blockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), true, "userA blocked");

        _step("[Step 2] blocked userA tries transfer to userB");
        _expectRevertFrom(
            userA,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userB, 10e18),
            Compliance.UserBlocked.selector
        );
        _step("  PASS: reverted UserBlocked()");

        _step("[Step 3] cleanup: unblock userA");
        _unblockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), false, "userA unblocked");
        _step("  PASS: userA unblocked");

        _logPass();
    }

    // ── QA-BLK-04: 解除拉黑后恢复 ──
    function test_BLK04() public {
        _logCase("QA-BLK-04", unicode"解除拉黑后恢复");

        _step("[Step 1] preconditions: distribute to userB, block then unblock userA");
        _requireNotPaused();
        _mintAndDistribute(userB, 200e18);
        _blockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), true, "userA blocked");
        _unblockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), false, "userA unblocked");

        _step("[Step 2] userB transfers to userA (should succeed)");
        uint256 bBefore = token.balanceOf(userB);
        uint256 aBefore = token.balanceOf(userA);
        vm.broadcast(userBPk);
        token.transfer(userA, 50e18);
        _assertDiff(bBefore, token.balanceOf(userB), -50e18, "userB diff");
        _assertDiff(aBefore, token.balanceOf(userA), 50e18, "userA diff");
        _step("  PASS: transfer succeeded after unblock");

        _logPass();
    }

    // ── QA-BLK-05: 黑名单按 token 隔离 ──
    function test_BLK05() public {
        _logCase("QA-BLK-05", unicode"黑名单按 token 隔离");

        _step("[Step 1] deploy tokenB via Factory");
        _requireNotPaused();
        vm.broadcast(adminPk);
        string memory sym = _uniqueSymbol("BK");
        address tokenBAddr = factory.deployToken("Block Corp", sym, "BLK001", admin, new address[](0), new address[](0));
        SecuritiesToken tokenB = SecuritiesToken(tokenBAddr);
        _step(string.concat("  tokenB: ", vm.toString(tokenBAddr)));

        _step("[Step 2] grant ISSUER_ROLE to wallet on tokenB + mint + distribute to userB");
        vm.broadcast(adminPk);
        tokenB.grantRole(ISSUER_ROLE, address(wallet));
        vm.broadcast(walletOpsPk);
        wallet.mint(tokenBAddr, hotWallet, 200e18);
        vm.broadcast(hotWalletPk);
        tokenB.transfer(userB, 100e18);

        _step("[Step 3] block userA on tokenA only");
        _blockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), true, "userA blocked on tokenA");
        _assertEq(compliance.blockedAddresses(tokenBAddr, userA), false, "userA NOT blocked on tokenB");

        _step("[Step 4] tokenA transfer to userA reverts");
        _mintToHotWallet(100e18);
        _expectRevertFrom(
            hotWallet,
            address(token),
            abi.encodeWithSelector(token.transfer.selector, userA, 10e18),
            Compliance.UserBlocked.selector
        );
        _step("  PASS: tokenA reverted UserBlocked()");

        _step("[Step 5] tokenB transfer to userA succeeds");
        uint256 bBefore = tokenB.balanceOf(userB);
        uint256 aBefore = tokenB.balanceOf(userA);
        vm.broadcast(userBPk);
        tokenB.transfer(userA, 10e18);
        _assertDiff(bBefore, tokenB.balanceOf(userB), -10e18, "userB tokenB diff");
        _assertDiff(aBefore, tokenB.balanceOf(userA), 10e18, "userA tokenB diff");
        _step("  PASS: tokenB transfer succeeded");

        _step("[Step 6] cleanup: unblock userA on tokenA");
        _unblockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), false, "userA unblocked");
        _step("  PASS: userA unblocked");

        _logPass();
    }

    // ── QA-BLK-06: transferFrom 检查代扣方(msg.sender) ──
    function test_BLK06() public {
        _logCase("QA-BLK-06", unicode"transferFrom 检查代扣方(msg.sender)");

        _step("[Step 1] preconditions: distribute to userA, userA approves userB");
        _requireNotPaused();
        _mintAndDistribute(userA, 200e18);
        vm.broadcast(userAPk);
        token.approve(userB, 100e18);
        _assertEq(token.allowance(userA, userB), 100e18, "allowance set");

        _step("[Step 2] block userB (the spender / msg.sender)");
        _blockUser(userB);
        _assertEq(compliance.blockedAddresses(address(token), userB), true, "userB blocked");

        _step("[Step 3] userB calls transferFrom(userA, hotWallet, 50e18)");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transferFrom.selector, userA, hotWallet, 50e18),
            Compliance.UserBlocked.selector
        );
        _step("  PASS: reverted UserBlocked() on spender");

        _step("[Step 4] cleanup: unblock userB");
        _unblockUser(userB);
        _assertEq(compliance.blockedAddresses(address(token), userB), false, "userB unblocked");
        _step("  PASS: userB unblocked");

        _logPass();
    }

    // ── QA-BLK-07: 普通用户不能管理黑名单 ──
    function test_BLK07() public {
        _logCase("QA-BLK-07", unicode"普通用户不能管理黑名单");

        _step("[Step 1] precondition: userA has no OPS_ROLE on compliance");
        _assertEq(compliance.hasRole(COMPLIANCE_OPS_ROLE, userA), false, "userA no OPS_ROLE");

        _step("[Step 2] userA tries addToBlocklist");
        address[] memory addrs = new address[](1);
        addrs[0] = userB;
        _expectRevertFrom(
            userA,
            address(compliance),
            abi.encodeWithSelector(compliance.addToBlocklist.selector, address(token), addrs),
            Compliance.MissingBlocklistRole.selector
        );
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ── QA-BLK-08: admin 不能管理黑名单 ──
    function test_BLK08() public {
        _logCase("QA-BLK-08", unicode"admin 不能管理黑名单");

        _step("[Step 1] precondition: admin has DEFAULT_ADMIN_ROLE but NOT OPS_ROLE on compliance");
        _requireRole(address(compliance), DEFAULT_ADMIN_ROLE_HASH, admin, "admin");
        _assertEq(compliance.hasRole(COMPLIANCE_OPS_ROLE, admin), false, "admin no OPS_ROLE");

        _step("[Step 2] admin tries addToBlocklist");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        _expectRevertFrom(
            admin,
            address(compliance),
            abi.encodeWithSelector(compliance.addToBlocklist.selector, address(token), addrs),
            Compliance.MissingBlocklistRole.selector
        );
        _step("  PASS: reverted MissingBlocklistRole()");

        _logPass();
    }

    // ── QA-BLK-09: compliance OPS 可管理黑名单 ──
    function test_BLK09() public {
        _logCase("QA-BLK-09", unicode"compliance OPS 可管理黑名单");

        _step("[Step 1] precondition: complianceOps has OPS_ROLE");
        _requireRole(address(compliance), COMPLIANCE_OPS_ROLE, complianceOps, "complianceOps");

        _step("[Step 2] complianceOps adds userA to blocklist");
        _blockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), true, "userA blocked");
        _step("  PASS: addToBlocklist succeeded");

        _step("[Step 3] complianceOps removes userA from blocklist");
        _unblockUser(userA);
        _assertEq(compliance.blockedAddresses(address(token), userA), false, "userA unblocked");
        _step("  PASS: removeFromBlocklist succeeded");

        _logPass();
    }
}
