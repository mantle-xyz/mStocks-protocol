// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {BaseQAScript} from "./BaseQAScript.s.sol";
import {WarrantRegistry} from "../../src/privatization/WarrantRegistry.sol";
import {MockUSD} from "../../test/mocks/MockUSD.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ScaledToken} from "../../src/scaledToken/ScaledToken.sol";

contract QAWarrantRegistry is BaseQAScript {
    WarrantRegistry internal reg;
    MockUSD internal usd;
    uint256 internal warrantOpsPk;
    address internal warrantOps;
    string internal merkleHost;
    string internal apiKey;

    bytes32 internal WR_OPS_ROLE;

    uint256 internal wr13Pid;

    bool internal _wrEnvLoaded;

    function _initWarrantEnv() internal {
        _loadEnv();
        if (_wrEnvLoaded) return;
        _wrEnvLoaded = true;
        reg = WarrantRegistry(vm.envAddress("WARRANT_REGISTRY_ADDR"));
        usd = MockUSD(vm.envAddress("SETTLE_TOKEN_ADDR"));
        warrantOpsPk = vm.envUint("WARRANT_OPS_PK");
        warrantOps = vm.addr(warrantOpsPk);
        merkleHost = vm.envString("MERKLE_HOST");
        apiKey = vm.envString("API_KEY");
        WR_OPS_ROLE = reg.OPS_ROLE();
    }

    // ═══════════════════════════════════════════════
    //      Merkle Service Helpers (vm.ffi)
    // ═══════════════════════════════════════════════

    function _recordBlock() internal view returns (uint256) {
        return block.number - 150;
    }

    function _snapshotWarrant(uint256 recordBlock, uint256 programId) internal returns (bytes32 root) {
        string memory body = string.concat(
            '{"token":"', vm.toString(address(token)),
            '","recordBlock":"', vm.toString(recordBlock),
            '","kind":1,"total":"1000000000000000000"',
            ',"programId":"', vm.toString(programId),
            '","registry":"', vm.toString(address(reg)),
            '","chainId":"5000"}'
        );
        string memory pollBase = string.concat(merkleHost, "/v1/snapshots/");
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "set -e; ",
            "SID=$(curl -sf -X POST '", merkleHost, "/v1/programs/snapshot' ",
            "-H 'Content-Type: application/json' -H 'X-API-Key: ", apiKey, "' ",
            "-d '", body, "' | jq -r '.snapshotId'); ",
            "for i in $(seq 1 60); do ",
            "S=$(curl -sf '", pollBase, "'\"$SID\" -H 'X-API-Key: ", apiKey, "' | jq -r '.status'); ",
            "[ \"$S\" = \"SNAPSHOT_STATUS_READY\" ] || [ \"$S\" = \"3\" ] || [ \"$S\" = \"SNAPSHOT_STATUS_FAILED\" ] || [ \"$S\" = \"4\" ] && break; sleep 2; done; ",
            "( [ \"$S\" != \"SNAPSHOT_STATUS_READY\" ] && [ \"$S\" != \"3\" ] ) && { echo 'snapshot failed: '$S >&2; exit 1; }; ",
            "curl -sf '", pollBase, "'\"$SID\" -H 'X-API-Key: ", apiKey, "' | jq -r '.root'"
        );
        bytes memory result = vm.ffi(cmd);
        require(result.length == 32, string.concat("bad root length: ", vm.toString(result.length)));
        root = bytes32(result);
    }

    function _snapshotLeverage(uint256 recordBlock, string memory ratio, uint256 programId)
        internal
        returns (bytes32 root)
    {
        string memory body = string.concat(
            '{"token":"', vm.toString(address(token)),
            '","recordBlock":"', vm.toString(recordBlock),
            '","kind":2,"ratio":"', ratio,
            '","programId":"', vm.toString(programId),
            '","registry":"', vm.toString(address(reg)),
            '","chainId":"5000"}'
        );
        string memory pollBase = string.concat(merkleHost, "/v1/snapshots/");
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "set -e; ",
            "SID=$(curl -sf -X POST '", merkleHost, "/v1/programs/snapshot' ",
            "-H 'Content-Type: application/json' -H 'X-API-Key: ", apiKey, "' ",
            "-d '", body, "' | jq -r '.snapshotId'); ",
            "for i in $(seq 1 60); do ",
            "S=$(curl -sf '", pollBase, "'\"$SID\" -H 'X-API-Key: ", apiKey, "' | jq -r '.status'); ",
            "[ \"$S\" = \"SNAPSHOT_STATUS_READY\" ] || [ \"$S\" = \"3\" ] || [ \"$S\" = \"SNAPSHOT_STATUS_FAILED\" ] || [ \"$S\" = \"4\" ] && break; sleep 2; done; ",
            "( [ \"$S\" != \"SNAPSHOT_STATUS_READY\" ] && [ \"$S\" != \"3\" ] ) && { echo 'snapshot failed: '$S >&2; exit 1; }; ",
            "curl -sf '", pollBase, "'\"$SID\" -H 'X-API-Key: ", apiKey, "' | jq -r '.root'"
        );
        bytes memory result = vm.ffi(cmd);
        require(result.length == 32, string.concat("bad root length: ", vm.toString(result.length)));
        root = bytes32(result);
    }

    function _getAllocation(uint256 programId, address account)
        internal
        returns (uint256 index, uint256 amount, bytes32[] memory proof)
    {
        string memory url = string.concat(
            merkleHost, "/v1/programs/", vm.toString(programId),
            "/allocation?account=", vm.toString(account),
            "&registry=", vm.toString(address(reg)),
            "&chainId=5000"
        );
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = string.concat(
            "set -e; ",
            "JSON=$(curl -sf '", url, "'); ",
            "INDEX=$(echo \"$JSON\" | jq -r '.index'); ",
            "AMOUNT=$(echo \"$JSON\" | jq -r '.amount'); ",
            "PROOFS=$(echo \"$JSON\" | jq -r '.proof | join(\",\")'); ",
            "cast abi-encode 'f(uint256,uint256,bytes32[])' \"$INDEX\" \"$AMOUNT\" \"[$PROOFS]\""
        );
        bytes memory result = vm.ffi(cmd);
        (index, amount, proof) = abi.decode(result, (uint256, uint256, bytes32[]));
    }

    // ═══════════════════════════════════════════════
    //      Local Merkle helpers (WR-15)
    // ═══════════════════════════════════════════════

    function _leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    // ═══════════════════════════════════════════════
    //      Program Lifecycle Helpers
    // ═══════════════════════════════════════════════

    function _createWarrantProgram() internal returns (uint256 pid) {
        vm.broadcast(warrantOpsPk);
        pid = reg.createProgram(address(token), address(usd));
    }

    function _createLeverageProgram() internal returns (uint256 pid) {
        vm.broadcast(warrantOpsPk);
        pid = reg.createProgram(address(token), address(0));
    }

    function _activateWarrantProgram(uint256 pid, uint256 settleTotal, uint64 deadline)
        internal
        returns (bytes32 root)
    {
        uint256 rb = _recordBlock();
        root = _snapshotWarrant(rb, pid);

        WarrantRegistry.Program memory cfg;
        cfg.merkleRoot = root;
        cfg.settleTotal = settleTotal;
        cfg.startTime = uint64(block.timestamp);
        cfg.deadline = deadline;
        vm.broadcast(warrantOpsPk);
        reg.configureProgram(pid, cfg);

        vm.startBroadcast(warrantOpsPk);
        usd.mint(warrantOps, settleTotal);
        usd.approve(address(reg), settleTotal);
        reg.fund(pid, settleTotal);
        vm.stopBroadcast();

        WarrantRegistry.Program memory activate;
        activate.state = 2;
        vm.broadcast(warrantOpsPk);
        reg.configureProgram(pid, activate);
    }

    // ═══════════════════════════════════════════════
    //      run()
    // ═══════════════════════════════════════════════

    function run() external {
        _initWarrantEnv();

        test_WR01();
        test_WR02();
        test_WR03();
        test_WR04();
        test_WR05();
        test_WR06();
        test_WR07();
        test_WR08();
        test_WR09();
        test_WR10();
        test_WR11();
        test_WR12a_setup();
        // WR-12b needs manual wait >=70s, run separately:
        //   forge script ... --sig "test_WR12b_verify(uint256)" <pid>
        test_WR13();
        test_WR14();
        test_WR15();
    }

    // ═══════════════════════════════════════════════
    //      §2.1 Deployment Verification (read-only)
    // ═══════════════════════════════════════════════

    function test_WR01() public {
        _initWarrantEnv();
        _logCase("QA-WR-01", unicode"合约可调用 + 角色正确");

        uint256 count = reg.programCount();
        _step(string.concat("  programCount = ", vm.toString(count)));

        _assertEq(reg.hasRole(reg.DEFAULT_ADMIN_ROLE(), admin), true, "admin has DEFAULT_ADMIN_ROLE");
        _assertEq(reg.hasRole(reg.DEFAULT_ADMIN_ROLE(), warrantOps), false, "ops has no DEFAULT_ADMIN_ROLE");
        _assertEq(reg.RATE_SCALE(), 1e18, "RATE_SCALE == 1e18");

        _logPass();
    }

    function test_WR02() public {
        _initWarrantEnv();
        _logCase("QA-WR-02", unicode"OPS 与 admin 职责分离");

        require(admin != warrantOps, "admin == ops");
        _step(string.concat("  admin: ", vm.toString(admin)));
        _step(string.concat("  ops:   ", vm.toString(warrantOps)));

        _assertEq(reg.hasRole(WR_OPS_ROLE, warrantOps), true, "ops has OPS_ROLE");
        _assertEq(reg.hasRole(WR_OPS_ROLE, admin), false, "admin has no OPS_ROLE");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      §2.2 Lifecycle Tests
    // ═══════════════════════════════════════════════

    function test_WR03() public {
        _initWarrantEnv();
        _logCase("QA-WR-03", unicode"创建 program");

        uint256 countBefore = reg.programCount();
        uint256 pid = _createWarrantProgram();
        _step(string.concat("  programId = ", vm.toString(pid)));

        (address storedToken,, address settleTok,,,, uint8 state) = reg.programs(pid);
        _assertEq(storedToken, address(token), "token");
        _assertEq(settleTok, address(usd), "settlementToken");
        _assertEq(uint256(state), 1, "state == Created");
        _assertEq(reg.programCount(), countBefore + 1, "programCount +1");

        _logPass();
    }

    function test_WR04() public {
        _initWarrantEnv();
        _logCase("QA-WR-04", unicode"configure → fund → Active 完整流程");

        uint256 pid = _createWarrantProgram();
        uint256 settleTotal = 500e6;
        uint64 deadline = uint64(block.timestamp + 7 days);

        bytes32 root = _activateWarrantProgram(pid, settleTotal, deadline);
        _step(string.concat("  root: ", vm.toString(root)));

        (, bytes32 storedRoot,, uint256 storedTotal,,, uint8 state) = reg.programs(pid);
        _assertEq(uint256(state), 2, "state == Active");
        require(storedRoot == root, "merkleRoot mismatch");
        _assertEq(storedTotal, settleTotal, "settleTotal");
        _assertEq(reg.settleReserve(pid), settleTotal, "settleReserve");

        _logPass();
    }

    function test_WR05() public {
        _initWarrantEnv();
        _logCase("QA-WR-05", unicode"完整 claim 主流程");

        uint256 pid = _createWarrantProgram();
        _activateWarrantProgram(pid, 500e6, uint64(block.timestamp + 7 days));

        (uint256 idx, uint256 amt, bytes32[] memory proof) = _getAllocation(pid, userA);
        _step(string.concat("  alice index=", vm.toString(idx), " amount=", vm.toString(amt)));

        uint256 preview = reg.previewClaim(pid, amt);
        _step(string.concat("  previewClaim = ", vm.toString(preview)));

        uint256 balBefore = usd.balanceOf(userA);
        vm.broadcast(userAPk);
        reg.claim(pid, idx, userA, amt, proof);

        uint256 balAfter = usd.balanceOf(userA);
        _assertEq(balAfter - balBefore, preview, "alice received == preview");
        _assertEq(reg.isClaimed(pid, idx), true, "isClaimed");
        _assertEq(reg.warrant(pid, userA), amt, "warrant[alice]");
        _assertEq(reg.claimStarted(pid), true, "claimStarted");

        _logPass();
    }

    function test_WR06() public {
        _initWarrantEnv();
        _logCase("QA-WR-06", unicode"第三方代 claim（relayer 替 alice）");

        uint256 pid = _createWarrantProgram();
        _activateWarrantProgram(pid, 500e6, uint64(block.timestamp + 7 days));

        (uint256 idx, uint256 amt, bytes32[] memory proof) = _getAllocation(pid, userA);

        uint256 aliceBefore = usd.balanceOf(userA);
        uint256 relayerBefore = usd.balanceOf(hotWallet);

        vm.broadcast(hotWalletPk);
        reg.claim(pid, idx, userA, amt, proof);

        _assertEq(usd.balanceOf(userA) - aliceBefore, reg.previewClaim(pid, amt), "alice received");
        _assertEq(usd.balanceOf(hotWallet), relayerBefore, "relayer balance unchanged");
        _assertEq(reg.warrant(pid, userA), amt, "warrant[alice]");
        _assertEq(reg.warrant(pid, hotWallet), 0, "warrant[relayer] == 0");

        _logPass();
    }

    function test_WR07() public {
        _initWarrantEnv();
        _logCase("QA-WR-07", unicode"stranger 不能 createProgram");

        address stranger = vm.addr(99999);
        _expectRevertFrom(
            stranger,
            address(reg),
            abi.encodeWithSelector(reg.createProgram.selector, address(token), address(usd)),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  stranger createProgram reverted as expected");

        _logPass();
    }

    function test_WR08() public {
        _initWarrantEnv();
        _logCase("QA-WR-08", unicode"admin 不能 createProgram");

        _expectRevertFrom(
            admin,
            address(reg),
            abi.encodeWithSelector(reg.createProgram.selector, address(token), address(usd)),
            IAccessControl.AccessControlUnauthorizedAccount.selector
        );
        _step("  admin createProgram reverted as expected");

        _logPass();
    }

    function test_WR09() public {
        _initWarrantEnv();
        _logCase("QA-WR-09", unicode"Created + funded → settleTotal 被锁");

        uint256 pid = _createWarrantProgram();

        WarrantRegistry.Program memory cfg;
        cfg.settleTotal = 500e6;
        cfg.startTime = uint64(block.timestamp);
        cfg.deadline = uint64(block.timestamp + 7 days);
        vm.broadcast(warrantOpsPk);
        reg.configureProgram(pid, cfg);

        vm.startBroadcast(warrantOpsPk);
        usd.mint(warrantOps, 500e6);
        usd.approve(address(reg), 500e6);
        reg.fund(pid, 500e6);
        vm.stopBroadcast();

        WarrantRegistry.Program memory patch;
        patch.settleTotal = 600e6;
        _expectRevertFrom(
            warrantOps,
            address(reg),
            abi.encodeWithSelector(reg.configureProgram.selector, pid, patch),
            WarrantRegistry.SettlementTermsLocked.selector
        );
        _step("  change settleTotal after fund -> SettlementTermsLocked");

        _logPass();
    }

    function test_WR10() public {
        _initWarrantEnv();
        _logCase("QA-WR-10", unicode"Active 后 configure 全锁");

        uint256 pid = _createWarrantProgram();
        _activateWarrantProgram(pid, 500e6, uint64(block.timestamp + 7 days));

        WarrantRegistry.Program memory patch;
        patch.merkleRoot = bytes32(uint256(1));
        _expectRevertFrom(
            warrantOps,
            address(reg),
            abi.encodeWithSelector(reg.configureProgram.selector, pid, patch),
            WarrantRegistry.ConfigureLockedOnceActive.selector
        );
        _step("  configure after Active -> ConfigureLockedOnceActive");

        _logPass();
    }

    function test_WR11() public {
        _initWarrantEnv();
        _logCase("QA-WR-11", unicode"admin 自授权保护");

        _expectRevertFrom(
            admin,
            address(reg),
            abi.encodeWithSelector(reg.grantRole.selector, WR_OPS_ROLE, admin),
            WarrantRegistry.SelfGrantNotAllowed.selector
        );
        _step("  admin self-grant OPS_ROLE -> SelfGrantNotAllowed");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      §2.3 Time-Dependent (split: setup/verify)
    // ═══════════════════════════════════════════════

    function test_WR12a_setup() public {
        _initWarrantEnv();
        _logCase("QA-WR-12a", unicode"deadline 到期 — setup");

        uint256 pid = _createWarrantProgram();
        uint64 deadline = uint64(block.timestamp + 60);
        _activateWarrantProgram(pid, 500e6, deadline);

        _step(string.concat("  programId = ", vm.toString(pid)));
        _step(string.concat("  deadline  = ", vm.toString(uint256(deadline))));
        _step("  >>> Wait 70+ seconds, then run: test_WR12b_verify()");

        _assertEq(reg.settleReserve(pid), 500e6, "reserve funded");
        _logPass();
    }

    function test_WR12b_verify() public {
        _initWarrantEnv();
        _logCase("QA-WR-12b", unicode"deadline 到期 — verify");

        uint256 cnt = reg.programCount();
        require(cnt > 0, "no programs exist, run WR12a first");
        uint256 pid = cnt - 1;
        (,,,,, uint64 deadline, uint8 state) = reg.programs(pid);
        require(state == 2, "program not Active - run WR12a first");
        require(block.timestamp > deadline, "deadline not passed yet - wait longer");
        _step(string.concat("  now=", vm.toString(block.timestamp), " deadline=", vm.toString(uint256(deadline))));

        // alice claim should fail with ClaimClosed
        bytes32[] memory dummyProof = new bytes32[](1);
        _expectRevertFrom(
            userA,
            address(reg),
            abi.encodeWithSelector(reg.claim.selector, pid, uint256(0), userA, uint256(1e17), dummyProof),
            WarrantRegistry.ClaimClosed.selector
        );
        _step("  alice claim -> ClaimClosed");

        // OPS sweep
        uint256 reserveBefore = reg.settleReserve(pid);
        uint256 custodyBefore = usd.balanceOf(admin);

        vm.broadcast(warrantOpsPk);
        reg.sweepUnclaimed(pid, admin);

        _assertEq(reg.settleReserve(pid), 0, "reserve swept to 0");

        (,,,,,, uint8 newState) = reg.programs(pid);
        _assertEq(uint256(newState), 3, "state == Closed");

        uint256 custodyAfter = usd.balanceOf(admin);
        _assertEq(custodyAfter - custodyBefore, reserveBefore, "custody received reserve");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      §2.4 Leverage (配资)
    // ═══════════════════════════════════════════════

    function test_WR13() public {
        _initWarrantEnv();
        _logCase("QA-WR-13", unicode"配资 program 完整流程");

        uint256 pid = _createLeverageProgram();
        wr13Pid = pid;
        _step(string.concat("  programId = ", vm.toString(pid)));

        uint256 rb = _recordBlock();
        bytes32 root = _snapshotLeverage(rb, "0.25", pid);
        _step(string.concat("  root: ", vm.toString(root)));

        WarrantRegistry.Program memory cfg;
        cfg.merkleRoot = root;
        cfg.startTime = uint64(block.timestamp);
        cfg.deadline = uint64(block.timestamp + 7 days);
        cfg.state = 2; // Active (settleTotal=0 exempt from NotFullyFunded)
        vm.broadcast(warrantOpsPk);
        reg.configureProgram(pid, cfg);

        (address storedToken, bytes32 storedRoot, address settleTok, uint256 total,,, uint8 state) =
            reg.programs(pid);
        _assertEq(storedToken, address(token), "token");
        _assertEq(settleTok, address(0), "settlementToken == 0");
        _assertEq(total, 0, "settleTotal == 0");
        _assertEq(reg.settleReserve(pid), 0, "settleReserve == 0");
        _assertEq(uint256(state), 2, "state == Active");
        require(storedRoot == root, "merkleRoot mismatch");

        _logPass();
    }

    function test_WR14() public {
        _initWarrantEnv();
        _logCase("QA-WR-14", unicode"配资 program 不可 claim");

        uint256 pid = wr13Pid;
        if (pid == 0) {
            _step("  no leverage program found, creating one...");
            test_WR13();
            pid = wr13Pid;
        }

        (uint256 idx, uint256 amt, bytes32[] memory proof) = _getAllocation(pid, userA);
        _step(string.concat("  alice index=", vm.toString(idx), " amount=", vm.toString(amt)));

        _expectRevertFrom(
            userA,
            address(reg),
            abi.encodeWithSelector(reg.claim.selector, pid, idx, userA, amt, proof),
            WarrantRegistry.NotConvertibleYet.selector
        );
        _step("  alice claim leverage -> NotConvertibleYet");

        _assertEq(reg.isClaimed(pid, idx), false, "index not consumed");

        _logPass();
    }

    // ═══════════════════════════════════════════════
    //      §2.5 Multi-Token Isolation
    // ═══════════════════════════════════════════════

    function test_WR15() public {
        _initWarrantEnv();
        _logCase("QA-WR-15", unicode"不同 mStock 的 program 资金隔离");

        // ── Program A: use existing QATST + Merkle service ──
        uint256 pidA = _createWarrantProgram();
        _activateWarrantProgram(pidA, 500e6, uint64(block.timestamp + 7 days));
        _step(string.concat("  programA = ", vm.toString(pidA), " (QATST, 500 mUSD)"));

        // ── Program B: deploy new token + local Merkle tree ──
        address[] memory emptyArr = new address[](0);
        address[] memory opsArr = new address[](1);
        opsArr[0] = walletOps;

        vm.broadcast(factoryOpsPk);
        ScaledToken tokenB = ScaledToken(
            factory.createToken(
                "Test Token B", _uniqueSymbol("TKNB"), _uniqueSymbol("TMP"), admin, emptyArr, emptyArr, opsArr
            )
        );

        vm.broadcast(warrantOpsPk);
        uint256 pidB = reg.createProgram(address(tokenB), address(usd));

        bytes32 leafB0 = _leaf(0, userA, 0.6e18);
        bytes32 leafB1 = _leaf(1, userB, 0.4e18);
        bytes32 rootB = _hashPair(leafB0, leafB1);

        WarrantRegistry.Program memory cfgB;
        cfgB.merkleRoot = rootB;
        cfgB.settleTotal = 300e6;
        cfgB.startTime = uint64(block.timestamp);
        cfgB.deadline = uint64(block.timestamp + 7 days);
        vm.broadcast(warrantOpsPk);
        reg.configureProgram(pidB, cfgB);

        vm.startBroadcast(warrantOpsPk);
        usd.mint(warrantOps, 300e6);
        usd.approve(address(reg), 300e6);
        reg.fund(pidB, 300e6);
        vm.stopBroadcast();

        WarrantRegistry.Program memory activateB;
        activateB.state = 2;
        vm.broadcast(warrantOpsPk);
        reg.configureProgram(pidB, activateB);

        _step(string.concat("  programB = ", vm.toString(pidB), " (tokenB, 300 mUSD)"));

        // ── alice claims from programA ──
        (uint256 idx, uint256 amt, bytes32[] memory proof) = _getAllocation(pidA, userA);
        vm.broadcast(userAPk);
        reg.claim(pidA, idx, userA, amt, proof);
        _step("  alice claimed from programA");

        // ── verify programB unaffected ──
        _assertEq(reg.settleReserve(pidB), 300e6, "programB reserve unchanged");
        _assertEq(reg.isClaimed(pidB, 0), false, "programB isClaimed(alice) == false");

        (,,,,,, uint8 stateB) = reg.programs(pidB);
        _assertEq(uint256(stateB), 2, "programB still Active");

        _logPass();
    }
}
