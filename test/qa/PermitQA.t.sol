// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2, Vm} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {PauseManagerClientUpgradeable} from "../../src/pauseManager/PauseManagerClientUpgradeable.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract PermitQA is BaseQA {
    string constant MODULE = unicode"EIP-2612 Permit";

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _signPermit(
        Vm.Wallet memory signer,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 nonce = IERC20Permit(address(token)).nonces(signer.addr);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, signer.addr, spender, value, nonce, deadline)
        );
        bytes32 domain = IERC20Permit(address(token)).DOMAIN_SEPARATOR();
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, structHash);
        (v, r, s) = vm.sign(signer.privateKey, digest);
    }

    // ═══════════════════════════════════════════════
    //      B.1 EIP-2612 Permit [P0]
    // ═══════════════════════════════════════════════

    // ── PMT-01 ──
    function test_PMT01_PermitFullE2E() public {
        _logCase("PMT-01", unicode"permit 完整 E2E 流程");

        _step(unicode"[Step 1] mint → transfer to holder");
        Vm.Wallet memory holder = vm.createWallet("holder");
        uint256 amount = 500e18;
        _mintAndTransfer(holder.addr, amount);
        assertEq(token.balanceOf(holder.addr), amount);
        _step("  PASS: holder has 500e18");

        _step("[Step 2] holder signs permit for spender");
        address spender = makeAddr("spender");
        uint256 permitAmt = 200e18;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(holder, spender, permitAmt, deadline);

        _step("[Step 3] submit permit");
        IERC20Permit(address(token)).permit(holder.addr, spender, permitAmt, deadline, v, r, s);
        assertEq(token.allowance(holder.addr, spender), permitAmt);
        assertEq(IERC20Permit(address(token)).nonces(holder.addr), 1);
        _step("  PASS: allowance set, nonce incremented");

        _step("[Step 4] spender transfers via transferFrom");
        vm.prank(spender);
        token.transferFrom(holder.addr, spender, permitAmt);
        assertEq(token.balanceOf(holder.addr), amount - permitAmt);
        assertEq(token.balanceOf(spender), permitAmt);
        _step("  PASS: transferFrom succeeded");

        _logPass();
    }

    // ── PMT-02 ──
    function test_PMT02_PermitSucceedsForBlockedUser() public {
        _logCase("PMT-02", unicode"blocked 用户可签 permit 但 transferFrom 失败");

        _step("[Step 1] mint to holder, then block holder");
        Vm.Wallet memory holder = vm.createWallet("holder");
        _mintAndTransfer(holder.addr, 100e18);

        address[] memory blocked = new address[](1);
        blocked[0] = holder.addr;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), blocked);
        _step("  holder is now blocked");

        _step("[Step 2] permit itself succeeds (no _update call)");
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(holder, spender, 100e18, deadline);
        IERC20Permit(address(token)).permit(holder.addr, spender, 100e18, deadline, v, r, s);
        assertEq(token.allowance(holder.addr, spender), 100e18);
        _step("  PASS: permit succeeded for blocked user");

        _step("[Step 3] transferFrom reverts (UserBlocked)");
        vm.prank(spender);
        vm.expectRevert(Compliance.UserBlocked.selector);
        token.transferFrom(holder.addr, spender, 100e18);
        _step("  PASS: transferFrom reverted UserBlocked");

        _logPass();
    }

    // ── PMT-03 ──
    function test_PMT03_PermitSucceedsForSanctionedUser() public {
        _logCase("PMT-03", unicode"sanctioned 用户可签 permit 但 transferFrom 失败");

        _step("[Step 1] mint to holder, then sanction holder");
        Vm.Wallet memory holder = vm.createWallet("holder");
        _mintAndTransfer(holder.addr, 100e18);

        address[] memory sanctioned = new address[](1);
        sanctioned[0] = holder.addr;
        vm.prank(complianceOps);
        compliance.addToSanctionsList(sanctioned);
        _step("  holder is now sanctioned");

        _step("[Step 2] permit itself succeeds");
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(holder, spender, 100e18, deadline);
        IERC20Permit(address(token)).permit(holder.addr, spender, 100e18, deadline, v, r, s);
        assertEq(token.allowance(holder.addr, spender), 100e18);
        _step("  PASS: permit succeeded for sanctioned user");

        _step("[Step 3] transferFrom reverts (UserSanctioned)");
        vm.prank(spender);
        vm.expectRevert(Compliance.UserSanctioned.selector);
        token.transferFrom(holder.addr, spender, 100e18);
        _step("  PASS: transferFrom reverted UserSanctioned");

        _logPass();
    }

    // ── PMT-04 ──
    function test_PMT04_PermitSucceedsWhenPaused() public {
        _logCase("PMT-04", unicode"暂停时 permit 成功但 transferFrom 失败");

        _step("[Step 1] mint to holder, then pause token");
        Vm.Wallet memory holder = vm.createWallet("holder");
        _mintAndTransfer(holder.addr, 100e18);

        vm.prank(pauseOps);
        pauseManager.pauseToken(address(token));
        _step("  token is paused");

        _step("[Step 2] permit succeeds while paused");
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(holder, spender, 100e18, deadline);
        IERC20Permit(address(token)).permit(holder.addr, spender, 100e18, deadline, v, r, s);
        assertEq(token.allowance(holder.addr, spender), 100e18);
        _step("  PASS: permit succeeded while paused");

        _step("[Step 3] transferFrom reverts (TokenPaused)");
        vm.prank(spender);
        vm.expectRevert(PauseManagerClientUpgradeable.TokenPaused.selector);
        token.transferFrom(holder.addr, spender, 100e18);
        _step("  PASS: transferFrom reverted TokenPaused");

        _logPass();
    }

    // ── PMT-05 ──
    function test_PMT05_ExpiredDeadlineReverts() public {
        _logCase("PMT-05", unicode"过期签名精确 revert");

        _step("[Step 1] sign permit with past deadline");
        Vm.Wallet memory holder = vm.createWallet("holder");
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(holder, userA, 100e18, deadline);

        _step("[Step 2] permit reverts ERC2612ExpiredSignature");
        vm.expectRevert(
            abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline)
        );
        IERC20Permit(address(token)).permit(holder.addr, userA, 100e18, deadline, v, r, s);
        _step("  PASS: reverted ERC2612ExpiredSignature(deadline)");

        _logPass();
    }

    // ── PMT-06 ──
    function test_PMT06_WrongSignerReverts() public {
        _logCase("PMT-06", unicode"伪造签名精确 revert");

        _step("[Step 1] imposter signs on behalf of owner");
        Vm.Wallet memory owner = vm.createWallet("owner");
        Vm.Wallet memory imposter = vm.createWallet("imposter");
        uint256 deadline = block.timestamp + 1 hours;

        uint256 nonce = IERC20Permit(address(token)).nonces(owner.addr);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner.addr, userA, 100e18, nonce, deadline)
        );
        bytes32 domain = IERC20Permit(address(token)).DOMAIN_SEPARATOR();
        bytes32 digest = MessageHashUtils.toTypedDataHash(domain, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(imposter.privateKey, digest);

        _step("[Step 2] permit reverts ERC2612InvalidSigner");
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20PermitUpgradeable.ERC2612InvalidSigner.selector,
                imposter.addr,
                owner.addr
            )
        );
        IERC20Permit(address(token)).permit(owner.addr, userA, 100e18, deadline, v, r, s);
        _step("  PASS: reverted ERC2612InvalidSigner(imposter, owner)");

        _logPass();
    }

    // ── PMT-07 ──
    function test_PMT07_ReplayReverts() public {
        _logCase("PMT-07", unicode"重放保护 nonce 递增");

        _step("[Step 1] first permit succeeds");
        Vm.Wallet memory holder = vm.createWallet("holder");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(holder, userA, 100e18, deadline);
        IERC20Permit(address(token)).permit(holder.addr, userA, 100e18, deadline, v, r, s);
        assertEq(IERC20Permit(address(token)).nonces(holder.addr), 1);
        _step("  PASS: first permit ok, nonce == 1");

        _step("[Step 2] replay with same signature reverts (ERC2612InvalidSigner)");
        bytes32 replayStructHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, holder.addr, userA, 100e18, 1, deadline)
        );
        bytes32 replayDigest = MessageHashUtils.toTypedDataHash(
            IERC20Permit(address(token)).DOMAIN_SEPARATOR(), replayStructHash
        );
        address recoveredSigner = ecrecover(replayDigest, v, r, s);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, recoveredSigner, holder.addr)
        );
        IERC20Permit(address(token)).permit(holder.addr, userA, 100e18, deadline, v, r, s);
        assertEq(IERC20Permit(address(token)).nonces(holder.addr), 1, "nonce unchanged after replay");
        _step("  PASS: replay reverted, nonce still 1");

        _logPass();
    }

    // ── PMT-08 ──
    function test_PMT08_SetNameDoesNotBreakPermit() public {
        _logCase("PMT-08", unicode"setName 后 permit 仍有效");

        _step("[Step 1] sign permit before setName");
        Vm.Wallet memory holder = vm.createWallet("holder");
        _mintAndTransfer(holder.addr, 100e18);

        bytes32 domainBefore = IERC20Permit(address(token)).DOMAIN_SEPARATOR();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(holder, userA, 50e18, deadline);

        _step("[Step 2] admin calls setName");
        vm.prank(admin);
        token.setName("New Token Name");
        _step("  name changed to 'New Token Name'");

        _step("[Step 3] DOMAIN_SEPARATOR unchanged (uses initial name)");
        bytes32 domainAfter = IERC20Permit(address(token)).DOMAIN_SEPARATOR();
        assertEq(domainBefore, domainAfter);
        _step("  PASS: DOMAIN_SEPARATOR unchanged");

        _step("[Step 4] permit still valid after setName");
        IERC20Permit(address(token)).permit(holder.addr, userA, 50e18, deadline, v, r, s);
        assertEq(token.allowance(holder.addr, userA), 50e18);
        _step("  PASS: permit succeeded after setName");

        _logPass();
    }

    // ── PMT-09 ──
    function test_PMT09_BlockedSpenderCannotTransferFrom() public {
        _logCase("PMT-09", unicode"spender 被 blocklist 时 transferFrom 失败");

        _step("[Step 1] mint to holder, permit to spender");
        Vm.Wallet memory holder = vm.createWallet("holder");
        address spender = makeAddr("spender");
        _mintAndTransfer(holder.addr, 100e18);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(holder, spender, 100e18, deadline);
        IERC20Permit(address(token)).permit(holder.addr, spender, 100e18, deadline, v, r, s);
        _step("  permit granted");

        _step("[Step 2] block spender");
        address[] memory blocked = new address[](1);
        blocked[0] = spender;
        vm.prank(complianceOps);
        compliance.addToBlocklist(address(token), blocked);
        _step("  spender is blocked");

        _step("[Step 3] spender transferFrom reverts (UserBlocked for msg.sender)");
        vm.prank(spender);
        vm.expectRevert(Compliance.UserBlocked.selector);
        token.transferFrom(holder.addr, spender, 100e18);
        _step("  PASS: reverted UserBlocked");

        _logPass();
    }

    // ── PMT-10 ──
    function test_PMT10_EIP712DomainMatchesInitialName() public {
        _logCase("PMT-10", unicode"eip712Domain 返回初始名称");

        _step("[Step 1] query eip712Domain()");
        (
            ,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            ,
        ) = token.eip712Domain();

        assertEq(name, "Apple Inc.");
        _step("  PASS: domain name == 'Apple Inc.'");
        assertEq(version, "1");
        _step("  PASS: version == '1'");
        assertEq(chainId, block.chainid);
        _step("  PASS: chainId correct");
        assertEq(verifyingContract, address(token));
        _step("  PASS: verifyingContract == token address");

        _logPass();
    }
}
