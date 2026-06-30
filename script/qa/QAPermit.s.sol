// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {PauseManagerClientUpgradeable} from "../../src/pauseManager/PauseManagerClientUpgradeable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

contract QAPermit is BaseQAScript {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function run() external {
        _loadEnv();

        test_PMT01();
        test_PMT02();
        test_PMT03();
        test_PMT04();
        test_PMT05();
    }

    function _signPermit(uint256 ownerPk, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(ownerPk);
        uint256 nonce = token.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerPk, digest);
    }

    // ── QA-PMT-01: permit 完整 E2E ──
    function test_PMT01() public {
        _logCase("QA-PMT-01", unicode"permit 完整 E2E");

        _step("[Step 1] preconditions: distribute to userA");
        _requireNotPaused();
        _mintAndDistribute(userA, 200e18);
        _requireBalance(userA, 200e18, "userA");

        _step("[Step 2] userA signs permit for userB (100e18)");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userAPk, userB, 100e18, deadline);

        _step("[Step 3] submit permit on-chain");
        uint256 nonceBefore = token.nonces(userA);
        vm.broadcast(userBPk);
        token.permit(userA, userB, 100e18, deadline, v, r, s);
        _assertEq(token.allowance(userA, userB), 100e18, "allowance set");
        _step("  PASS: allowance == 100e18");
        _assertEq(token.nonces(userA), nonceBefore + 1, "nonce incremented");
        _step("  PASS: nonce incremented");

        _step("[Step 4] userB calls transferFrom");
        uint256 aBefore = token.balanceOf(userA);
        uint256 bBefore = token.balanceOf(userB);
        vm.broadcast(userBPk);
        token.transferFrom(userA, userB, 100e18);
        _assertDiff(aBefore, token.balanceOf(userA), -100e18, "userA diff");
        _assertDiff(bBefore, token.balanceOf(userB), 100e18, "userB diff");
        _step("  PASS: transferFrom succeeded");

        _logPass();
    }

    // ── QA-PMT-02: blocked 用户 permit 成功但 transferFrom 失败 ──
    function test_PMT02() public {
        _logCase("QA-PMT-02", unicode"blocked 用户 permit 成功但 transferFrom 失败");

        _step("[Step 1] preconditions: distribute to userA, block userA");
        _requireNotPaused();
        _mintAndDistribute(userA, 200e18);
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.addToBlocklist(address(token), addrs);
        _assertEq(compliance.blockedAddresses(address(token), userA), true, "userA blocked");

        _step("[Step 2] userA signs permit for userB");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userAPk, userB, 100e18, deadline);

        _step("[Step 3] submit permit - should succeed (permit doesn't check compliance)");
        vm.broadcast(userBPk);
        token.permit(userA, userB, 100e18, deadline, v, r, s);
        _assertEq(token.allowance(userA, userB), 100e18, "allowance set");
        _step("  PASS: permit succeeded, allowance == 100e18");

        _step("[Step 4] userB calls transferFrom - should fail (blocked)");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transferFrom.selector, userA, userB, 100e18),
            Compliance.UserBlocked.selector
        );
        _step("  PASS: reverted UserBlocked()");

        _step("[Step 5] cleanup: unblock userA");
        vm.broadcast(complianceOpsPk);
        compliance.removeFromBlocklist(address(token), addrs);
        _assertEq(compliance.blockedAddresses(address(token), userA), false, "userA unblocked");
        _step("  PASS: userA unblocked");

        _logPass();
    }

    // ── QA-PMT-03: sanctioned 用户 permit 成功但 transferFrom 失败 ──
    function test_PMT03() public {
        _logCase("QA-PMT-03", unicode"sanctioned 用户 permit 成功但 transferFrom 失败");

        _step("[Step 1] preconditions: distribute to userA, sanction userA");
        _requireNotPaused();
        _mintAndDistribute(userA, 200e18);
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.broadcast(complianceOpsPk);
        compliance.addToSanctionsList(addrs);
        _assertEq(compliance.sanctionedAddresses(userA), true, "userA sanctioned");

        _step("[Step 2] userA signs permit for userB");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userAPk, userB, 100e18, deadline);

        _step("[Step 3] submit permit - should succeed");
        vm.broadcast(userBPk);
        token.permit(userA, userB, 100e18, deadline, v, r, s);
        _assertEq(token.allowance(userA, userB), 100e18, "allowance set");
        _step("  PASS: permit succeeded, allowance == 100e18");

        _step("[Step 4] userB calls transferFrom - should fail (sanctioned)");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transferFrom.selector, userA, userB, 100e18),
            Compliance.UserSanctioned.selector
        );
        _step("  PASS: reverted UserSanctioned()");

        _step("[Step 5] cleanup: unsanction userA");
        vm.broadcast(complianceOpsPk);
        compliance.removeFromSanctionsList(addrs);
        _assertEq(compliance.sanctionedAddresses(userA), false, "userA unsanctioned");
        _step("  PASS: userA unsanctioned");

        _logPass();
    }

    // ── QA-PMT-04: 暂停时 permit 成功但 transferFrom 失败 ──
    function test_PMT04() public {
        _logCase("QA-PMT-04", unicode"暂停时 permit 成功但 transferFrom 失败");

        _step("[Step 1] preconditions: distribute to userA BEFORE pause");
        _requireNotPaused();
        _mintAndDistribute(userA, 200e18);

        _step("[Step 2] pause token");
        vm.broadcast(pauseOpsPk);
        pauseManager.pauseToken(address(token));
        _requirePaused();

        _step("[Step 3] userA signs permit for userB");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userAPk, userB, 100e18, deadline);

        _step("[Step 4] submit permit - should succeed (permit doesn't check pause)");
        vm.broadcast(userBPk);
        token.permit(userA, userB, 100e18, deadline, v, r, s);
        _assertEq(token.allowance(userA, userB), 100e18, "allowance set");
        _step("  PASS: permit succeeded during pause");

        _step("[Step 5] userB calls transferFrom - should fail (paused)");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.transferFrom.selector, userA, userB, 100e18),
            PauseManagerClientUpgradeable.TokenPaused.selector
        );
        _step("  PASS: reverted TokenPaused()");

        _step("[Step 6] cleanup: unpause");
        vm.broadcast(pauseOpsPk);
        pauseManager.unpauseToken(address(token));
        _requireNotPaused();
        _step("  PASS: unpauseToken done");

        _logPass();
    }

    // ── QA-PMT-05: 过期签名精确 revert ──
    function test_PMT05() public {
        _logCase("QA-PMT-05", unicode"过期签名精确 revert");

        _step("[Step 1] userA signs permit with deadline = 1 (already expired)");
        uint256 expiredDeadline = 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(userAPk, userB, 100e18, expiredDeadline);

        _step("[Step 2] submit permit with expired deadline");
        _expectRevertFrom(
            userB,
            address(token),
            abi.encodeWithSelector(token.permit.selector, userA, userB, 100e18, expiredDeadline, v, r, s),
            ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector
        );
        _step("  PASS: reverted ERC2612ExpiredSignature()");

        _logPass();
    }
}
