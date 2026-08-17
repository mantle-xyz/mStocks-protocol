// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ScaledTokenFactory} from "../src/scaledToken/ScaledTokenFactory.sol";

/// @notice Generates Gnosis Safe Transaction Builder JSON batches for POST-HANDOVER operations —
///         once the factory / token DEFAULT_ADMIN_ROLE is held by a multisig, an EOA-signed
///         `forge script --broadcast` can no longer call createToken / grantRole directly.
///
/// Read-only: NO `--broadcast`, no signer. Each entrypoint only encodes calldata and writes a JSON
/// file under ./safe-txs/ that operators import into the Safe Transaction Builder, then sign+execute.
/// Run with `--rpc-url $RPC` so `chainId` in the output matches the target chain.
///
/// Entrypoints:
///   createTokens(address factory)
///     Reads the `[[tokens]]` array from config.toml and emits one `factory.createToken(...)` tx per
///     entry. createToken is OPS_ROLE-gated, so import ./safe-txs/createTokens.json into the Safe
///     that holds the factory OPS_ROLE.
///
///   grantIssuer(address issuer, address[] tokens)
///     Emits one `token.grantRole(ISSUER_ROLE, issuer)` tx per token — run AFTER createTokens has
///     executed and the token addresses are known (they come from CREATE, not CREATE2). Import
///     ./safe-txs/grantIssuer.json into the Safe that holds each token's admin.
contract BuildSafeTxs is Script {
    using stdToml for string;

    /// @dev Matches ScaledToken.ISSUER_ROLE.
    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    /// @notice Builds a Safe batch of `createToken` calls (one per `[[tokens]]` entry) to `factory`.
    function createTokens(address factory) external {
        require(factory != address(0), "BuildSafeTxs: factory is zero");
        string memory toml = _config();

        string memory txs = "";
        uint256 count = 0;
        for (uint256 i = 0;; ++i) {
            string memory base = string.concat(".tokens[", vm.toString(i), "]");
            if (!vm.keyExistsToml(toml, string.concat(base, ".symbol"))) break;

            string memory name = toml.readString(string.concat(base, ".name"));
            string memory symbol = toml.readString(string.concat(base, ".symbol"));
            string memory identifier = toml.readString(string.concat(base, ".identifier"));
            address admin = toml.readAddress(string.concat(base, ".admin"));
            require(admin != address(0), string.concat("BuildSafeTxs: tokens[", vm.toString(i), "].admin is zero"));
            address[] memory issuers = _readAddrArr(toml, string.concat(base, ".issuers"));
            address[] memory schedulers = _readAddrArr(toml, string.concat(base, ".multiplierSchedulers"));

            bytes memory data = abi.encodeWithSelector(
                ScaledTokenFactory.createToken.selector, name, symbol, identifier, admin, issuers, schedulers
            );
            txs = string.concat(txs, count == 0 ? "" : ",", _tx(factory, data));
            console.log(string.concat("  createToken ", symbol, " -> admin ", vm.toString(admin)));
            count++;
        }
        require(count > 0, "BuildSafeTxs: no [[tokens]] entries in config");

        _write("./safe-txs/createTokens.json", _batch("createTokens", txs));
        console.log("Wrote ./safe-txs/createTokens.json  (txs:", count, ")");
    }

    /// @notice Builds a Safe batch granting each `tokens[i]` its ISSUER_ROLE to `issuer`.
    function grantIssuer(address issuer, address[] calldata tokens) external {
        require(issuer != address(0), "BuildSafeTxs: issuer is zero");
        require(tokens.length > 0, "BuildSafeTxs: no tokens");

        bytes memory data = abi.encodeWithSignature("grantRole(bytes32,address)", ISSUER_ROLE, issuer);
        string memory txs = "";
        for (uint256 i = 0; i < tokens.length; ++i) {
            require(tokens[i] != address(0), "BuildSafeTxs: token is zero");
            txs = string.concat(txs, i == 0 ? "" : ",", _tx(tokens[i], data));
            console.log(string.concat("  grantRole(ISSUER_ROLE) on ", vm.toString(tokens[i])));
        }

        _write("./safe-txs/grantIssuer.json", _batch("grantIssuer", txs));
        console.log("Wrote ./safe-txs/grantIssuer.json  (txs:", tokens.length, ")");
    }

    // --- helpers -------------------------------------------------------------

    function _config() internal view returns (string memory) {
        string memory path = vm.envOr("DEPLOY_CONFIG_PATH", string("./config.toml"));
        return vm.readFile(path);
    }

    function _readAddrArr(string memory toml, string memory key) internal view returns (address[] memory) {
        return vm.keyExistsToml(toml, key) ? toml.readAddressArray(key) : new address[](0);
    }

    /// @dev A single Safe Transaction Builder tx object (custom-data form).
    function _tx(address to, bytes memory data) internal view returns (string memory) {
        return string.concat('{"to":"', vm.toString(to), '","value":"0","data":"', vm.toString(data), '"}');
    }

    /// @dev Wraps the tx list in a Safe Transaction Builder v1.0 batch envelope.
    function _batch(string memory name, string memory txs) internal view returns (string memory) {
        return string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"',
            name,
            '"},"transactions":[',
            txs,
            "]}"
        );
    }

    function _write(string memory path, string memory content) internal {
        vm.writeFile(path, content);
    }
}
