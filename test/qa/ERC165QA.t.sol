// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ERC165QA is BaseQA {
    string constant MODULE = "ERC-165";

    // ── ERC165-01 ──
    function test_ERC16501_IERC165() public {
        _logCase("ERC165-01", "IERC165");

        _step("[Step 1] supportsInterface(0x01ffc9a7)");
        assertTrue(token.supportsInterface(0x01ffc9a7));
        _step("  PASS: true");

        _logPass();
    }

    // ── ERC165-02 ──
    function test_ERC16502_IERC20() public {
        _logCase("ERC165-02", "IERC20");

        _step("[Step 1] supportsInterface(0x36372b07)");
        assertTrue(token.supportsInterface(0x36372b07));
        _step("  PASS: true");

        _logPass();
    }

    // ── ERC165-03 ──
    function test_ERC16503_IScaledUIAmount() public {
        _logCase("ERC165-03", "IScaledUIAmount");

        _step("[Step 1] supportsInterface(0xa60bf13d)");
        assertTrue(token.supportsInterface(0xa60bf13d));
        _step("  PASS: true");

        _logPass();
    }

    // ── ERC165-04 ──
    function test_ERC16504_IScaledUIAmountNewUIMultiplier() public {
        _logCase("ERC165-04", "IScaledUIAmountNewUIMultiplier");

        _step("[Step 1] supportsInterface(0x4bd27648)");
        assertTrue(token.supportsInterface(0x4bd27648));
        _step("  PASS: true");

        _logPass();
    }

    // ── ERC165-05 ──
    function test_ERC16505_IScaledUIAmountConversion() public {
        _logCase("ERC165-05", "IScaledUIAmountConversion");

        _step("[Step 1] supportsInterface(0x57854fc3)");
        assertTrue(token.supportsInterface(0x57854fc3));
        _step("  PASS: true");

        _logPass();
    }

    // ── ERC165-06 ──
    function test_ERC16506_IScaledUIAmountBalances() public {
        _logCase("ERC165-06", "IScaledUIAmountBalances");

        _step("[Step 1] supportsInterface(0xd890fd71)");
        assertTrue(token.supportsInterface(0xd890fd71));
        _step("  PASS: true");

        _logPass();
    }

    // ── ERC165-07 ──
    function test_ERC16507_IERC8056Scheduled() public {
        _logCase("ERC165-07", "IERC8056Scheduled");

        _step("[Step 1] supportsInterface(0xeb0093dd)");
        assertTrue(token.supportsInterface(0xeb0093dd));
        _step("  PASS: true");

        _logPass();
    }

    // ── ERC165-08 ──
    function test_ERC16508_IAccessControl() public {
        _logCase("ERC165-08", "IAccessControl");

        _step("[Step 1] supportsInterface(IAccessControl interfaceId)");
        assertTrue(token.supportsInterface(type(IAccessControl).interfaceId));
        _step("  PASS: true");

        _logPass();
    }

    // ── ERC165-09 ──
    function test_ERC16509_UnsupportedInterface() public {
        _logCase("ERC165-09", unicode"不支持的接口");

        _step("[Step 1] supportsInterface(0xdeadbeef)");
        assertFalse(token.supportsInterface(0xdeadbeef));
        _step("  PASS: false");

        _logPass();
    }
}
