// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ScaledTokenFactory} from "../../src/scaledToken/ScaledTokenFactory.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract QAFactory is BaseQAScript {
    function run() external {
        _loadEnv();

        test_FT01();
        test_FT02();
        test_FT03();
        test_FT04();
        test_FT05();
        test_FT06();
        test_FT07();
        test_FT08();
    }

    // ── QA-FT-01: 部署新 token ──
    function test_FT01() public {
        _logCase("QA-FT-01", unicode"部署新 token");

        _step("[Step 1] record tokenCount before");
        uint256 countBefore = factory.tokenCount();
        _step(string.concat("  count before: ", vm.toString(countBefore)));

        _step("[Step 2] factoryOps deploys new token");
        string memory sym = _uniqueSymbol("FT");
        vm.broadcast(factoryOpsPk);
        address newToken = factory.createToken("Test Corp", sym, "FT001", admin, new address[](0), new address[](0), new address[](0));
        _assertGt(uint160(newToken), 0, "newToken != address(0)");
        _step(string.concat("  newToken: ", vm.toString(newToken)));

        _step("[Step 3] verify count increased");
        _assertEq(factory.tokenCount(), countBefore + 1, "count increased");
        _step("  PASS: tokenCount +1");

        _logPass();
    }

    // ── QA-FT-02: 重复 symbol 回滚 ──
    function test_FT02() public {
        _logCase("QA-FT-02", unicode"重复 symbol 回滚");

        _step("[Step 1] precondition: AAPL already exists");
        address existing = factory.tokenBySymbol("AAPL");
        _assertGt(uint160(existing), 0, "AAPL exists");

        _step("[Step 2] factoryOps tries createToken with same symbol AAPL");
        _expectRevertFrom(
            factoryOps,
            address(factory),
            abi.encodeWithSelector(
                factory.createToken.selector,
                "Dup Corp", "AAPL", "DUP001", admin, new address[](0), new address[](0), new address[](0)
            ),
            ScaledTokenFactory.TokenSymbolAlreadyExists.selector
        );
        _step("  PASS: reverted TokenSymbolAlreadyExists()");

        _logPass();
    }

    // ── QA-FT-03: 无效 symbol 回滚 ──
    function test_FT03() public {
        _logCase("QA-FT-03", unicode"无效 symbol 回滚");

        _step("[Step 1] factoryOps tries createToken with invalid symbol 'AAPL!'");
        _expectRevertFrom(
            factoryOps,
            address(factory),
            abi.encodeWithSelector(
                factory.createToken.selector,
                "Bad Corp", "AAPL!", "BAD001", admin, new address[](0), new address[](0), new address[](0)
            ),
            ScaledTokenFactory.InvalidSymbol.selector
        );
        _step("  PASS: reverted InvalidSymbol()");

        _logPass();
    }

    // ── QA-FT-04: tokenBySymbol 正确 ──
    function test_FT04() public {
        _logCase("QA-FT-04", unicode"tokenBySymbol 正确");

        _step("[Step 1] query tokenBySymbol('AAPL')");
        address result = factory.tokenBySymbol("AAPL");
        _assertEq(result, address(token), "tokenBySymbol matches");
        _step("  PASS: tokenBySymbol('AAPL') == TOKEN_ADDR");

        _logPass();
    }

    // ── QA-FT-05: 多 token 部署 ──
    function test_FT05() public {
        _logCase("QA-FT-05", unicode"多 token 部署");

        _step("[Step 1] record count before");
        uint256 countBefore = factory.tokenCount();

        _step("[Step 2] deploy 3 tokens");
        string memory s1 = _uniqueSymbol("T1");
        string memory s2 = _uniqueSymbol("T2");
        string memory s3 = _uniqueSymbol("T3");
        vm.broadcast(factoryOpsPk);
        address t1 = factory.createToken("Corp One", s1, "T001", admin, new address[](0), new address[](0), new address[](0));
        vm.broadcast(factoryOpsPk);
        address t2 = factory.createToken("Corp Two", s2, "T002", admin, new address[](0), new address[](0), new address[](0));
        vm.broadcast(factoryOpsPk);
        address t3 = factory.createToken("Corp Three", s3, "T003", admin, new address[](0), new address[](0), new address[](0));

        _step("[Step 3] verify count");
        _assertEq(factory.tokenCount(), countBefore + 3, "count +3");
        _step("  PASS: tokenCount +3");

        _step("[Step 4] verify tokenBySymbol mappings");
        _assertEq(factory.tokenBySymbol(s1), t1, "s1 mapping");
        _assertEq(factory.tokenBySymbol(s2), t2, "s2 mapping");
        _assertEq(factory.tokenBySymbol(s3), t3, "s3 mapping");
        _step("  PASS: all tokenBySymbol mappings correct");

        _logPass();
    }

    // ── QA-FT-06: updateSymbol 完整流程 ──
    function test_FT06() public {
        _logCase("QA-FT-06", unicode"updateSymbol 完整流程");

        _step("[Step 1] deploy tokenB with dynamic symbol");
        string memory oldSym = _uniqueSymbol("SA");
        string memory newSym = _uniqueSymbol("SB");
        address[] memory opsArr = new address[](1);
        opsArr[0] = tokenOps;
        vm.broadcast(factoryOpsPk);
        address tokenBAddr = factory.createToken("Sym Corp", oldSym, "SYM001", admin, new address[](0), new address[](0), opsArr);
        ScaledToken tokenB = ScaledToken(tokenBAddr);
        _assertEq(factory.tokenBySymbol(oldSym), tokenBAddr, "oldSym mapped");

        _step(string.concat("[Step 2] tokenOps sets token symbol to '", newSym, "'"));
        vm.broadcast(tokenOpsPk);
        tokenB.updateSymbol(newSym);
        _assertEq(tokenB.symbol(), newSym, "token symbol updated");

        _step("[Step 3] factoryOps calls factory.renameSymbol");
        vm.broadcast(factoryOpsPk);
        factory.renameSymbol(tokenBAddr, oldSym, newSym);
        _assertEq(factory.tokenBySymbol(oldSym), address(0), "oldSym cleared");
        _assertEq(factory.tokenBySymbol(newSym), tokenBAddr, "newSym mapped");
        _step("  PASS: updateSymbol complete");

        _logPass();
    }

    // ── QA-FT-07: symbol 变更不自动同步 ──
    function test_FT07() public {
        _logCase("QA-FT-07", unicode"symbol 变更不自动同步");

        string memory ts = vm.toString(block.timestamp);
        string memory oldSym = string.concat("OD", ts);
        string memory newSym = string.concat("NW", ts);

        _step(string.concat("[Step 1] deploy tokenB with symbol '", oldSym, "'"));
        address[] memory opsArr = new address[](1);
        opsArr[0] = tokenOps;
        vm.broadcast(factoryOpsPk);
        address tokenBAddr = factory.createToken("Old Corp", oldSym, "OLD001", admin, new address[](0), new address[](0), opsArr);
        ScaledToken tokenB = ScaledToken(tokenBAddr);

        _step(string.concat("[Step 2] only set token symbol to '", newSym, "', don't call factory.renameSymbol"));
        vm.broadcast(tokenOpsPk);
        tokenB.updateSymbol(newSym);
        _assertEq(tokenB.symbol(), newSym, "token symbol changed");

        _step("[Step 3] factory still maps old symbol");
        _assertEq(factory.tokenBySymbol(oldSym), tokenBAddr, "old symbol still mapped");
        _assertEq(factory.tokenBySymbol(newSym), address(0), "new symbol not mapped");
        _step("  PASS: factory not auto-synced (design behavior)");

        _logPass();
    }

    // ── QA-FT-08: 非 OPS_ROLE 不能部署 ──
    function test_FT08() public {
        _logCase("QA-FT-08", unicode"非 OPS_ROLE 不能部署");

        _step("[Step 1] precondition: userA has no OPS_ROLE on factory");
        _assertEq(factory.hasRole(FACTORY_OPS_ROLE, userA), false, "userA no OPS_ROLE");

        _step("[Step 2] userA tries createToken");
        _expectRevertFrom(
            userA,
            address(factory),
            abi.encodeWithSelector(
                factory.createToken.selector,
                "User Corp", "USRA", "USR001", userA, new address[](0), new address[](0), new address[](0)
            ),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  PASS: reverted AccessControlUnauthorizedAccount()");

        _logPass();
    }
}
