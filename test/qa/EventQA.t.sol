// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {SecuritiesToken} from "../../src/securitiesToken/SecuritiesToken.sol";
import {Compliance} from "../../src/compliance/Compliance.sol";
import {PauseManager} from "../../src/pauseManager/PauseManager.sol";

contract EventQA is BaseQA {
    string constant MODULE = unicode"事件测试";

    event MintEnabledSet(bool enabled);
    event BurnEnabledSet(bool enabled);
    event ComplianceSet(address indexed token, address indexed oldCompliance, address indexed newCompliance);
    event PauseManagerSet(address indexed token, address indexed oldPauseManager, address indexed newPauseManager);
    event HotWalletAdded(address indexed hotwallet);
    event HotWalletRemoved(address indexed hotwallet);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event AddedToBlocklist(address indexed token, address[] addresses);
    event RemovedFromBlocklist(address indexed token, address[] addresses);
    event AddedToSanctionsList(address[] addresses);
    event RemovedFromSanctionsList(address[] addresses);
    event SanctionedAddressesSet(address[] newList);
    event TokenPaused(address indexed token, address indexed pauser);
    event TokenUnpaused(address indexed token, address indexed unpauser);
    event AllTokensPaused(address indexed pauser);
    event AllTokensUnpaused(address indexed unpauser);

    // ═══════════════════════════════════════════════
    //      Token 开关事件
    // ═══════════════════════════════════════════════

    // ── EVT-01 ──
    function test_EVT01_MintEnabledSetFalse() public {
        _logCase("EVT-01", unicode"setMintEnabled(false) 事件");

        _step("[Step 1] admin disables minting");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit MintEnabledSet(false);
        token.setMintEnabled(false);
        _step("  PASS: MintEnabledSet(false) emitted");

        _logPass();
    }

    // ── EVT-02 ──
    function test_EVT02_MintEnabledSetTrue() public {
        _logCase("EVT-02", unicode"setMintEnabled(true) 事件");

        _step("[Step 1] admin disables then enables");
        vm.startPrank(admin);
        token.setMintEnabled(false);
        vm.expectEmit(false, false, false, true);
        emit MintEnabledSet(true);
        token.setMintEnabled(true);
        vm.stopPrank();
        _step("  PASS: MintEnabledSet(true) emitted");

        _logPass();
    }

    // ── EVT-03 ──
    function test_EVT03_BurnEnabledSetFalse() public {
        _logCase("EVT-03", unicode"setBurnEnabled(false) 事件");

        _step("[Step 1] admin disables burning");
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit BurnEnabledSet(false);
        token.setBurnEnabled(false);
        _step("  PASS: BurnEnabledSet(false) emitted");

        _logPass();
    }

    // ── EVT-04 ──
    function test_EVT04_BurnEnabledSetTrue() public {
        _logCase("EVT-04", unicode"setBurnEnabled(true) 事件");

        _step("[Step 1] admin disables then enables");
        vm.startPrank(admin);
        token.setBurnEnabled(false);
        vm.expectEmit(false, false, false, true);
        emit BurnEnabledSet(true);
        token.setBurnEnabled(true);
        vm.stopPrank();
        _step("  PASS: BurnEnabledSet(true) emitted");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Token 地址设置事件
    // ═══════════════════════════════════════════════

    // ── EVT-05 ──
    function test_EVT05_ComplianceSetEvent() public {
        _logCase("EVT-05", unicode"setCompliance 事件");

        _step("[Step 1] deploy new Compliance, setCompliance on token");
        Compliance newC = new Compliance(admin);
        address oldC = address(token.compliance());
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ComplianceSet(address(token), oldC, address(newC));
        token.setCompliance(address(newC));
        _step("  PASS: ComplianceSet emitted with correct args");

        _logPass();
    }

    // ── EVT-06 ──
    function test_EVT06_PauseManagerSetEvent() public {
        _logCase("EVT-06", unicode"setPauseManager 事件");

        _step("[Step 1] deploy new PauseManager, setPauseManager on token");
        PauseManager newPM = new PauseManager(admin);
        address oldPM = address(token.pauseManager());
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit PauseManagerSet(address(token), oldPM, address(newPM));
        token.setPauseManager(address(newPM));
        _step("  PASS: PauseManagerSet emitted with correct args");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      OperatorWallet 事件
    // ═══════════════════════════════════════════════

    // ── EVT-07 ──
    function test_EVT07_HotWalletAddedEvent() public {
        _logCase("EVT-07", unicode"addHotWallet 事件");

        _step("[Step 1] admin adds new hot wallet");
        address newHW = makeAddr("newHotWallet");
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit HotWalletAdded(newHW);
        wallet.addHotWallet(newHW);
        _step("  PASS: HotWalletAdded emitted");

        _logPass();
    }

    // ── EVT-08 ──
    function test_EVT08_HotWalletRemovedEvent() public {
        _logCase("EVT-08", unicode"removeHotWallet 事件");

        _step("[Step 1] admin removes hotWallet1");
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit HotWalletRemoved(hotWallet1);
        wallet.removeHotWallet(hotWallet1);
        _step("  PASS: HotWalletRemoved emitted");

        _logPass();
    }

    // ── EVT-09 ──
    function test_EVT09_WithdrawnNativeEvent() public {
        _logCase("EVT-09", unicode"withdraw native 事件");

        _step("[Step 1] fund wallet, admin withdraws");
        vm.deal(address(wallet), 1 ether);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(address(0), admin, 1 ether);
        wallet.withdraw(address(0));
        _step("  PASS: Withdrawn emitted");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Compliance 事件
    // ═══════════════════════════════════════════════

    // ── EVT-10 ──
    function test_EVT10_BlocklistAddEvent() public {
        _logCase("EVT-10", unicode"addToBlocklist 事件");

        _step("[Step 1] add userA to blocklist");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        vm.expectEmit(true, false, false, true);
        emit AddedToBlocklist(address(token), addrs);
        compliance.addToBlocklist(address(token), addrs);
        _step("  PASS: AddedToBlocklist emitted");

        _logPass();
    }

    // ── EVT-11 ──
    function test_EVT11_BlocklistRemoveEvent() public {
        _logCase("EVT-11", unicode"removeFromBlocklist 事件");

        _step("[Step 1] block then unblock userA");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.startPrank(complianceOps);
        compliance.addToBlocklist(address(token), addrs);
        vm.expectEmit(true, false, false, true);
        emit RemovedFromBlocklist(address(token), addrs);
        compliance.removeFromBlocklist(address(token), addrs);
        vm.stopPrank();
        _step("  PASS: RemovedFromBlocklist emitted");

        _logPass();
    }

    // ── EVT-12 ──
    function test_EVT12_SanctionsResetEvent() public {
        _logCase("EVT-12", unicode"resetSanctionedAddresses 事件");

        _step("[Step 1] sanction userA, then reset");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.startPrank(complianceOps);
        compliance.addToSanctionsList(addrs);

        address[] memory emptyList = new address[](0);
        vm.expectEmit(false, false, false, true);
        emit SanctionedAddressesSet(emptyList);
        compliance.resetSanctionedAddresses();
        vm.stopPrank();
        _step("  PASS: SanctionedAddressesSet([]) emitted on reset");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      PauseManager 事件
    // ═══════════════════════════════════════════════

    // ── EVT-13 ──
    function test_EVT13_TokenPausedEvent() public {
        _logCase("EVT-13", unicode"pauseToken 事件");

        _step("[Step 1] pauseOps pauses token");
        vm.prank(pauseOps);
        vm.expectEmit(true, true, false, false);
        emit TokenPaused(address(token), pauseOps);
        pauseManager.pauseToken(address(token));
        _step("  PASS: TokenPaused emitted");

        _logPass();
    }

    // ── EVT-14 ──
    function test_EVT14_TokenUnpausedEvent() public {
        _logCase("EVT-14", unicode"unpauseToken 事件");

        _step("[Step 1] pause then unpause");
        vm.startPrank(pauseOps);
        pauseManager.pauseToken(address(token));
        vm.expectEmit(true, true, false, false);
        emit TokenUnpaused(address(token), pauseOps);
        pauseManager.unpauseToken(address(token));
        vm.stopPrank();
        _step("  PASS: TokenUnpaused emitted");

        _logPass();
    }

    // ── EVT-15 ──
    function test_EVT15_AllTokensPausedEvent() public {
        _logCase("EVT-15", unicode"pauseAllTokens 事件");

        _step("[Step 1] pauseOps pauseAll");
        vm.prank(pauseOps);
        vm.expectEmit(true, false, false, false);
        emit AllTokensPaused(pauseOps);
        pauseManager.pauseAllTokens();
        _step("  PASS: AllTokensPaused emitted");

        _logPass();
    }

    // ── EVT-16 ──
    function test_EVT16_AllTokensUnpausedEvent() public {
        _logCase("EVT-16", unicode"unpauseAllTokens 事件");

        _step("[Step 1] pauseAll then unpauseAll");
        vm.startPrank(pauseOps);
        pauseManager.pauseAllTokens();
        vm.expectEmit(true, false, false, false);
        emit AllTokensUnpaused(pauseOps);
        pauseManager.unpauseAllTokens();
        vm.stopPrank();
        _step("  PASS: AllTokensUnpaused emitted");

        _logPass();
    }
}
