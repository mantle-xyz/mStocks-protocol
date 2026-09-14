// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BaseQA} from "./BaseQA.t.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";
import {ComplianceRegistry} from "../../src/complianceRegistry/ComplianceRegistry.sol";
import {PrivatizationRegistry} from "../../src/privatization/PrivatizationRegistry.sol";
import {CustodyClaimRouter} from "../../src/privatization/CustodyClaimRouter.sol";
import {MockUSD} from "../mocks/MockUSD.sol";

contract FuzzQA is BaseQA {
    // ═══════════════════════════════════════════════
    //      1. 乘数算术 Fuzz
    // ═══════════════════════════════════════════════

    function _activateMultiplier(uint256 m) internal {
        uint256 effectiveAt = block.timestamp + 1 hours;
        vm.prank(operator);
        token.setUIMultiplier(m, effectiveAt);
        vm.warp(effectiveAt);
    }

    function testFuzz_RoundTripPrecision(uint256 rawAmount, uint256 multiplier) public {
        _logCase("FUZZ-MUL-01", unicode"乘数往返精度");
        multiplier = bound(multiplier, 1e9, 1e27);
        rawAmount = bound(rawAmount, 0, type(uint128).max);
        _activateMultiplier(multiplier);

        uint256 ui = token.toUIAmount(rawAmount);
        uint256 roundTrip = token.fromUIAmount(ui);
        assertLe(roundTrip, rawAmount);
        uint256 maxError = 1e18 / multiplier + 1;
        assertLe(rawAmount - roundTrip, maxError);
        _logPass();
    }

    function testFuzz_ToUIAmountMonotonic(uint256 a, uint256 b, uint256 multiplier) public {
        _logCase("FUZZ-MUL-02", unicode"toUIAmount 单调性");
        multiplier = bound(multiplier, 1e9, 1e27);
        a = bound(a, 0, type(uint256).max / multiplier);
        b = bound(b, a, type(uint256).max / multiplier);
        _activateMultiplier(multiplier);

        assertLe(token.toUIAmount(a), token.toUIAmount(b));
        _logPass();
    }

    function testFuzz_FromUIAmountMonotonic(uint256 a, uint256 b, uint256 multiplier) public {
        _logCase("FUZZ-MUL-03", unicode"fromUIAmount 单调性");
        multiplier = bound(multiplier, 1e9, 1e27);
        uint256 maxUI = multiplier >= 1e18
            ? type(uint256).max
            : type(uint256).max / 1e18 * multiplier;
        a = bound(a, 0, maxUI);
        b = bound(b, a, maxUI);
        _activateMultiplier(multiplier);

        assertLe(token.fromUIAmount(a), token.fromUIAmount(b));
        _logPass();
    }

    function testFuzz_ZeroInputAlwaysZero(uint256 multiplier) public {
        _logCase("FUZZ-MUL-04", unicode"零输入恒零");
        multiplier = bound(multiplier, 1e9, 1e27);
        _activateMultiplier(multiplier);

        assertEq(token.toUIAmount(0), 0);
        assertEq(token.fromUIAmount(0), 0);
        _logPass();
    }

    function testFuzz_MultiplierBelowMinRejects(uint256 multiplier) public {
        _logCase("FUZZ-MUL-05", unicode"乘数下限拒绝");
        multiplier = bound(multiplier, 0, 1e9 - 1);
        uint256 effectiveAt = block.timestamp + 1 hours;

        vm.prank(operator);
        vm.expectRevert("ScaledToken: multiplier below minimum (1e-9x)");
        token.setUIMultiplier(multiplier, effectiveAt);
        _logPass();
    }

    function testFuzz_MultiplierAboveMaxRejects(uint256 multiplier) public {
        _logCase("FUZZ-MUL-06", unicode"乘数上限拒绝");
        multiplier = bound(multiplier, 1e27 + 1, type(uint256).max);
        uint256 effectiveAt = block.timestamp + 1 hours;

        vm.prank(operator);
        vm.expectRevert("ScaledToken: multiplier above maximum (1e9x)");
        token.setUIMultiplier(multiplier, effectiveAt);
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      2. ComplianceRegistry 批量操作 Fuzz
    // ═══════════════════════════════════════════════

    function _generateAddresses(uint256 count, uint256 seed) internal pure returns (address[] memory) {
        address[] memory addrs = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
            if (a == address(0)) a = address(uint160(1));
            addrs[i] = a;
        }
        return addrs;
    }

    function testFuzz_BlocklistAddRemove(uint8 count, uint256 seed) public {
        _logCase("FUZZ-CMP-01", unicode"黑名单增删");
        count = uint8(bound(count, 1, 20));
        address[] memory addrs = _generateAddresses(count, seed);

        vm.prank(complianceOps);
        compliance.blockUsers(address(token), addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            assertTrue(compliance.isBlocked(address(token), addrs[i]));
        }

        vm.prank(complianceOps);
        compliance.unblockUsers(address(token), addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            assertFalse(compliance.isBlocked(address(token), addrs[i]));
        }
        _logPass();
    }

    function testFuzz_BlocklistAndSanctionsDualListed(uint8 count, uint256 seed) public {
        _logCase("FUZZ-CMP-02", unicode"黑名单+制裁双重");
        count = uint8(bound(count, 1, 20));
        address[] memory addrs = _generateAddresses(count, seed);

        vm.prank(complianceOps);
        compliance.blockUsers(address(token), addrs);
        vm.prank(complianceOps);
        compliance.sanctionUsers(addrs);

        // blocklist checked first → UserBlocked
        for (uint256 i = 0; i < addrs.length; ++i) {
            vm.expectRevert(ComplianceRegistry.UserBlocked.selector);
            compliance.checkIsCompliant(address(token), addrs[i]);
        }

        // remove from blocklist → still sanctioned → UserSanctioned
        vm.prank(complianceOps);
        compliance.unblockUsers(address(token), addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            vm.expectRevert(ComplianceRegistry.UserSanctioned.selector);
            compliance.checkIsCompliant(address(token), addrs[i]);
        }

        // remove from sanctions → compliant
        vm.prank(complianceOps);
        compliance.unsanctionUsers(addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            compliance.checkIsCompliant(address(token), addrs[i]);
        }
        _logPass();
    }

    function testFuzz_SanctionsEpochReset(uint8 count, uint256 seed) public {
        _logCase("FUZZ-CMP-03", unicode"制裁 epoch 重置");
        count = uint8(bound(count, 1, 20));
        address[] memory addrs = _generateAddresses(count, seed);

        vm.prank(complianceOps);
        compliance.sanctionUsers(addrs);
        for (uint256 i = 0; i < addrs.length; ++i) {
            assertTrue(compliance.isSanctioned(addrs[i]));
        }

        vm.prank(complianceOps);
        compliance.clearSanctions();
        for (uint256 i = 0; i < addrs.length; ++i) {
            assertFalse(compliance.isSanctioned(addrs[i]));
        }
        _logPass();
    }

    function testFuzz_SanctionsSetReplace(uint8 countA, uint8 countB, uint256 seed) public {
        _logCase("FUZZ-CMP-04", unicode"制裁列表替换");
        countA = uint8(bound(countA, 1, 20));
        countB = uint8(bound(countB, 1, 20));
        address[] memory listA = _generateAddresses(countA, seed);
        address[] memory listB = _generateAddresses(countB, uint256(keccak256(abi.encode(seed))));

        vm.prank(complianceOps);
        compliance.replaceSanctions(listA);
        for (uint256 i = 0; i < listA.length; ++i) {
            assertTrue(compliance.isSanctioned(listA[i]));
        }

        vm.prank(complianceOps);
        compliance.replaceSanctions(listB);
        for (uint256 i = 0; i < listA.length; ++i) {
            assertFalse(compliance.isSanctioned(listA[i]));
        }
        for (uint256 i = 0; i < listB.length; ++i) {
            assertTrue(compliance.isSanctioned(listB[i]));
        }
        _logPass();
    }

    function testFuzz_SanctionsSetOverlap(uint8 countOnly, uint8 countShared, uint256 seed) public {
        _logCase("FUZZ-CMP-05", unicode"制裁列表重叠替换");
        countOnly = uint8(bound(countOnly, 1, 10));
        countShared = uint8(bound(countShared, 1, 10));

        address[] memory onlyA = _generateAddresses(countOnly, seed);
        address[] memory shared = _generateAddresses(countShared, uint256(keccak256(abi.encode(seed, "shared"))));

        // listA = onlyA + shared
        address[] memory listA = new address[](countOnly + countShared);
        for (uint256 i = 0; i < countOnly; ++i) listA[i] = onlyA[i];
        for (uint256 i = 0; i < countShared; ++i) listA[countOnly + i] = shared[i];

        // listB = shared (overlap portion only)
        vm.prank(complianceOps);
        compliance.replaceSanctions(listA);

        vm.prank(complianceOps);
        compliance.replaceSanctions(shared);

        // onlyA addresses should be cleared
        for (uint256 i = 0; i < onlyA.length; ++i) {
            assertFalse(compliance.isSanctioned(onlyA[i]));
        }
        // shared addresses should still be sanctioned
        for (uint256 i = 0; i < shared.length; ++i) {
            assertTrue(compliance.isSanctioned(shared[i]));
        }
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      3. 供应量守恒 Fuzz
    // ═══════════════════════════════════════════════

    function testFuzz_TransferConservesTotalSupply(uint256 mintAmt, uint256 txAmt) public {
        _logCase("FUZZ-SUP-01", unicode"transfer 供应量守恒");
        mintAmt = bound(mintAmt, 1, 1e30);
        txAmt = bound(txAmt, 0, mintAmt);

        _issuerMint(mintAmt);
        vm.prank(issuer);
        token.transfer(userA, txAmt);

        assertEq(token.totalSupply(), mintAmt);
        assertEq(token.balanceOf(issuer) + token.balanceOf(userA), mintAmt);
        _logPass();
    }

    function testFuzz_TransferFromConservesTotalSupply(uint256 mintAmt, uint256 txAmt) public {
        _logCase("FUZZ-SUP-02", unicode"transferFrom 供应量守恒");
        mintAmt = bound(mintAmt, 1, 1e30);
        txAmt = bound(txAmt, 0, mintAmt);

        _issuerMint(mintAmt);
        vm.prank(issuer);
        token.transfer(userA, mintAmt);

        vm.prank(userA);
        token.approve(userB, txAmt);
        vm.prank(userB);
        token.transferFrom(userA, userB, txAmt);

        assertEq(token.totalSupply(), mintAmt);
        assertEq(token.balanceOf(userA) + token.balanceOf(userB), mintAmt);
        _logPass();
    }

    function testFuzz_MintBurnSupplyAccounting(uint256 mintAmt, uint256 burnAmt) public {
        _logCase("FUZZ-SUP-03", unicode"mint/burn 供应量记账");
        mintAmt = bound(mintAmt, 1, 1e30);
        burnAmt = bound(burnAmt, 0, mintAmt);

        _issuerMint(mintAmt);
        vm.prank(issuer);
        token.burn(burnAmt);

        assertEq(token.totalSupply(), mintAmt - burnAmt);
        assertEq(token.balanceOf(issuer), mintAmt - burnAmt);
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      4. 权限矩阵 Fuzz
    // ═══════════════════════════════════════════════

    function testFuzz_UnauthorizedMintReverts(address caller) public {
        _logCase("FUZZ-PERM-01", unicode"未授权 mint 拒绝");
        vm.assume(caller != issuer && caller != address(vault));
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.mint(1e18);
        _logPass();
    }

    function testFuzz_UnauthorizedSetMultiplierReverts(address caller) public {
        _logCase("FUZZ-PERM-02", unicode"未授权 setMultiplier 拒绝");
        vm.assume(caller != operator);
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(ScaledToken.UnauthorizedRole.selector);
        token.setUIMultiplier(2e18, block.timestamp + 1 hours);
        _logPass();
    }

    function testFuzz_UnauthorizedAdminFunctionReverts(address caller) public {
        _logCase("FUZZ-PERM-03", unicode"未授权 OPS 函数拒绝");
        vm.assume(caller != tokenOps);
        vm.assume(caller != admin);
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, TOKEN_OPS_ROLE)
        );
        token.updateName("Hacked");
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      5. 私有化比例分配守恒 Fuzz
    // ═══════════════════════════════════════════════

    PrivatizationRegistry internal _prvRegistry;
    CustodyClaimRouter internal _prvRouter;
    MockUSD internal _prvUsdc;

    function _deployPrivatizationStack() internal {
        vm.startPrank(admin);
        _prvUsdc = new MockUSD();
        address[] memory prvOps = new address[](1);
        prvOps[0] = address(this);
        _prvRegistry = PrivatizationRegistry(
            address(
                new ERC1967Proxy(
                    address(new PrivatizationRegistry()),
                    abi.encodeCall(PrivatizationRegistry.initialize, (admin, prvOps))
                )
            )
        );
        _prvRouter = CustodyClaimRouter(
            address(
                new ERC1967Proxy(
                    address(new CustodyClaimRouter()),
                    abi.encodeCall(CustodyClaimRouter.initialize, (address(_prvRegistry), admin, prvOps))
                )
            )
        );
        _prvRouter.registerHotWallet(hotWallet1);
        vm.stopPrank();
    }

    function _prvProgram(uint256 snapshot, uint256 legTotal)
        internal
        returns (uint256 pid, ScaledToken old)
    {
        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        address[] memory none = new address[](0);
        old = ScaledToken(
            factory.createToken("Fuzz Old", "FOLD", "US9999999901", admin, issuers, none, none)
        );

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(_prvUsdc), legTotal);
        pid = _prvRegistry.createProgram(address(old), legs);

        vm.startPrank(admin);
        old.grantRole(old.BURN_ROLE(), address(_prvRegistry));
        old.grantRole(old.OPS_ROLE(), tokenOps);
        vm.stopPrank();

        old.mint(snapshot);

        vm.prank(tokenOps);
        old.setMintAllowed(false);

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: snapshot,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        _prvRegistry.configureProgram(pid, cfg);

        _prvUsdc.mint(address(this), legTotal);
        _prvUsdc.approve(address(_prvRegistry), legTotal);
        _prvRegistry.fund(pid, address(_prvUsdc), legTotal);
    }

    function testFuzz_SingleClaimNoOverIssuance(uint256 amount, uint256 legTotal, uint256 snapshot) public {
        _logCase("FUZZ-PRV-01", unicode"单人 claim 不超发");
        snapshot = bound(snapshot, 1, 1e30);
        amount = bound(amount, 1, snapshot);
        legTotal = bound(legTotal, 1, 1e30);

        _deployPrivatizationStack();
        (uint256 pid, ScaledToken old) = _prvProgram(snapshot, legTotal);
        old.transfer(userA, amount);

        uint256[] memory preview = _prvRegistry.previewClaim(pid, amount);
        if (preview[0] == 0) return;

        vm.startPrank(userA);
        old.approve(address(_prvRegistry), amount);
        _prvRegistry.claim(pid, amount);
        vm.stopPrank();

        assertLe(_prvUsdc.balanceOf(userA), legTotal, "out <= legTotal");
        _logPass();
    }

    function testFuzz_TwoHolderNoOverIssuance(uint256 holderA, uint256 legTotal, uint256 snapshot) public {
        _logCase("FUZZ-PRV-02", unicode"两人 claim 总和不超发");
        snapshot = bound(snapshot, 2, 1e30);
        holderA = bound(holderA, 1, snapshot - 1);
        uint256 holderB = snapshot - holderA;
        legTotal = bound(legTotal, 1, 1e30);

        _deployPrivatizationStack();
        (uint256 pid, ScaledToken old) = _prvProgram(snapshot, legTotal);

        uint256[] memory previewA = _prvRegistry.previewClaim(pid, holderA);
        uint256[] memory previewB = _prvRegistry.previewClaim(pid, holderB);
        if (previewA[0] == 0 || previewB[0] == 0) return;

        old.transfer(userA, holderA);
        old.transfer(userB, holderB);

        vm.startPrank(userA);
        old.approve(address(_prvRegistry), holderA);
        _prvRegistry.claim(pid, holderA);
        vm.stopPrank();

        vm.startPrank(userB);
        old.approve(address(_prvRegistry), holderB);
        _prvRegistry.claim(pid, holderB);
        vm.stopPrank();

        assertLe(
            _prvUsdc.balanceOf(userA) + _prvUsdc.balanceOf(userB),
            legTotal,
            "sum <= legTotal"
        );
        _logPass();
    }

    function testFuzz_SplitClaimEquivalence(uint256 total, uint256 split, uint256 legTotal) public {
        _logCase("FUZZ-PRV-03", unicode"分批 claim 等价性");
        total = bound(total, 2, 1e24);
        split = bound(split, 1, total - 1);
        legTotal = bound(legTotal, 1, 1e30);

        _deployPrivatizationStack();
        (uint256 pid, ScaledToken old) = _prvProgram(total, legTotal);

        uint256[] memory previewSplit = _prvRegistry.previewClaim(pid, split);
        uint256[] memory previewRest = _prvRegistry.previewClaim(pid, total - split);
        if (previewSplit[0] == 0 || previewRest[0] == 0) return;

        old.transfer(userA, total);

        uint256 snap = vm.snapshot();

        vm.startPrank(userA);
        old.approve(address(_prvRegistry), total);
        _prvRegistry.claim(pid, split);
        _prvRegistry.claim(pid, total - split);
        vm.stopPrank();
        uint256 splitOut = _prvUsdc.balanceOf(userA);

        vm.revertTo(snap);

        vm.startPrank(userA);
        old.approve(address(_prvRegistry), total);
        _prvRegistry.claim(pid, total);
        vm.stopPrank();
        uint256 fullOut = _prvUsdc.balanceOf(userA);

        assertLe(splitOut, fullOut, "split <= full (rounding)");
        _logPass();
    }

    function testFuzz_FullClaimZerosReserved(uint256 snapshot, uint256 legTotal) public {
        _logCase("FUZZ-PRV-04", unicode"全量 claim 后 reserved 归零");
        snapshot = bound(snapshot, 1, 1e30);
        legTotal = bound(legTotal, 1, 1e30);

        _deployPrivatizationStack();
        (uint256 pid, ScaledToken old) = _prvProgram(snapshot, legTotal);
        old.transfer(userA, snapshot);

        vm.startPrank(userA);
        old.approve(address(_prvRegistry), snapshot);
        _prvRegistry.claim(pid, snapshot);
        vm.stopPrank();

        assertEq(_prvRegistry.reserved(pid, address(_prvUsdc)), 0, "reserved == 0");
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      6. mulDiv 算术安全 Fuzz
    // ═══════════════════════════════════════════════

    function testFuzz_ExtremeParamsNoOverflow(uint256 amount, uint256 legTotal, uint256 snapshot) public {
        _logCase("FUZZ-PRV-05", unicode"极端参数不溢出");
        amount = bound(amount, 1, type(uint128).max);
        legTotal = bound(legTotal, 1, type(uint128).max);
        snapshot = bound(snapshot, amount, type(uint256).max);

        _deployPrivatizationStack();

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        address[] memory none = new address[](0);
        ScaledToken old = ScaledToken(
            factory.createToken("Extreme", "XOLD", "US8888888801", admin, issuers, none, none)
        );

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(_prvUsdc), legTotal);
        uint256 pid = _prvRegistry.createProgram(address(old), legs);

        PrivatizationRegistry.Program memory cfg = PrivatizationRegistry.Program({
            oldToken: address(0),
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 7 days),
            oldSupplySnapshot: snapshot,
            state: uint8(PrivatizationRegistry.State.Active)
        });
        _prvRegistry.configureProgram(pid, cfg);

        uint256[] memory outs = _prvRegistry.previewClaim(pid, amount);
        assertLe(outs[0], legTotal, "out <= legTotal with extreme params");
        _logPass();
    }

    function testFuzz_DustBinaryProperty(uint256 amount, uint256 legTotal, uint256 snapshot) public {
        _logCase("FUZZ-PRV-06", unicode"dust 边界二值性");
        snapshot = bound(snapshot, 1, 1e6);
        amount = bound(amount, 1, snapshot);
        legTotal = bound(legTotal, 1, 100);

        _deployPrivatizationStack();
        (uint256 pid, ScaledToken old) = _prvProgram(snapshot, legTotal);
        old.transfer(userA, amount);

        uint256[] memory preview = _prvRegistry.previewClaim(pid, amount);

        vm.startPrank(userA);
        old.approve(address(_prvRegistry), amount);
        if (preview[0] == 0) {
            vm.expectRevert(PrivatizationRegistry.NothingToDeliver.selector);
            _prvRegistry.claim(pid, amount);
        } else {
            _prvRegistry.claim(pid, amount);
            assertGt(_prvUsdc.balanceOf(userA), 0, "got output when preview > 0");
        }
        vm.stopPrank();
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      7. reserved 记账 Fuzz
    // ═══════════════════════════════════════════════

    function testFuzz_MultipleFundAccumulates(uint256 fundA, uint256 fundB) public {
        _logCase("FUZZ-PRV-07", unicode"多次 fund 累加精确");
        fundA = bound(fundA, 1, 1e24);
        fundB = bound(fundB, 1, 1e24);

        _deployPrivatizationStack();

        address[] memory issuers = new address[](1);
        issuers[0] = address(this);
        address[] memory none = new address[](0);
        ScaledToken old = ScaledToken(
            factory.createToken("Fund Old", "FNDO", "US7777", admin, issuers, none, none)
        );

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(_prvUsdc), fundA + fundB);
        uint256 pid = _prvRegistry.createProgram(address(old), legs);

        _prvUsdc.mint(address(this), fundA);
        _prvUsdc.approve(address(_prvRegistry), fundA);
        _prvRegistry.fund(pid, address(_prvUsdc), fundA);

        _prvUsdc.mint(address(this), fundB);
        _prvUsdc.approve(address(_prvRegistry), fundB);
        _prvRegistry.fund(pid, address(_prvUsdc), fundB);

        assertEq(_prvRegistry.reserved(pid, address(_prvUsdc)), fundA + fundB, "accumulated");
        _logPass();
    }

    function testFuzz_ClaimReducesReservedPrecisely(uint256 claimAmount, uint256 snapshot, uint256 legTotal) public {
        _logCase("FUZZ-PRV-08", unicode"claim 后 reserved 精确减少");
        snapshot = bound(snapshot, 1, 1e24);
        claimAmount = bound(claimAmount, 1, snapshot);
        legTotal = bound(legTotal, 1, 1e24);

        _deployPrivatizationStack();
        (uint256 pid, ScaledToken old) = _prvProgram(snapshot, legTotal);
        old.transfer(userA, claimAmount);

        uint256 reservedBefore = _prvRegistry.reserved(pid, address(_prvUsdc));
        uint256[] memory preview = _prvRegistry.previewClaim(pid, claimAmount);

        if (preview[0] == 0) return;

        vm.startPrank(userA);
        old.approve(address(_prvRegistry), claimAmount);
        _prvRegistry.claim(pid, claimAmount);
        vm.stopPrank();

        uint256 reservedAfter = _prvRegistry.reserved(pid, address(_prvUsdc));
        assertEq(reservedAfter, reservedBefore - preview[0], "reserved -= preview");
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      8. CustodyClaimRouter 转发守恒 Fuzz
    // ═══════════════════════════════════════════════

    function testFuzz_RouterNoResidualAfterClaimFor(uint256 amount, uint256 legTotal, uint256 snapshot) public {
        _logCase("FUZZ-RTR-01", unicode"claimFor 后 router 不残留");
        legTotal = bound(legTotal, 1, 1e24);
        snapshot = bound(snapshot, 1, 1e24);
        amount = bound(amount, 1, snapshot);

        _deployPrivatizationStack();
        (uint256 pid, ScaledToken old) = _prvProgram(snapshot, legTotal);

        uint256[] memory preview = _prvRegistry.previewClaim(pid, amount);
        if (preview[0] == 0) return;

        old.transfer(hotWallet1, amount);
        vm.prank(hotWallet1);
        old.transfer(address(_prvRouter), amount);

        _prvRouter.claimFor(pid, hotWallet1, amount);

        assertEq(_prvUsdc.balanceOf(address(_prvRouter)), 0, "router USDC == 0");
        _logPass();
    }

    function testFuzz_HotWalletReceivesPreviewAmount(uint256 amount, uint256 legTotal, uint256 snapshot) public {
        _logCase("FUZZ-RTR-02", unicode"hotWallet 收到 == previewClaim");
        legTotal = bound(legTotal, 1, 1e24);
        snapshot = bound(snapshot, 1, 1e24);
        amount = bound(amount, 1, snapshot);

        _deployPrivatizationStack();
        (uint256 pid, ScaledToken old) = _prvProgram(snapshot, legTotal);

        uint256[] memory preview = _prvRegistry.previewClaim(pid, amount);
        if (preview[0] == 0) return;

        uint256 usdcBefore = _prvUsdc.balanceOf(hotWallet1);

        old.transfer(hotWallet1, amount);
        vm.prank(hotWallet1);
        old.transfer(address(_prvRouter), amount);

        _prvRouter.claimFor(pid, hotWallet1, amount);

        assertEq(
            _prvUsdc.balanceOf(hotWallet1) - usdcBefore,
            preview[0],
            "received == preview"
        );
        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      9. 权限矩阵 Fuzz (privatization)
    // ═══════════════════════════════════════════════

    function testFuzz_UnauthorizedCreateProgram(address caller) public {
        _logCase("FUZZ-PERM-04", unicode"随机地址不能 createProgram");
        _deployPrivatizationStack();
        bytes32 opsRole = _prvRegistry.OPS_ROLE();
        vm.assume(!_prvRegistry.hasRole(opsRole, caller));
        vm.assume(caller != address(0));

        PrivatizationRegistry.Leg[] memory legs = new PrivatizationRegistry.Leg[](1);
        legs[0] = PrivatizationRegistry.Leg(address(_prvUsdc), 100e6);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, opsRole)
        );
        _prvRegistry.createProgram(address(token), legs);
        _logPass();
    }

    function testFuzz_UnauthorizedClaimFor(address caller) public {
        _logCase("FUZZ-PERM-05", unicode"随机地址不能 claimFor");
        _deployPrivatizationStack();
        bytes32 opsRole = _prvRouter.OPS_ROLE();
        vm.assume(!_prvRouter.hasRole(opsRole, caller));
        vm.assume(caller != address(0));

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, opsRole)
        );
        _prvRouter.claimFor(0, hotWallet1, 1e18);
        _logPass();
    }
}
