"""LP 穿透测试 — 公共模块"""
import os, sys, time, json, re, requests
from web3 import Web3
from web3.logs import DISCARD
from eth_account import Account
from eth_abi import encode as _abi_encode
from eth_utils import keccak as _keccak


# ── OZ StandardMerkleTree 独立实现 (MS-21~25) ──
# 探测已验证: 与服务端 tree.json 位对位一致 (见 /tmp/probe_merkle_algo.py)
def standard_leaf_hash(types: list, value) -> bytes:
    """OZ leaf hash = keccak256(keccak256(abi.encode(types, value)))."""
    return _keccak(_keccak(_abi_encode(types, list(value))))


def hash_pair_sorted(a: bytes, b: bytes) -> bytes:
    """OZ 节点 hash: keccak256 拼接前按字节排序."""
    return _keccak(a + b) if a < b else _keccak(b + a)


def build_standard_tree(leaf_hashes: list) -> list:
    """OZ makeMerkleTree: 输入原顺序叶子哈希, 返回大小 2N-1 的 tree 数组 (tree[0]=root).
    叶子先按字节升序排序, 反向填在数组末尾, 向上 hash pair."""
    sorted_hashes = sorted(leaf_hashes)
    n = len(sorted_hashes)
    if n == 0:
        return []
    tree_size = 2 * n - 1
    tree = [b"\x00" * 32] * tree_size
    for i, h in enumerate(sorted_hashes):
        tree[tree_size - 1 - i] = h
    for i in range(tree_size - 1 - n, -1, -1):
        tree[i] = hash_pair_sorted(tree[2 * i + 1], tree[2 * i + 2])
    return tree


def get_merkle_proof(tree: list, tree_index: int) -> list:
    """从 tree 数组中提取叶子位置 tree_index 的 proof (向上收集兄弟节点)."""
    proof = []
    i = tree_index
    while i > 0:
        sib = i - 1 if i % 2 == 0 else i + 1
        proof.append(tree[sib])
        i = (i - 1) // 2
    return proof


def verify_merkle_proof(root: bytes, leaf_hash: bytes, proof: list) -> bool:
    """OZ verify: 从 leaf 向上 hash pair, 结果应 == root."""
    h = leaf_hash
    for sib in proof:
        h = hash_pair_sorted(h, sib)
    return h == root


def typed_value_from_tree(value_arr: list, leaf_encoding: list):
    """tree.json 里 value 都是字符串, 按 leafEncoding 转成 python 类型 (uint→int, 其它保留 str).
    返回 tuple 供 abi.encode 使用."""
    return tuple(
        int(value_arr[i]) if t.startswith("uint") or t.startswith("int") else value_arr[i]
        for i, t in enumerate(leaf_encoding)
    )

# ── .env 加载 ──
def load_env(path=".env"):
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

# ── 常量 ──
NPM = Web3.to_checksum_address("0xB65EDa352dF237089Cfc9647A8Ed7C159Cc8fE1E")
SWAP_ROUTER = Web3.to_checksum_address("0x5de38072ff78Fd4E6B3c937b5859B911B3758dbc")
POOL = Web3.to_checksum_address("0xd70eE5f83288ADF183E06fa04dAbC859ba8aCFBD")
TICK_SPACING = 1

# ── 最小 ABI ──
ERC20_ABI = json.loads('[{"inputs":[{"name":"account","type":"address"}],"name":"balanceOf","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"name":"owner","type":"address"},{"name":"spender","type":"address"}],"name":"allowance","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[{"name":"spender","type":"address"},{"name":"amount","type":"uint256"}],"name":"approve","outputs":[{"name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},{"inputs":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],"name":"mint","outputs":[],"stateMutability":"nonpayable","type":"function"},{"inputs":[],"name":"totalSupply","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"uiMultiplier","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"}]')

POOL_ABI = json.loads('[{"inputs":[],"name":"slot0","outputs":[{"name":"sqrtPriceX96","type":"uint160"},{"name":"tick","type":"int24"},{"name":"observationIndex","type":"uint16"},{"name":"observationCardinality","type":"uint16"},{"name":"observationCardinalityNext","type":"uint16"},{"name":"feeProtocol","type":"uint8"},{"name":"unlocked","type":"bool"}],"stateMutability":"view","type":"function"},{"inputs":[],"name":"liquidity","outputs":[{"name":"","type":"uint128"}],"stateMutability":"view","type":"function"}]')

NPM_ABI = json.loads('''[
{"inputs":[{"components":[{"name":"token0","type":"address"},{"name":"token1","type":"address"},{"name":"tickSpacing","type":"int24"},{"name":"tickLower","type":"int24"},{"name":"tickUpper","type":"int24"},{"name":"amount0Desired","type":"uint256"},{"name":"amount1Desired","type":"uint256"},{"name":"amount0Min","type":"uint256"},{"name":"amount1Min","type":"uint256"},{"name":"recipient","type":"address"},{"name":"deadline","type":"uint256"},{"name":"followTokenId","type":"uint256"}],"name":"params","type":"tuple"}],"name":"mint","outputs":[{"name":"tokenId","type":"uint256"},{"name":"liquidity","type":"uint128"},{"name":"amount0","type":"uint256"},{"name":"amount1","type":"uint256"}],"stateMutability":"payable","type":"function"},
{"inputs":[{"components":[{"name":"tokenId","type":"uint256"},{"name":"liquidity","type":"uint128"},{"name":"amount0Min","type":"uint256"},{"name":"amount1Min","type":"uint256"},{"name":"deadline","type":"uint256"}],"name":"params","type":"tuple"}],"name":"decreaseLiquidity","outputs":[{"name":"amount0","type":"uint256"},{"name":"amount1","type":"uint256"}],"stateMutability":"payable","type":"function"},
{"inputs":[{"components":[{"name":"tokenId","type":"uint256"},{"name":"recipient","type":"address"},{"name":"amount0Max","type":"uint128"},{"name":"amount1Max","type":"uint128"}],"name":"params","type":"tuple"}],"name":"collect","outputs":[{"name":"amount0","type":"uint256"},{"name":"amount1","type":"uint256"}],"stateMutability":"payable","type":"function"},
{"inputs":[{"name":"tokenId","type":"uint256"}],"name":"positions","outputs":[{"name":"nonce","type":"uint96"},{"name":"operator","type":"address"},{"name":"token0","type":"address"},{"name":"token1","type":"address"},{"name":"tickSpacing","type":"int24"},{"name":"tickLower","type":"int24"},{"name":"tickUpper","type":"int24"},{"name":"liquidity","type":"uint128"},{"name":"feeGrowthInside0LastX128","type":"uint256"},{"name":"feeGrowthInside1LastX128","type":"uint256"},{"name":"tokensOwed0","type":"uint128"},{"name":"tokensOwed1","type":"uint128"}],"stateMutability":"view","type":"function"},
{"anonymous":false,"inputs":[{"indexed":true,"name":"tokenId","type":"uint256"},{"indexed":false,"name":"recipient","type":"address"},{"indexed":false,"name":"amount0","type":"uint256"},{"indexed":false,"name":"amount1","type":"uint256"}],"name":"Collect","type":"event"},
{"inputs":[{"name":"tokenId","type":"uint256"}],"name":"burn","outputs":[],"stateMutability":"payable","type":"function"},
{"inputs":[{"name":"tokenId","type":"uint256"}],"name":"ownerOf","outputs":[{"name":"","type":"address"}],"stateMutability":"view","type":"function"},
{"inputs":[{"name":"owner","type":"address"}],"name":"balanceOf","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
{"inputs":[{"name":"owner","type":"address"},{"name":"index","type":"uint256"}],"name":"tokenOfOwnerByIndex","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"}
]''')

SWAP_ABI = json.loads('[{"inputs":[{"components":[{"name":"tokenIn","type":"address"},{"name":"tokenOut","type":"address"},{"name":"tickSpacing","type":"int24"},{"name":"recipient","type":"address"},{"name":"amountIn","type":"uint256"},{"name":"amountOutMinimum","type":"uint256"},{"name":"sqrtPriceLimitX96","type":"uint160"},{"name":"extraFeeClass","type":"uint8"}],"name":"params","type":"tuple"}],"name":"exactInputSingle","outputs":[{"name":"amountOut","type":"uint256"}],"stateMutability":"payable","type":"function"}]')

TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
# NPM: event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1)
NPM_COLLECT_TOPIC = "0x40d0efd1a53d60ecbf40971b9daf7dc90178c3aadc7aab1765632738fa8b8f01"

ISSUER_VAULT_ABI = json.loads('[{"inputs":[{"name":"token","type":"address"},{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],"name":"mint","outputs":[],"stateMutability":"nonpayable","type":"function"}]')

ERC20_TRANSFER_ABI = json.loads('[{"inputs":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}],"name":"transfer","outputs":[{"name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"}]')

# WarrantRegistry: createProgram/configureProgram/fund/programs/programCount + ProgramCreated/ProgramConfigured events
WARRANT_REGISTRY_ABI = json.loads('''[
{"inputs":[{"name":"token","type":"address"},{"name":"settlementToken","type":"address"}],"name":"createProgram","outputs":[{"name":"programId","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
{"inputs":[{"name":"programId","type":"uint256"},{"components":[{"name":"token","type":"address"},{"name":"merkleRoot","type":"bytes32"},{"name":"settlementToken","type":"address"},{"name":"settleTotal","type":"uint256"},{"name":"startTime","type":"uint64"},{"name":"deadline","type":"uint64"},{"name":"state","type":"uint8"}],"name":"program","type":"tuple"}],"name":"configureProgram","outputs":[],"stateMutability":"nonpayable","type":"function"},
{"inputs":[{"name":"programId","type":"uint256"},{"name":"amount","type":"uint256"}],"name":"fund","outputs":[],"stateMutability":"nonpayable","type":"function"},
{"inputs":[{"name":"","type":"uint256"}],"name":"programs","outputs":[{"name":"token","type":"address"},{"name":"merkleRoot","type":"bytes32"},{"name":"settlementToken","type":"address"},{"name":"settleTotal","type":"uint256"},{"name":"startTime","type":"uint64"},{"name":"deadline","type":"uint64"},{"name":"state","type":"uint8"}],"stateMutability":"view","type":"function"},
{"inputs":[],"name":"programCount","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
{"inputs":[{"name":"","type":"uint256"}],"name":"settleReserve","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
{"inputs":[{"name":"programId","type":"uint256"},{"name":"index","type":"uint256"}],"name":"isClaimed","outputs":[{"name":"","type":"bool"}],"stateMutability":"view","type":"function"},
{"inputs":[{"name":"programId","type":"uint256"},{"name":"amount","type":"uint256"}],"name":"previewClaim","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
{"inputs":[{"name":"programId","type":"uint256"},{"name":"index","type":"uint256"},{"name":"account","type":"address"},{"name":"amount","type":"uint256"},{"name":"proof","type":"bytes32[]"}],"name":"claim","outputs":[],"stateMutability":"nonpayable","type":"function"},
{"inputs":[{"name":"programId","type":"uint256"},{"name":"custody","type":"address"}],"name":"sweepUnclaimed","outputs":[],"stateMutability":"nonpayable","type":"function"},
{"anonymous":false,"inputs":[{"indexed":true,"name":"programId","type":"uint256"},{"indexed":true,"name":"token","type":"address"},{"indexed":false,"name":"settlementToken","type":"address"}],"name":"ProgramCreated","type":"event"},
{"anonymous":false,"inputs":[{"indexed":true,"name":"programId","type":"uint256"},{"indexed":false,"name":"merkleRoot","type":"bytes32"},{"indexed":false,"name":"settlementToken","type":"address"},{"indexed":false,"name":"settleTotal","type":"uint256"},{"indexed":false,"name":"startTime","type":"uint64"},{"indexed":false,"name":"deadline","type":"uint64"},{"indexed":false,"name":"state","type":"uint8"}],"name":"ProgramConfigured","type":"event"},
{"anonymous":false,"inputs":[{"indexed":true,"name":"programId","type":"uint256"},{"indexed":false,"name":"index","type":"uint256"},{"indexed":true,"name":"account","type":"address"},{"indexed":false,"name":"amount","type":"uint256"},{"indexed":false,"name":"assetOut","type":"uint256"}],"name":"Claimed","type":"event"}
]''')


# ── Logger ──
class Logger:
    CYAN = "\033[0;36m"
    GREEN = "\033[0;32m"
    RED = "\033[0;31m"
    YELLOW = "\033[0;33m"
    NC = "\033[0m"

    def __init__(self, log_dir="logs/merkle"):
        os.makedirs(log_dir, exist_ok=True)
        self.log_dir = log_dir
        self.pass_count = 0
        self.fail_count = 0
        self._file = None

    def set_file(self, name):
        if self._file:
            self._file.close()
        self._file = open(os.path.join(self.log_dir, f"{name}.log"), "w")

    def _out(self, msg):
        print(msg)
        if self._file:
            # strip ANSI
            import re
            self._file.write(re.sub(r'\033\[[0-9;]*m', '', msg) + "\n")
            self._file.flush()

    def case(self, name):
        self.pass_count = 0
        self.fail_count = 0
        self._out(f"\n{self.CYAN}========================================{self.NC}")
        self._out(f"{self.CYAN}  {name}{self.NC}")
        self._out(f"{self.CYAN}========================================{self.NC}")

    def step(self, msg):
        self._out(f"  {self.YELLOW}[Step]{self.NC} {msg}")

    def request(self, msg):
        self._out(f"  {self.CYAN}>>> REQUEST:{self.NC} {msg}")

    def response(self, data):
        if isinstance(data, dict):
            self._out(f"  {self.CYAN}<<< RESPONSE:{self.NC}")
            self._out("  " + json.dumps(data, indent=2, default=str)[:2000])
        else:
            self._out(f"  {self.CYAN}<<< RESPONSE:{self.NC} {str(data)[:500]}")

    def pass_(self, msg):
        self.pass_count += 1
        self._out(f"  {self.GREEN}[PASS]{self.NC} {msg}")

    def fail(self, msg):
        self.fail_count += 1
        self._out(f"  {self.RED}[FAIL]{self.NC} {msg}")

    def summary(self) -> bool:
        self._out(f"\n{self.CYAN}========================================{self.NC}")
        self._out(f"  PASS: {self.GREEN}{self.pass_count}{self.NC}  FAIL: {self.RED}{self.fail_count}{self.NC}")
        self._out(f"{self.CYAN}========================================{self.NC}")
        if self._file:
            self._file.close()
            self._file = None
        return self.fail_count == 0


# ── ChainHelper ──
class ChainHelper:
    def __init__(self, rpc_url, token0, token1, log: Logger,
                 issuer_vault_addr=None, token_ops_pk=None,
                 hot_wallet_addr=None, hot_wallet_pk=None):
        """
        token0 = mUSD (SETTLE_TOKEN, MockERC20，直接 admin mint)
        token1 = mStock (ScaledToken，走 TokenIssuer + hot wallet 两步)
        """
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.token0 = Web3.to_checksum_address(token0)
        self.token1 = Web3.to_checksum_address(token1)
        self.log = log
        self.pool = self.w3.eth.contract(address=POOL, abi=POOL_ABI)
        self.npm = self.w3.eth.contract(address=NPM, abi=NPM_ABI)
        self.swap_router = self.w3.eth.contract(address=SWAP_ROUTER, abi=SWAP_ABI)
        self.issuer_vault_addr = Web3.to_checksum_address(issuer_vault_addr) if issuer_vault_addr else None
        self.token_ops_pk = token_ops_pk
        self.hot_wallet_addr = Web3.to_checksum_address(hot_wallet_addr) if hot_wallet_addr else None
        self.hot_wallet_pk = hot_wallet_pk
        if self.issuer_vault_addr:
            self.issuer_vault = self.w3.eth.contract(address=self.issuer_vault_addr, abi=ISSUER_VAULT_ABI)
        else:
            self.issuer_vault = None
        self.chain_id = self.w3.eth.chain_id
        self.last_tx_block = 0
        self._nonce_cache = {}  # addr -> next nonce; 公共 RPC 各节点 pending 状态不一致，本地维护

    def _addr(self, pk):
        return Account.from_key(pk).address

    def _send_tx(self, tx, pk, gas=200000):
        account = Account.from_key(pk)
        addr = account.address
        tx["from"] = addr
        tx["gas"] = gas
        tx["chainId"] = self.chain_id
        if "maxFeePerGas" not in tx:
            tx["gasPrice"] = self.w3.eth.gas_price

        # 本地 nonce 缓存 + 出错自恢复（公共 RPC 各节点 pending 视图不同）
        if addr not in self._nonce_cache:
            self._nonce_cache[addr] = self.w3.eth.get_transaction_count(addr, "pending")

        tx_hash = None
        last_err = None
        for _ in range(3):
            tx["nonce"] = self._nonce_cache[addr]
            signed = account.sign_transaction(tx)
            try:
                tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
                self._nonce_cache[addr] += 1
                break
            except Exception as e:
                last_err = str(e)
                m = re.search(r"next nonce (\d+)", last_err)
                if m:
                    self._nonce_cache[addr] = int(m.group(1))
                    continue
                if "nonce too low" in last_err or "already known" in last_err:
                    self._nonce_cache[addr] = self.w3.eth.get_transaction_count(addr, "pending")
                    continue
                raise
        if tx_hash is None:
            raise RuntimeError(f"send_raw_transaction 重试 3 次仍失败: {last_err}")

        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
        blk = int(receipt.get("blockNumber", 0) or 0)
        if blk > self.last_tx_block:
            self.last_tx_block = blk
        # 通用防御：等公共 RPC 池子追上到 receipt block，让下游读能看到新状态
        # 覆盖所有走 _send_tx 的场景（swap/mint/collect/decrease/transfer/approve...）
        if blk > 0:
            deadline = time.time() + 10
            while time.time() < deadline:
                if self.w3.eth.block_number >= blk:
                    break
                time.sleep(0.5)
        return receipt

    def get_current_tick(self) -> int:
        result = self.pool.functions.slot0().call()
        return result[1]

    def chain_balance(self, token_addr, owner, block_identifier=None) -> int:
        token = self.w3.eth.contract(address=Web3.to_checksum_address(token_addr), abi=ERC20_ABI)
        fn = token.functions.balanceOf(Web3.to_checksum_address(owner))
        if block_identifier is None:
            return fn.call()
        return fn.call(block_identifier=block_identifier)

    def get_block_number(self) -> int:
        return self.w3.eth.block_number

    def get_marked_block(self, margin: int = 2) -> int:
        """
        取 snapshot 用的 marked_block：max(RPC latest, 本地记录的最后一笔 tx block) + margin。
        margin 抵消公共 RPC 负载均衡节点间的同步滞后（避免 marked_block 落在 receipt block 之前）。
        """
        latest = self.w3.eth.block_number
        return max(latest, self.last_tx_block) + margin

    def approve(self, token_addr, spender, amount, pk):
        token_addr = Web3.to_checksum_address(token_addr)
        spender = Web3.to_checksum_address(spender)
        owner = self._addr(pk)
        token = self.w3.eth.contract(address=token_addr, abi=ERC20_ABI)
        allowance = token.functions.allowance(owner, spender).call()
        if allowance >= amount:
            return
        self.log.step(f"approve {token_addr[:10]}... -> {spender[:10]}...")
        tx = token.functions.approve(spender, 2 * 10**21).build_transaction({"from": owner, "gas": 100000})
        self._send_tx(tx, pk, gas=100000)

    def mint_position(self, tick_lower, tick_upper, amt0, amt1, pk) -> int:
        recipient = self._addr(pk)
        deadline = int(time.time()) + 600

        self.approve(self.token0, NPM, amt0, pk)
        self.approve(self.token1, NPM, amt1, pk)

        bal0 = self.chain_balance(self.token0, recipient)
        bal1 = self.chain_balance(self.token1, recipient)
        self.log.step(f"mint position: [{tick_lower}, {tick_upper}] amt0={amt0} amt1={amt1}")
        self.log.step(f"  balance: token0={bal0}, token1={bal1}")

        params = (
            self.token0, self.token1, TICK_SPACING,
            tick_lower, tick_upper,
            amt0, amt1, 0, 0,
            recipient, deadline, 0
        )

        fn = self.npm.functions.mint(params)
        try:
            fn.call({"from": recipient})
        except Exception as e:
            self.log.step(f"eth_call 首次失败 ({e})，等 2s 重试...")
            time.sleep(2)
            try:
                fn.call({"from": recipient})
            except Exception as e2:
                self.log.fail(f"mint eth_call 预检失败: {e2}")
                return 0

        tx = fn.build_transaction({"from": recipient, "gas": 800000})
        receipt = self._send_tx(tx, pk, gas=800000)

        if receipt["status"] != 1:
            self.log.fail(f"mint position failed (status=0, tx={receipt['transactionHash'].hex()})")
            return 0

        # parse tokenId from ERC721 Transfer event
        npm_lower = NPM.lower()
        for log_entry in receipt["logs"]:
            if (log_entry["address"].lower() == npm_lower
                    and len(log_entry["topics"]) >= 4
                    and log_entry["topics"][0].hex() == TRANSFER_TOPIC[2:]):
                token_id = int(log_entry["topics"][3].hex(), 16)
                self.log.step(f"minted tokenId={token_id} (tx={receipt['transactionHash'].hex()})")
                return token_id

        self.log.fail("could not parse tokenId from logs")
        return 0

    def get_pool_tick(self, pool_addr) -> int:
        """任意池 slot0().tick"""
        pool = self.w3.eth.contract(address=Web3.to_checksum_address(pool_addr), abi=POOL_ABI)
        return pool.functions.slot0().call()[1]

    def get_pool_liquidity(self, pool_addr) -> int:
        """任意池 liquidity() (uint128)"""
        pool = self.w3.eth.contract(address=Web3.to_checksum_address(pool_addr), abi=POOL_ABI)
        return pool.functions.liquidity().call()

    def mint_position_generic(self, token0, token1, tick_spacing,
                              tick_lower, tick_upper, amt0, amt1, pk) -> int:
        """
        通用 mint: 任意 token 对 + 任意 tick_spacing (自动 approve, 返回 tokenId).
        与 mint_position 不同: 后者写死 self.token0/self.token1/TICK_SPACING (老池).
        """
        token0 = Web3.to_checksum_address(token0)
        token1 = Web3.to_checksum_address(token1)
        recipient = self._addr(pk)
        deadline = int(time.time()) + 600

        self.approve(token0, NPM, amt0, pk)
        self.approve(token1, NPM, amt1, pk)

        bal0 = self.chain_balance(token0, recipient)
        bal1 = self.chain_balance(token1, recipient)
        self.log.step(f"mint_generic: token0={token0[:10]}... token1={token1[:10]}... spacing={tick_spacing}")
        self.log.step(f"  ticks=[{tick_lower}, {tick_upper}] amt0={amt0} amt1={amt1}")
        self.log.step(f"  balance: token0={bal0}, token1={bal1}")

        params = (
            token0, token1, tick_spacing,
            tick_lower, tick_upper,
            amt0, amt1, 0, 0,
            recipient, deadline, 0
        )
        fn = self.npm.functions.mint(params)
        try:
            fn.call({"from": recipient})
        except Exception as e:
            self.log.step(f"eth_call 首次失败 ({e})，等 2s 重试...")
            time.sleep(2)
            try:
                fn.call({"from": recipient})
            except Exception as e2:
                self.log.fail(f"mint_generic eth_call 预检失败: {e2}")
                return 0

        tx = fn.build_transaction({"from": recipient, "gas": 800000})
        receipt = self._send_tx(tx, pk, gas=800000)

        if receipt["status"] != 1:
            self.log.fail(f"mint_generic failed (status=0, tx={receipt['transactionHash'].hex()})")
            return 0

        npm_lower = NPM.lower()
        for log_entry in receipt["logs"]:
            if (log_entry["address"].lower() == npm_lower
                    and len(log_entry["topics"]) >= 4
                    and log_entry["topics"][0].hex() == TRANSFER_TOPIC[2:]):
                token_id = int(log_entry["topics"][3].hex(), 16)
                self.log.step(f"minted tokenId={token_id} (tx={receipt['transactionHash'].hex()})")
                return token_id

        self.log.fail("could not parse tokenId from logs")
        return 0

    def do_swap(self, zero_for_one: bool, amount_in: int, pk):
        owner = self._addr(pk)
        if zero_for_one:
            token_in, token_out = self.token0, self.token1
        else:
            token_in, token_out = self.token1, self.token0

        self.approve(token_in, SWAP_ROUTER, amount_in, pk)
        self.log.step(f"swap: {'mUSD->QATST' if zero_for_one else 'QATST->mUSD'} amountIn={amount_in}")

        params = (token_in, token_out, TICK_SPACING, owner, amount_in, 0, 0, 0)
        tx = self.swap_router.functions.exactInputSingle(params).build_transaction({"from": owner, "gas": 500000})
        receipt = self._send_tx(tx, pk, gas=500000)

        if receipt["status"] == 1:
            self.log.step("swap completed")
        else:
            self.log.fail("swap failed (status=0)")

    def get_position(self, token_id):
        """返回 (liquidity, tokensOwed0, tokensOwed1)"""
        r = self.npm.functions.positions(token_id).call()
        return r[7], r[10], r[11]

    def collect_fees(self, token_id, pk, amount0_max=(1 << 128) - 1, amount1_max=(1 << 128) - 1):
        """
        调用 NPM.collect，返回 (amount0, amount1) — 从 NPM.Collect event 解析实际收到量。
        失败返回 None。用 event 而不是 balance diff，避免公共 RPC 读到 stale 状态。
        """
        owner = self._addr(pk)
        params = (token_id, owner, amount0_max, amount1_max)
        fn = self.npm.functions.collect(params)
        try:
            fn.call({"from": owner})
        except Exception as e:
            self.log.step(f"collect eth_call 首次失败 ({e})，等 2s 重试...")
            time.sleep(2)
            try:
                fn.call({"from": owner})
            except Exception as e2:
                self.log.fail(f"collect eth_call 失败: {e2}")
                return None
        tx = fn.build_transaction({"from": owner, "gas": 300000})
        receipt = self._send_tx(tx, pk, gas=300000)
        if receipt["status"] != 1:
            self.log.fail(f"collect failed (tx={receipt['transactionHash'].hex()})")
            return None

        # 用 web3.py 的 event 解析，避免手撸 hex 字符串
        events = self.npm.events.Collect().process_receipt(receipt, errors=DISCARD)
        for ev in events:
            if int(ev["args"]["tokenId"]) == int(token_id):
                a0 = int(ev["args"]["amount0"])
                a1 = int(ev["args"]["amount1"])
                self.log.step(f"collect ok (tx={receipt['transactionHash'].hex()}) amount0={a0} amount1={a1}")
                return (a0, a1)

        self.log.fail(f"collect tx 成功但未解析到 NPM.Collect event for tokenId={token_id} (tx={receipt['transactionHash'].hex()})")
        return None

    def decrease_liquidity(self, token_id, liquidity, pk):
        """调用 NPM.decreaseLiquidity，返回 receipt；失败返回 None"""
        owner = self._addr(pk)
        deadline = int(time.time()) + 600
        params = (token_id, int(liquidity), 0, 0, deadline)
        fn = self.npm.functions.decreaseLiquidity(params)
        try:
            fn.call({"from": owner})
        except Exception as e:
            self.log.step(f"decreaseLiquidity eth_call 首次失败 ({e})，等 2s 重试...")
            time.sleep(2)
            try:
                fn.call({"from": owner})
            except Exception as e2:
                self.log.fail(f"decreaseLiquidity eth_call 失败: {e2}")
                return None
        tx = fn.build_transaction({"from": owner, "gas": 400000})
        receipt = self._send_tx(tx, pk, gas=400000)
        if receipt["status"] != 1:
            self.log.fail(f"decreaseLiquidity failed (tx={receipt['transactionHash'].hex()})")
            return None
        self.log.step(f"decreaseLiquidity ok (tx={receipt['transactionHash'].hex()})")
        return receipt

    def burn_position(self, token_id, pk) -> bool:
        """
        调用 NPM.burn(tokenId) 销毁空 position NFT。
        要求 position 完全为空 (liquidity==0 且 tokensOwed0==0 且 tokensOwed1==0)。
        """
        owner = self._addr(pk)
        fn = self.npm.functions.burn(int(token_id))
        try:
            fn.call({"from": owner})
        except Exception as e:
            self.log.step(f"burn eth_call 首次失败 ({e})，等 2s 重试...")
            time.sleep(2)
            try:
                fn.call({"from": owner})
            except Exception as e2:
                self.log.fail(f"burn eth_call 失败 (position 未完全清空?): {e2}")
                return False
        tx = fn.build_transaction({"from": owner, "gas": 200000})
        receipt = self._send_tx(tx, pk, gas=200000)
        if receipt["status"] != 1:
            self.log.fail(f"burn failed (tx={receipt['transactionHash'].hex()})")
            return False
        self.log.step(f"burn ok (tx={receipt['transactionHash'].hex()})")
        return True

    def position_exists(self, token_id) -> bool:
        """burn 后 ownerOf 会 revert；用作存在性检查"""
        try:
            self.npm.functions.ownerOf(int(token_id)).call()
            return True
        except Exception:
            return False

    def mint_token(self, token_addr, to, amount, admin_pk) -> bool:
        """直接调用 token.mint(to, amount) — 仅适用于 mUSD (MockERC20)"""
        token_addr = Web3.to_checksum_address(token_addr)
        to = Web3.to_checksum_address(to)
        admin_addr = self._addr(admin_pk)
        token = self.w3.eth.contract(address=token_addr, abi=ERC20_ABI)

        bal_before = token.functions.balanceOf(to).call()

        fn = token.functions.mint(to, amount)
        try:
            fn.call({"from": admin_addr})
        except Exception as e:
            self.log.fail(f"mint_token eth_call 预检失败 (admin 可能无 MINTER 权限): {e}")
            return False

        tx = fn.build_transaction({"from": admin_addr, "gas": 200000})
        receipt = self._send_tx(tx, admin_pk, gas=200000)
        if receipt["status"] != 1:
            self.log.fail(f"mint_token tx revert (tx={receipt['transactionHash'].hex()})")
            return False

        # 公共 RPC 负载均衡节点可能读到未同步状态，轮询等 balance 到位；tx status==1 已证明链上生效
        target = bal_before + amount
        for i in range(15):
            if token.functions.balanceOf(to).call() >= target:
                if i > 0:
                    self.log.step(f"  RPC synced after {i+1}s")
                return True
            time.sleep(1)
        self.log.step(f"  warn: RPC 15s 内未同步到目标余额 {target}（tx 已成功，下游可能需重试）")
        return True

    def mint_mstock(self, to, amount) -> bool:
        """
        ScaledToken (mStock) 只能通过 TokenIssuer 铸造到热钱包，然后 transfer 给用户。
        步骤: 1) vault.mint(token1, hot_wallet, amount) via TOKEN_OPS_PK
             2) token1.transfer(to, amount) via HOT_WALLET_PK
        """
        if not (self.issuer_vault and self.token_ops_pk and self.hot_wallet_addr and self.hot_wallet_pk):
            self.log.fail("mint_mstock 缺少配置 (issuer_vault/token_ops_pk/hot_wallet)")
            return False

        to = Web3.to_checksum_address(to)
        token = self.w3.eth.contract(address=self.token1, abi=ERC20_ABI)
        transfer_token = self.w3.eth.contract(address=self.token1, abi=ERC20_TRANSFER_ABI)
        bal_entry = token.functions.balanceOf(to).call()

        # step 1: vault.mint -> hot wallet
        ops_addr = self._addr(self.token_ops_pk)
        fn = self.issuer_vault.functions.mint(self.token1, self.hot_wallet_addr, amount)
        try:
            fn.call({"from": ops_addr})
        except Exception as e:
            self.log.fail(f"vault.mint eth_call 失败 (ops 无 WALLET_OPS_ROLE?): {e}")
            return False
        tx = fn.build_transaction({"from": ops_addr, "gas": 250000})
        receipt = self._send_tx(tx, self.token_ops_pk, gas=250000)
        if receipt["status"] != 1:
            self.log.fail(f"vault.mint tx revert (tx={receipt['transactionHash'].hex()})")
            return False

        self.log.step(f"  vault.mint ok (tx={receipt['transactionHash'].hex()})")

        # step 2: hot wallet transfer -> user
        # 不做本地 balanceOf 前后对比：公共 RPC 负载均衡可能读到未同步节点，
        # 拿 tx status==1 判定即可，链上事实已生效；若 hot wallet 真没到位，此步会自己 revert
        fn2 = transfer_token.functions.transfer(to, amount)
        try:
            fn2.call({"from": self.hot_wallet_addr})
        except Exception as e:
            self.log.fail(f"hot wallet transfer eth_call 失败: {e}")
            return False
        tx2 = fn2.build_transaction({"from": self.hot_wallet_addr, "gas": 150000})
        receipt2 = self._send_tx(tx2, self.hot_wallet_pk, gas=150000)
        if receipt2["status"] != 1:
            self.log.fail(f"hot wallet transfer tx revert (tx={receipt2['transactionHash'].hex()})")
            return False
        self.log.step(f"  hot -> user transfer ok (tx={receipt2['transactionHash'].hex()})")

        # 等公共 RPC 端能看到新余额 —— 下游 mint_position 的 eth_call/allowance 需要读到新状态
        target = bal_entry + amount
        for i in range(15):
            if token.functions.balanceOf(to).call() >= target:
                if i > 0:
                    self.log.step(f"  RPC synced after {i+1}s")
                return True
            time.sleep(1)
        self.log.step(f"  warn: RPC 15s 内未同步到目标余额 {target}，继续（下游可能需重试）")
        return True

    def ensure_balance(self, user_pk, admin_pk, min_musd=200_000_000, min_qatst=200 * 10**18):
        """min_musd: mUSD 最低 (6 decimals), min_qatst: mStock 最低 (18 decimals)"""
        addr = self._addr(user_pk)
        musd_bal = self.chain_balance(self.token0, addr)
        if musd_bal < min_musd:
            self.log.step(f"mint 500 mUSD for {addr[:10]}...")
            self.mint_token(self.token0, addr, 500_000_000, admin_pk)
        qatst_bal = self.chain_balance(self.token1, addr)
        if qatst_bal < min_qatst:
            self.log.step(f"mint 500 mStock for {addr[:10]}... (via vault + hot wallet)")
            self.mint_mstock(addr, 500 * 10**18)

    def wait_confirmations(self, marked_block, confirms=150):
        target = marked_block + confirms
        self.log.step(f"等待块高到达 {target} (标记块 {marked_block} + {confirms} 确认)...")
        while True:
            try:
                current = self.get_block_number()
            except Exception as e:
                self.log.step(f"  get_block_number 出错 ({str(e)[:120]}), 10s 后重试...")
                time.sleep(10)
                continue
            remaining = target - current
            if remaining <= 0:
                self.log.step(f"确认完成，当前块: {current}")
                return marked_block
            wait_secs = min(remaining * 2 + 5, 120)
            self.log.step(f"  还需 {remaining} 块 (当前 {current})，等待 {wait_secs}s...")
            time.sleep(wait_secs)

    # ── WarrantRegistry helpers (MS-27~28b) ───────────────────────────────
    def _warrant(self, registry_addr):
        return self.w3.eth.contract(
            address=Web3.to_checksum_address(registry_addr),
            abi=WARRANT_REGISTRY_ABI,
        )

    def warrant_create_program(self, registry_addr, token, settlement_token, pk) -> int:
        reg = self._warrant(registry_addr)
        owner = self._addr(pk)
        self.log.step(f"createProgram(token={token[:10]}..., settle={settlement_token[:10]}...)")
        tx = reg.functions.createProgram(
            Web3.to_checksum_address(token),
            Web3.to_checksum_address(settlement_token),
        ).build_transaction({"from": owner, "gas": 300000})
        receipt = self._send_tx(tx, pk, gas=300000)
        if receipt["status"] != 1:
            self.log.fail(f"createProgram failed (tx={receipt['transactionHash'].hex()})")
            return -1
        # ProgramCreated event → programId
        events = reg.events.ProgramCreated().process_receipt(receipt, errors=DISCARD)
        for ev in events:
            pid = int(ev["args"]["programId"])
            self.log.step(f"createProgram ok programId={pid} (tx={receipt['transactionHash'].hex()})")
            return pid
        self.log.fail("no ProgramCreated event")
        return -1

    def warrant_configure_program(self, registry_addr, program_id, patch: dict, pk):
        """patch: dict with keys token/merkleRoot/settlementToken/settleTotal/startTime/deadline/state.
        Missing keys default to 0 (keep). merkleRoot 传 bytes32 或 hex str."""
        reg = self._warrant(registry_addr)
        owner = self._addr(pk)
        root = patch.get("merkleRoot", b"\x00" * 32)
        if isinstance(root, str):
            root = bytes.fromhex(root[2:] if root.startswith("0x") else root)
            if len(root) != 32:
                raise ValueError(f"merkleRoot len={len(root)}")
        prog_tuple = (
            Web3.to_checksum_address(patch.get("token") or "0x0000000000000000000000000000000000000000"),
            root,
            Web3.to_checksum_address(patch.get("settlementToken") or "0x0000000000000000000000000000000000000000"),
            int(patch.get("settleTotal", 0)),
            int(patch.get("startTime", 0)),
            int(patch.get("deadline", 0)),
            int(patch.get("state", 0)),
        )
        self.log.step(f"configureProgram(id={program_id}, root=0x{root.hex()[:16]}..., state={prog_tuple[6]})")
        tx = reg.functions.configureProgram(int(program_id), prog_tuple).build_transaction(
            {"from": owner, "gas": 400000}
        )
        receipt = self._send_tx(tx, pk, gas=400000)
        if receipt["status"] != 1:
            self.log.fail(f"configureProgram failed (tx={receipt['transactionHash'].hex()})")
            return None
        self.log.step(f"configureProgram ok (tx={receipt['transactionHash'].hex()})")
        return receipt

    def warrant_fund(self, registry_addr, program_id, amount, pk):
        reg = self._warrant(registry_addr)
        owner = self._addr(pk)
        self.log.step(f"fund(id={program_id}, amount={amount})")
        tx = reg.functions.fund(int(program_id), int(amount)).build_transaction(
            {"from": owner, "gas": 300000}
        )
        receipt = self._send_tx(tx, pk, gas=300000)
        if receipt["status"] != 1:
            self.log.fail(f"fund failed (tx={receipt['transactionHash'].hex()})")
            return None
        self.log.step(f"fund ok (tx={receipt['transactionHash'].hex()})")
        return receipt

    def warrant_get_program(self, registry_addr, program_id) -> dict:
        reg = self._warrant(registry_addr)
        r = reg.functions.programs(int(program_id)).call()
        return {
            "token": r[0],
            "merkleRoot": "0x" + r[1].hex(),
            "settlementToken": r[2],
            "settleTotal": int(r[3]),
            "startTime": int(r[4]),
            "deadline": int(r[5]),
            "state": int(r[6]),
        }

    def warrant_settle_reserve(self, registry_addr, program_id) -> int:
        reg = self._warrant(registry_addr)
        return int(reg.functions.settleReserve(int(program_id)).call())

    def warrant_is_claimed(self, registry_addr, program_id, index) -> bool:
        reg = self._warrant(registry_addr)
        return bool(reg.functions.isClaimed(int(program_id), int(index)).call())

    def warrant_preview_claim(self, registry_addr, program_id, amount) -> int:
        reg = self._warrant(registry_addr)
        return int(reg.functions.previewClaim(int(program_id), int(amount)).call())

    def warrant_claim(self, registry_addr, program_id, index, account, amount, proof, pk,
                      expect_revert: bool = False):
        """调用 WarrantRegistry.claim(programId, index, account, amount, proof).
        返回 (receipt, Claimed_event_dict) 或 (None, None) 失败.
        proof: list[bytes32 hex str 或 bytes].
        expect_revert=True: 预期 revert (幂等/权限等负测), 不 log.fail; 返回 (None, revert_reason_str)."""
        reg = self._warrant(registry_addr)
        caller = self._addr(pk)
        # 规范 proof: hex str → bytes
        proof_bytes = []
        for p in proof:
            if isinstance(p, str):
                proof_bytes.append(bytes.fromhex(p[2:] if p.startswith("0x") else p))
            else:
                proof_bytes.append(p)
        account_cs = Web3.to_checksum_address(account)
        fn = reg.functions.claim(int(program_id), int(index), account_cs, int(amount), proof_bytes)
        try:
            fn.call({"from": caller})
        except Exception as e:
            if expect_revert:
                # 负测: eth_call revert 即证实契约拒绝, 不用重试
                return None, str(e)
            self.log.step(f"claim eth_call 首次失败 ({e})，等 2s 重试...")
            time.sleep(2)
            try:
                fn.call({"from": caller})
            except Exception as e2:
                self.log.fail(f"claim eth_call 预检失败: {e2}")
                return None, None
        self.log.step(f"claim(id={program_id}, idx={index}, acct={account_cs[:10]}..., amt={amount}) 提交...")
        tx = fn.build_transaction({"from": caller, "gas": 400000})
        receipt = self._send_tx(tx, pk, gas=400000)
        if receipt["status"] != 1:
            self.log.fail(f"claim tx revert (tx={receipt['transactionHash'].hex()})")
            return None, None
        events = reg.events.Claimed().process_receipt(receipt, errors=DISCARD)
        for ev in events:
            args = ev["args"]
            evt = {
                "programId": int(args["programId"]),
                "index": int(args["index"]),
                "account": args["account"],
                "amount": int(args["amount"]),
                "assetOut": int(args["assetOut"]),
                "tx": receipt["transactionHash"].hex(),
            }
            self.log.step(f"claim ok (tx={evt['tx']}) assetOut={evt['assetOut']}")
            return receipt, evt
        self.log.fail("claim tx 成功但未解析到 Claimed event")
        return receipt, None

    def warrant_sweep_unclaimed(self, registry_addr, program_id, custody, pk,
                                 expect_revert: bool = False):
        """调用 WarrantRegistry.sweepUnclaimed(programId, custody).
        返回 receipt (成功) 或 None (失败).
        expect_revert=True: 预期 revert (deadline 未到等), 返回 (None, revert_reason)."""
        reg = self._warrant(registry_addr)
        owner = self._addr(pk)
        custody_cs = Web3.to_checksum_address(custody)
        fn = reg.functions.sweepUnclaimed(int(program_id), custody_cs)
        try:
            fn.call({"from": owner})
        except Exception as e:
            if expect_revert:
                return None, str(e)
            self.log.fail(f"sweepUnclaimed eth_call 失败: {e}")
            return None
        self.log.step(f"sweepUnclaimed(id={program_id}, custody={custody_cs[:10]}...) 提交...")
        tx = fn.build_transaction({"from": owner, "gas": 300000})
        receipt = self._send_tx(tx, pk, gas=300000)
        if receipt["status"] != 1:
            self.log.fail(f"sweepUnclaimed tx revert (tx={receipt['transactionHash'].hex()})")
            return None
        self.log.step(f"sweepUnclaimed ok (tx={receipt['transactionHash'].hex()})")
        return receipt

    @staticmethod
    def align_tick(tick, spacing=TICK_SPACING):
        if tick >= 0:
            return (tick // spacing) * spacing
        return ((tick - spacing + 1) // spacing) * spacing


# ── MerkleClient ──
class MerkleClient:
    def __init__(self, host, api_key, token, chain_helper: ChainHelper, log: Logger):
        self.host = host.rstrip("/")
        self.api_key = api_key
        self.token = token
        self.chain = chain_helper
        self.log = log
        self.headers = {"X-API-Key": api_key, "Content-Type": "application/json"}

    def _http(self, method, url, retries=5, backoff=2.0, **kwargs):
        """裸 requests.{method} 会遇 SSL EOF / ConnectionError, 加重试. 网络错重试, 4xx/5xx 不重试."""
        kwargs.setdefault("timeout", 30)
        last_err = None
        for i in range(retries):
            try:
                return requests.request(method, url, headers=self.headers, **kwargs)
            except (requests.exceptions.SSLError,
                    requests.exceptions.ConnectionError,
                    requests.exceptions.Timeout) as e:
                last_err = e
                wait = backoff * (i + 1)
                self.log.step(f"[net retry {i+1}/{retries}] {type(e).__name__}: 等 {wait:.1f}s 后重试")
                time.sleep(wait)
        raise last_err

    def _http_raw(self, method, url, headers=None, retries=5, backoff=2.0, **kwargs):
        """同 _http 但不自动带 self.headers (X-API-Key). MS-32~34 鉴权测试用.
        headers=None 表示完全不带任何 header; 传 dict 则用调用方指定的."""
        kwargs.setdefault("timeout", 30)
        hdrs = headers or {}
        last_err = None
        for i in range(retries):
            try:
                return requests.request(method, url, headers=hdrs, **kwargs)
            except (requests.exceptions.SSLError,
                    requests.exceptions.ConnectionError,
                    requests.exceptions.Timeout) as e:
                last_err = e
                wait = backoff * (i + 1)
                self.log.step(f"[net retry {i+1}/{retries}] {type(e).__name__}: 等 {wait:.1f}s 后重试")
                time.sleep(wait)
        raise last_err

    def safe_record_block(self) -> int:
        return self.chain.get_block_number() - 200

    def create_snapshot(self, record_block, rules: dict = None,
                        kind: str = None, total: str = None, ratio: str = None,
                        body_override: dict = None) -> str:
        """
        默认 WARRANT + total=1e18. 可覆盖:
          - kind: "PROGRAM_KIND_WARRANT" | "PROGRAM_KIND_LEVERAGE"
          - total: 字符串, WARRANT 用
          - ratio: 字符串 (如 "0.25"), LEVERAGE 用
          - body_override: 最后合并到 body, 可覆盖任意字段或删字段 (值=None 时 pop)
        """
        body = {
            "token": self.token,
            "record_block": str(record_block),
            "kind": kind or "PROGRAM_KIND_WARRANT",
            "chain_id": "5000",
        }
        if (kind or "PROGRAM_KIND_WARRANT") == "PROGRAM_KIND_WARRANT":
            body["total"] = total or "1000000000000000000"
        elif kind == "PROGRAM_KIND_LEVERAGE":
            if ratio is not None:
                body["ratio"] = ratio
        if rules:
            # rules 支持 exclude_addresses (list[str]) 和 residual_account (str)
            body["rules"] = rules
        if body_override:
            for k, v in body_override.items():
                if v is None:
                    body.pop(k, None)
                else:
                    body[k] = v
        url = f"{self.host}/v1/programs/snapshot"
        self.log.request(f"POST {url}")
        self.log.step(f"  Body: {json.dumps(body)}")
        resp = self._http("POST", url, json=body)
        data = resp.json()
        sid = data.get("snapshotId")
        if not sid:
            self.log.fail(f"create snapshot failed: {data}")
            return ""
        self.log.step(f"snapshotId: {sid}")
        return sid

    def wait_snapshot(self, sid, timeout=180) -> dict:
        url = f"{self.host}/v1/snapshots/{sid}"
        for _ in range(timeout // 3):
            resp = self._http("GET", url)
            data = resp.json()
            status = data.get("status", "")
            if status in ("SNAPSHOT_STATUS_READY", "SNAPSHOT_STATUS_FAILED"):
                self.log.response(data)
                return data
            time.sleep(3)
        self.log.fail("snapshot timeout")
        return {"error": "timeout"}

    def snapshot(self, record_block, rules: dict = None) -> dict:
        sid = self.create_snapshot(record_block, rules=rules)
        if not sid:
            return {}
        return self.wait_snapshot(sid)

    def get_allocation(self, sid, address):
        """
        返回 int(holding); 若地址不在树中(被排除或不存在), 返回 None (对应 404)
        """
        address = address.lower()
        url = f"{self.host}/v1/snapshots/{sid}/allocation?account={address}"
        self.log.request(f"GET {url}")
        try:
            resp = self._http("GET", url)
            if resp.status_code == 404:
                self.log.response({"status_code": 404, "body": resp.text[:200]})
                return None
            data = resp.json()
            self.log.response(data)
            holding = data.get("holding") or data.get("amount") or "0"
            return int(holding)
        except Exception as e:
            self.log.fail(f"get_allocation error: {e}")
            return 0

    def get_allocation_full(self, sid, address):
        """
        返回完整 allocation dict (含 index/amount/proof/holding/root); 404 → None.
        MS-13 (LEVERAGE ratio 校验) 需要 amount 和 holding 一起.
        """
        address = address.lower()
        url = f"{self.host}/v1/snapshots/{sid}/allocation?account={address}"
        self.log.request(f"GET {url}")
        try:
            resp = self._http("GET", url)
            if resp.status_code == 404:
                self.log.response({"status_code": 404, "body": resp.text[:200]})
                return None
            data = resp.json()
            self.log.response(data)
            return data
        except Exception as e:
            self.log.fail(f"get_allocation_full error: {e}")
            return None

    def list_pools(self, chain_id: int, token: str = None, include_disabled: bool = False) -> list:
        """
        GET /v1/pools; 用于拿到 pool 的 created_block/position_manager 用于二次注册(upsert)
        """
        params = {"chain_id": str(chain_id)}
        if token:
            params["token"] = token
        if include_disabled:
            params["include_disabled"] = "true"
        url = f"{self.host}/v1/pools"
        self.log.request(f"GET {url} params={params}")
        resp = self._http("GET", url, params=params)
        data = resp.json()
        self.log.response(data)
        return data.get("pools", [])

    def register_pool(self, address: str, chain_id: int, position_manager: str,
                      created_block: int, residual_max_bps: int = 0,
                      kind: str = "", note: str = "") -> dict:
        """
        POST /v1/pools; upsert 语义 — 已注册池子的 residual_max_bps 会被覆盖.
        residual_max_bps=10000 表示豁免 (100% 残差也不 FAILED); =0 表示用全局默认.
        enabled 状态不受此 API 影响 (由 EnablePool/DisablePool 单独控制).
        """
        body = {
            "address": address,
            "chain_id": str(chain_id),
            "position_manager": position_manager,
            "created_block": str(created_block),
            "residual_max_bps": residual_max_bps,
        }
        if kind:
            body["kind"] = kind
        if note:
            body["note"] = note
        url = f"{self.host}/v1/pools"
        self.log.request(f"POST {url}")
        self.log.step(f"  Body: {json.dumps(body)}")
        resp = self._http("POST", url, json=body)
        data = resp.json() if resp.text else {}
        self.log.response(data)
        if resp.status_code >= 400:
            self.log.fail(f"register_pool http {resp.status_code}: {data}")
        return data

    def disable_pool(self, address: str, chain_id: int) -> dict:
        """POST /v1/pools/{address}/disable — disabled 池不进 poolCount, 其地址被当普通持有人."""
        body = {"chain_id": str(chain_id)}
        url = f"{self.host}/v1/pools/{address}/disable"
        self.log.request(f"POST {url}")
        self.log.step(f"  Body: {json.dumps(body)}")
        resp = self._http("POST", url, json=body)
        data = resp.json() if resp.text else {}
        self.log.response(data)
        if resp.status_code >= 400:
            self.log.fail(f"disable_pool http {resp.status_code}: {data}")
        return data

    def enable_pool(self, address: str, chain_id: int) -> dict:
        """POST /v1/pools/{address}/enable — 恢复池到扫描列表."""
        body = {"chain_id": str(chain_id)}
        url = f"{self.host}/v1/pools/{address}/enable"
        self.log.request(f"POST {url}")
        self.log.step(f"  Body: {json.dumps(body)}")
        resp = self._http("POST", url, json=body)
        data = resp.json() if resp.text else {}
        self.log.response(data)
        if resp.status_code >= 400:
            self.log.fail(f"enable_pool http {resp.status_code}: {data}")
        return data

    def fetch_tree(self, tree_uri: str) -> dict:
        """GET treeUri (公开 S3 URL, 无需 auth). 格式 standard-v1, 含 values/leafEncoding/tree."""
        self.log.request(f"GET {tree_uri}")
        # S3 URL — 不带 API headers, 但同样加重试防 SSL EOF
        last_err = None
        resp = None
        for i in range(5):
            try:
                resp = requests.get(tree_uri, timeout=30)
                break
            except (requests.exceptions.SSLError,
                    requests.exceptions.ConnectionError,
                    requests.exceptions.Timeout) as e:
                last_err = e
                self.log.step(f"[net retry {i+1}/5] {type(e).__name__}: 等 {2*(i+1):.1f}s")
                time.sleep(2 * (i + 1))
        if resp is None:
            raise last_err
        if resp.status_code != 200:
            self.log.fail(f"fetch_tree http {resp.status_code}")
            return {}
        data = resp.json()
        self.log.response({"format": data.get("format"), "leafEncoding": data.get("leafEncoding"),
                           "values_count": len(data.get("values", [])),
                           "tree_nodes": len(data.get("tree", []))})
        return data

    def verify_snapshot(self, sid: str) -> dict:
        """GET /v1/snapshots/{id}/verify → {ok, recomputedRoot, storedRoot, leafCount, proofsVerified, errors}."""
        url = f"{self.host}/v1/snapshots/{sid}/verify"
        self.log.request(f"GET {url}")
        resp = self._http("GET", url, timeout=60)
        data = resp.json() if resp.text else {}
        self.log.response(data)
        return data

    def bind_program(self, snapshot_id: str, program_id, registry: str, chain_id: int = 5000):
        """POST /v1/programs — 绑定 snapshot 到 program (upsert). 返回 (status_code, body)."""
        body = {
            "snapshot_id": snapshot_id,
            "program_id": str(program_id),
            "registry": registry,
            "chain_id": str(chain_id),
        }
        url = f"{self.host}/v1/programs"
        self.log.request(f"POST {url}")
        self.log.step(f"  Body: {json.dumps(body)}")
        resp = self._http("POST", url, json=body)
        data = resp.json() if resp.text else {}
        self.log.response({"status_code": resp.status_code, "body": data})
        return resp.status_code, data

    def get_program(self, program_id, registry: str, chain_id: int = 5000):
        """GET /v1/programs/{program_id}?registry=&chain_id= → (status_code, body)."""
        url = f"{self.host}/v1/programs/{program_id}"
        params = {"registry": registry, "chain_id": str(chain_id)}
        self.log.request(f"GET {url} params={params}")
        resp = self._http("GET", url, params=params)
        data = resp.json() if resp.text else {}
        self.log.response({"status_code": resp.status_code, "body": data})
        return resp.status_code, data

    def get_tree(self, sid: str) -> dict:
        """GET /v1/snapshots/{sid}/tree — 服务端直接返完整树 (root/format/leafEncoding/values/treeUri/tree).
        与 fetch_tree(treeUri) 走 S3 不同, 这个走服务端, MS-35/36 明确要求测这个端点."""
        url = f"{self.host}/v1/snapshots/{sid}/tree"
        self.log.request(f"GET {url}")
        resp = self._http("GET", url)
        if resp.status_code != 200:
            self.log.fail(f"get_tree http {resp.status_code}: {resp.text[:200]}")
            return {}
        data = resp.json()
        self.log.response({"format": data.get("format"), "leafEncoding": data.get("leafEncoding"),
                           "values_count": len(data.get("values", [])),
                           "tree_nodes": len(data.get("tree", [])),
                           "root": data.get("root")})
        return data

    def get_program_allocation(self, program_id, account: str, registry: str, chain_id: int = 5000):
        """GET /v1/programs/{program_id}/allocation?account=&registry=&chain_id= → (status_code, body).
        body 含: snapshotId/programId/registry/index/account/amount/root/proof/holding/kind (200);
        或 {code,reason,message} (404 non-holder / unknown program)."""
        url = f"{self.host}/v1/programs/{program_id}/allocation"
        params = {"account": account, "registry": registry, "chain_id": str(chain_id)}
        self.log.request(f"GET {url} params={params}")
        resp = self._http("GET", url, params=params)
        data = resp.json() if resp.text else {}
        self.log.response({"status_code": resp.status_code, "body": data})
        return resp.status_code, data
