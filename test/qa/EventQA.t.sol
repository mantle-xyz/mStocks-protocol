// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PauseRegistry} from "../../src/pauseRegistry/PauseRegistry.sol";

contract EventQA is BaseQA {
    string constant MODULE = unicode"事件测试";

    event MintAllowedSet(bool allowed);
    event BurnAllowedSet(bool allowed);
    event ComplianceSet(address indexed token, address indexed oldCompliance, address indexed newCompliance);
    event PauseManagerSet(address indexed token, address indexed oldPauseManager, address indexed newPauseManager);
    event RecipientApproved(address indexed recipient);
    event RecipientRevoked(address indexed recipient);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event UsersBlocked(address indexed token, address[] users);
    event UsersUnblocked(address indexed token, address[] users);
    event UsersSanctioned(address[] users);
    event UsersUnsanctioned(address[] users);
    event SanctionsReplaced(address[] newList);
    event TokenPaused(address indexed token, address indexed pauser);
    event TokenUnpaused(address indexed token, address indexed unpauser);
    event GlobalPaused(address indexed pauser);
    event GlobalUnpaused(address indexed unpauser);

    // ═══════════════════════════════════════════════
    //      Token 开关事件
    // ═══════════════════════════════════════════════

    // ── EVT-01 ──
    function test_EVT01_MintAllowedSetFalse() public {
        _logCase("EVT-01", unicode"setMintAllowed(false) 事件");

        _step("[Step 1] tokenOps disables minting");
        vm.prank(tokenOps);
        vm.expectEmit(false, false, false, true);
        emit MintAllowedSet(false);
        token.setMintAllowed(false);
        _step("  PASS: MintAllowedSet(false) emitted");

        _logPass();
    }

    // ── EVT-02 ──
    function test_EVT02_MintAllowedSetTrue() public {
        _logCase("EVT-02", unicode"setMintAllowed(true) 事件");

        _step("[Step 1] tokenOps disables then enables");
        vm.startPrank(tokenOps);
        token.setMintAllowed(false);
        vm.expectEmit(false, false, false, true);
        emit MintAllowedSet(true);
        token.setMintAllowed(true);
        vm.stopPrank();
        _step("  PASS: MintAllowedSet(true) emitted");

        _logPass();
    }

    // ── EVT-03 ──
    function test_EVT03_BurnAllowedSetFalse() public {
        _logCase("EVT-03", unicode"setBurnAllowed(false) 事件");

        _step("[Step 1] tokenOps disables burning");
        vm.prank(tokenOps);
        vm.expectEmit(false, false, false, true);
        emit BurnAllowedSet(false);
        token.setBurnAllowed(false);
        _step("  PASS: BurnAllowedSet(false) emitted");

        _logPass();
    }

    // ── EVT-04 ──
    function test_EVT04_BurnAllowedSetTrue() public {
        _logCase("EVT-04", unicode"setBurnAllowed(true) 事件");

        _step("[Step 1] tokenOps disables then enables");
        vm.startPrank(tokenOps);
        token.setBurnAllowed(false);
        vm.expectEmit(false, false, false, true);
        emit BurnAllowedSet(true);
        token.setBurnAllowed(true);
        vm.stopPrank();
        _step("  PASS: BurnAllowedSet(true) emitted");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      Token 地址设置事件
    // ═══════════════════════════════════════════════

    // ── EVT-05 ──
    function test_EVT05_ComplianceSetEvent() public {
        _logCase("EVT-05", unicode"updateCompliance 事件");

        _step("[Step 1] deploy new ComplianceRegistry, updateCompliance on token");
        ComplianceRegistry newC = new ComplianceRegistry(admin);
        address oldC = address(token.compliance());
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit ComplianceSet(address(token), oldC, address(newC));
        token.updateCompliance(address(newC));
        _step("  PASS: ComplianceSet emitted with correct args");

        _logPass();
    }

    // ── EVT-06 ──
    function test_EVT06_PauseManagerSetEvent() public {
        _logCase("EVT-06", unicode"updatePauseManager 事件");

        _step("[Step 1] deploy new PauseRegistry, updatePauseManager on token");
        PauseRegistry newPM = new PauseRegistry(admin);
        address oldPM = address(token.pauseManager());
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit PauseManagerSet(address(token), oldPM, address(newPM));
        token.updatePauseManager(address(newPM));
        _step("  PASS: PauseManagerSet emitted with correct args");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      TokenIssuer 事件
    // ═══════════════════════════════════════════════

    // ── EVT-07 ──
    function test_EVT07_RecipientApprovedEvent() public {
        _logCase("EVT-07", unicode"addApprovedRecipient 事件");

        _step("[Step 1] admin adds new hot wallet");
        address newHW = makeAddr("newHotWallet");
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit RecipientApproved(newHW);
        vault.addApprovedRecipient(newHW);
        _step("  PASS: RecipientApproved emitted");

        _logPass();
    }

    // ── EVT-08 ──
    function test_EVT08_RecipientRevokedEvent() public {
        _logCase("EVT-08", unicode"removeApprovedRecipient 事件");

        _step("[Step 1] admin removes hotWallet1");
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit RecipientRevoked(hotWallet1);
        vault.removeApprovedRecipient(hotWallet1);
        _step("  PASS: RecipientRevoked emitted");

        _logPass();
    }

    // ── EVT-09 ──
    function test_EVT09_WithdrawnERC20Event() public {
        _logCase("EVT-09", unicode"withdraw ERC20 事件");

        _step("[Step 1] mint to wallet, admin withdraws ERC20");
        vm.prank(walletOps);
        vault.mint(address(token), address(vault), 50e18);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(address(token), admin, 50e18);
        vault.withdraw(address(token));
        _step("  PASS: Withdrawn emitted for ERC20");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      ComplianceRegistry 事件
    // ═══════════════════════════════════════════════

    // ── EVT-10 ──
    function test_EVT10_BlocklistAddEvent() public {
        _logCase("EVT-10", unicode"blockUsers 事件");

        _step("[Step 1] add userA to blocklist");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.prank(complianceOps);
        vm.expectEmit(true, false, false, true);
        emit UsersBlocked(address(token), addrs);
        compliance.blockUsers(address(token), addrs);
        _step("  PASS: AddedToBlocklist emitted");

        _logPass();
    }

    // ── EVT-11 ──
    function test_EVT11_BlocklistRemoveEvent() public {
        _logCase("EVT-11", unicode"unblockUsers 事件");

        _step("[Step 1] block then unblock userA");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.startPrank(complianceOps);
        compliance.blockUsers(address(token), addrs);
        vm.expectEmit(true, false, false, true);
        emit UsersUnblocked(address(token), addrs);
        compliance.unblockUsers(address(token), addrs);
        vm.stopPrank();
        _step("  PASS: RemovedFromBlocklist emitted");

        _logPass();
    }

    // ── EVT-12 ──
    function test_EVT12_SanctionsResetEvent() public {
        _logCase("EVT-12", unicode"clearSanctions 事件");

        _step("[Step 1] sanction userA, then reset");
        address[] memory addrs = new address[](1);
        addrs[0] = userA;
        vm.startPrank(complianceOps);
        compliance.sanctionUsers(addrs);

        address[] memory emptyList = new address[](0);
        vm.expectEmit(false, false, false, true);
        emit SanctionsReplaced(emptyList);
        compliance.clearSanctions();
        vm.stopPrank();
        _step("  PASS: SanctionsReplaced([]) emitted on reset");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      PauseRegistry 事件
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
    function test_EVT15_GlobalPausedEvent() public {
        _logCase("EVT-15", unicode"pauseGlobally 事件");

        _step("[Step 1] pauseOps pauseAll");
        vm.prank(pauseOps);
        vm.expectEmit(true, false, false, false);
        emit GlobalPaused(pauseOps);
        pauseManager.pauseGlobally();
        _step("  PASS: GlobalPaused emitted");

        _logPass();
    }

    // ── EVT-16 ──
    function test_EVT16_GlobalUnpausedEvent() public {
        _logCase("EVT-16", unicode"unpauseGlobally 事件");

        _step("[Step 1] pauseAll then unpauseAll");
        vm.startPrank(pauseOps);
        pauseManager.pauseGlobally();
        vm.expectEmit(true, false, false, false);
        emit GlobalUnpaused(pauseOps);
        pauseManager.unpauseGlobally();
        vm.stopPrank();
        _step("  PASS: GlobalUnpaused emitted");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      TokenIssuer.mint/burn 事件
    // ═══════════════════════════════════════════════

    event Minted(address indexed vault, address indexed token, address indexed recipient, uint256 amount);
    event Burned(address indexed vault, address indexed token, address indexed from, uint256 amount);

    // ── EVT-17 ──
    function test_EVT17_MintedEvent() public {
        _logCase("EVT-17", unicode"vault.mint 事件");

        _step("[Step 1] walletOps mints 100e18 to hotWallet1 via vault");
        uint256 amount = 100e18;
        vm.prank(walletOps);
        vm.expectEmit(true, true, true, true);
        emit Minted(address(vault), address(token), hotWallet1, amount);
        vault.mint(address(token), hotWallet1, amount);
        _step("  PASS: Minted(vault, token, hotWallet1, 100e18) emitted");

        _logPass();
    }

    // ── EVT-18 ──
    function test_EVT18_BurnedEvent() public {
        _logCase("EVT-18", unicode"vault.burn 事件");

        _step("[Step 1] mint 200e18 to hotWallet1, hotWallet1 approves vault");
        uint256 amount = 200e18;
        vm.prank(walletOps);
        vault.mint(address(token), hotWallet1, amount);
        vm.prank(hotWallet1);
        token.approve(address(vault), amount);

        _step("[Step 2] walletOps burns 200e18 from hotWallet1 via vault");
        vm.prank(walletOps);
        vm.expectEmit(true, true, true, true);
        emit Burned(address(vault), address(token), hotWallet1, amount);
        vault.burn(address(token), hotWallet1, amount);
        _step("  PASS: Burned(vault, token, hotWallet1, 200e18) emitted");

        _logPass();
    }

    // ── EVT-19 ──
    function test_EVT19_MintedToSelfEvent() public {
        _logCase("EVT-19", unicode"vault.mint(self) 事件");

        _step("[Step 1] walletOps mints 50e18 to vault itself");
        uint256 amount = 50e18;
        vm.prank(walletOps);
        vm.expectEmit(true, true, true, true);
        emit Minted(address(vault), address(token), address(vault), amount);
        vault.mint(address(token), address(vault), amount);
        _step("  PASS: Minted(vault, token, vault, 50e18) emitted");

        _logPass();
    }
}
