// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";
import {TokenIssuer} from "../../src/tokenIssuer/TokenIssuer.sol";

abstract contract BaseQAScript is Script {
    // ── protocol stack (from .env) ──
    ScaledToken internal token;
    ScaledTokenFactory internal factory;
    ComplianceRegistry internal compliance;
    PauseRegistry internal pauseManager;
    TokenIssuer internal vault;

    // ── accounts ──
    address internal admin;
    uint256 internal adminPk;

    address internal complianceOps;
    uint256 internal complianceOpsPk;

    address internal pauseOps;
    uint256 internal pauseOpsPk;

    address internal walletOps;
    uint256 internal walletOpsPk;

    address internal hotWallet;
    uint256 internal hotWalletPk;

    address internal userA;
    uint256 internal userAPk;

    address internal userB;
    uint256 internal userBPk;

    // ── role hashes ──
    bytes32 internal ISSUER_ROLE;
    bytes32 internal TOKEN_MULTIPLIER_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE_HASH;
    bytes32 internal COMPLIANCE_OPS_ROLE;
    bytes32 internal PAUSE_MANAGER_PAUSE_ROLE;
    bytes32 internal PAUSE_MANAGER_UNPAUSE_ROLE;
    bytes32 internal WALLET_OPS_ROLE;

    // ── state ──
    string internal _caseId;
    string internal _caseName;
    bool internal _envLoaded;

    function _loadEnv() internal {
        if (_envLoaded) return;
        _envLoaded = true;
        // contracts
        token = ScaledToken(vm.envAddress("TOKEN_ADDR"));
        factory = ScaledTokenFactory(vm.envAddress("FACTORY_ADDR"));
        compliance = ComplianceRegistry(vm.envAddress("COMPLIANCE_ADDR"));
        pauseManager = PauseRegistry(vm.envAddress("PAUSE_MANAGER_ADDR"));
        vault = TokenIssuer(payable(vm.envAddress("ISSUER_VAULT_ADDR")));

        // admin
        adminPk = vm.envUint("ADMIN_PK");
        admin = vm.addr(adminPk);

        // ops (may share the same key)
        complianceOpsPk = vm.envUint("COMPLIANCE_OPS_PK");
        complianceOps = vm.addr(complianceOpsPk);

        pauseOpsPk = vm.envUint("PAUSE_OPS_PK");
        pauseOps = vm.addr(pauseOpsPk);

        walletOpsPk = vm.envUint("ISSUER_VAULT_OPS_PK");
        walletOps = vm.addr(walletOpsPk);

        // hot wallet
        hotWalletPk = vm.envUint("HOT_WALLET_PK");
        hotWallet = vm.addr(hotWalletPk);

        // users
        userAPk = vm.envUint("USER_A_PK");
        userA = vm.addr(userAPk);

        userBPk = vm.envUint("USER_B_PK");
        userB = vm.addr(userBPk);

        // role hashes
        ISSUER_ROLE = token.ISSUER_ROLE();
        TOKEN_MULTIPLIER_ROLE = token.MULTIPLIER_SCHEDULER_ROLE();
        DEFAULT_ADMIN_ROLE_HASH = 0x00;
        COMPLIANCE_OPS_ROLE = compliance.OPS_ROLE();
        PAUSE_MANAGER_PAUSE_ROLE = pauseManager.PAUSE_ROLE();
        PAUSE_MANAGER_UNPAUSE_ROLE = pauseManager.UNPAUSE_ROLE();
        WALLET_OPS_ROLE = vault.OPS_ROLE();
    }

    // ═══════════════════════════════════════════════
    //      Token deploy helpers
    // ═══════════════════════════════════════════════

    uint256 private _symNonce;

    function _uniqueSymbol(string memory prefix) internal returns (string memory) {
        _symNonce++;
        return string.concat(prefix, vm.toString(block.timestamp), vm.toString(_symNonce));
    }

    // ═══════════════════════════════════════════════
    //      Logging — matches BaseQA.t.sol format
    // ═══════════════════════════════════════════════

    function _log(string memory line) internal pure {
        console.log(line);
    }

    function _logCase(string memory id, string memory name) internal {
        _loadEnv();
        _caseId = id;
        _caseName = name;
        _log("========================================");
        _log(string.concat("testcase id: ", id));
        _log(string.concat("testcase name: ", name));
        _log("========================================");
    }

    function _step(string memory msg_) internal {
        _log(msg_);
    }

    function _logPass() internal {
        _log("----------------------------------------");
        _log("test result: passed");
    }

    function _logFail(string memory reason) internal {
        _log("----------------------------------------");
        _log(string.concat("test result: failed | reason: ", reason));
    }

    // ═══════════════════════════════════════════════
    //      Revert helpers (replaces vm.expectRevert)
    // ═══════════════════════════════════════════════

    /// revert 模拟：不指定 caller，由脚本合约发起（适用于不涉及角色检查的场景）
    function _expectRevert(address target, bytes memory callData, bytes4 expectedSelector) internal {
        (bool ok, bytes memory ret) = target.call(callData);
        require(!ok, "expected revert but call succeeded");
        require(ret.length >= 4, "revert data too short");
        bytes4 actual = bytes4(ret);
        require(
            actual == expectedSelector,
            string.concat(
                "wrong selector: expected ",
                vm.toString(bytes32(expectedSelector)),
                " got ",
                vm.toString(bytes32(actual))
            )
        );
    }

    /// revert 模拟：指定 caller，用 vm.prank 设置 msg.sender（适用于需要特定角色才能触达目标 revert 的场景）
    function _expectRevertFrom(address caller, address target, bytes memory callData, bytes4 expectedSelector) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(callData);
        require(!ok, "expected revert but call succeeded");
        require(ret.length >= 4, "revert data too short");
        bytes4 actual = bytes4(ret);
        require(
            actual == expectedSelector,
            string.concat(
                "wrong selector: expected ",
                vm.toString(bytes32(expectedSelector)),
                " got ",
                vm.toString(bytes32(actual))
            )
        );
    }

    function _expectRevertFromWithMessage(address caller, address target, bytes memory callData, string memory expectedMsg) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(callData);
        require(!ok, "expected revert but call succeeded");
        require(ret.length >= 68, "revert data too short for Error(string)");
        string memory actualMsg = abi.decode(_slice(ret, 4, ret.length - 4), (string));
        require(
            keccak256(bytes(actualMsg)) == keccak256(bytes(expectedMsg)),
            string.concat("wrong message: expected '", expectedMsg, "' got '", actualMsg, "'")
        );
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory) {
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = data[start + i];
        }
        return result;
    }

    // ═══════════════════════════════════════════════
    //      Assertion helpers (diff-based)
    // ═══════════════════════════════════════════════

    function _assertEq(uint256 actual, uint256 expected, string memory label) internal pure {
        require(
            actual == expected,
            string.concat(label, ": expected ", vm.toString(expected), " got ", vm.toString(actual))
        );
    }

    function _assertEq(address actual, address expected, string memory label) internal pure {
        require(
            actual == expected,
            string.concat(label, ": expected ", vm.toString(expected), " got ", vm.toString(actual))
        );
    }

    function _assertEq(bool actual, bool expected, string memory label) internal pure {
        require(actual == expected, string.concat(label, ": expected ", vm.toString(expected)));
    }

    function _assertEq(string memory actual, string memory expected, string memory label) internal pure {
        require(
            keccak256(bytes(actual)) == keccak256(bytes(expected)),
            string.concat(label, ": expected '", expected, "' got '", actual, "'")
        );
    }

    function _assertDiff(uint256 before_, uint256 after_, int256 expected, string memory label) internal pure {
        int256 diff = int256(after_) - int256(before_);
        require(
            diff == expected,
            string.concat(label, ": expected diff ", vm.toString(expected), " got ", vm.toString(diff))
        );
    }

    function _assertGt(uint256 actual, uint256 threshold, string memory label) internal pure {
        require(
            actual > threshold,
            string.concat(label, ": expected > ", vm.toString(threshold), " got ", vm.toString(actual))
        );
    }

    // ═══════════════════════════════════════════════
    //      Precondition checks (原则7)
    // ═══════════════════════════════════════════════

    function _requireBalance(address account, uint256 minBalance, string memory label) internal view {
        uint256 bal = token.balanceOf(account);
        require(
            bal >= minBalance,
            string.concat(label, " balance too low: ", vm.toString(bal), " < ", vm.toString(minBalance))
        );
    }

    function _requireRole(address target, bytes32 role, address account, string memory label) internal view {
        (bool ok, bytes memory ret) = target.staticcall(
            abi.encodeWithSignature("hasRole(bytes32,address)", role, account)
        );
        require(ok && abi.decode(ret, (bool)), string.concat(label, " missing required role"));
    }

    function _requireNotPaused() internal view {
        require(!pauseManager.isTokenPaused(address(token)), "precondition: token must not be paused");
    }

    function _requirePaused() internal view {
        require(pauseManager.isTokenPaused(address(token)), "precondition: token must be paused");
    }

    // ═══════════════════════════════════════════════
    //      Common operations
    // ═══════════════════════════════════════════════

    function _mintToHotWallet(uint256 amount) internal {
        _requireNotPaused();
        _requireRole(address(vault), WALLET_OPS_ROLE, walletOps, "walletOps");
        vm.broadcast(walletOpsPk);
        vault.mint(address(token), hotWallet, amount);
    }

    function _transferFromHotWallet(address to, uint256 amount) internal {
        _requireNotPaused();
        _requireBalance(hotWallet, amount, "hotWallet");
        vm.broadcast(hotWalletPk);
        token.transfer(to, amount);
    }

    function _mintAndDistribute(address to, uint256 amount) internal {
        _mintToHotWallet(amount);
        _transferFromHotWallet(to, amount);
    }
}
