// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Hands DEFAULT_ADMIN_ROLE over from the deploy signer (broadcaster — e.g. a Ledger)
///         to the FINAL admin configured as `admin` in config.toml, across every contract
///         deployed by Deploy.s.sol.
///
/// Deploy.s.sol bootstraps every contract with the broadcaster as the temporary
/// DEFAULT_ADMIN_ROLE holder. Once deployment is complete AND all operational wiring is done
/// (token creation, OPS_ROLE grants, issuer ISSUER_ROLE, etc.), run this to move admin to the
/// multisig. Per target it GRANTS the role to the new admin first, then REVOKES it from the
/// broadcaster — the admin count never drops to zero. Idempotent and safe to re-run.
///
/// Scope: DEFAULT_ADMIN_ROLE only. `proxyAdmin` / beacon ownership is Ownable and was already
/// set to its final value at deploy — it needs no handover here.
///
/// ORDER MATTERS: run this LAST. Revoking the broadcaster's admin on the factory removes its
/// ability to createToken; revoking on a token removes its ability to grant that token's roles.
///
/// Deployed addresses are passed as CLI args (Deploy.s.sol does not persist them). Pass
/// address(0) for any contract that was not deployed.
///
/// Usage (Ledger):
///   forge script script/TransferAdmin.s.sol:TransferAdmin \
///     --sig "run(address,address,address,address,address[])" \
///     <compliance> <pauseManager> <factory> <tokenIssuer> "[<token1>,<token2>]" \
///     --rpc-url $RPC --ledger --sender <ledgerAddr> --broadcast -vvv
///
///   # single target:
///   forge script script/TransferAdmin.s.sol:TransferAdmin --sig "transferOne(address)" \
///     <target> --rpc-url $RPC --ledger --sender <ledgerAddr> --broadcast
contract TransferAdmin is Script {
    using stdToml for string;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    /// @param compliance   ComplianceRegistry  (address(0) to skip)
    /// @param pauseManager PauseRegistry        (address(0) to skip)
    /// @param factory      ScaledTokenFactory   (address(0) to skip)
    /// @param tokenIssuer  TokenIssuer proxy    (address(0) to skip)
    /// @param tokens       ScaledToken proxies  (empty to skip)
    function run(
        address compliance,
        address pauseManager,
        address factory,
        address tokenIssuer,
        address[] calldata tokens
    ) external {
        address newAdmin = _finalAdmin();
        address from = _broadcaster();
        _printHeader(newAdmin, from);

        vm.startBroadcast();
        _handover(compliance, "ComplianceRegistry", newAdmin, from);
        _handover(pauseManager, "PauseRegistry", newAdmin, from);
        _handover(factory, "ScaledTokenFactory", newAdmin, from);
        _handover(tokenIssuer, "TokenIssuer", newAdmin, from);
        for (uint256 i = 0; i < tokens.length; ++i) {
            _handover(tokens[i], "ScaledToken", newAdmin, from);
        }
        vm.stopBroadcast();

        console.log("=== Handover complete ===");
    }

    /// @notice Hand a single contract's DEFAULT_ADMIN_ROLE over to config.admin.
    function transferOne(address target) external {
        address newAdmin = _finalAdmin();
        address from = _broadcaster();
        _printHeader(newAdmin, from);

        vm.startBroadcast();
        _handover(target, "target", newAdmin, from);
        vm.stopBroadcast();
    }

    /// @dev Grant DEFAULT_ADMIN_ROLE to `newAdmin`, then revoke it from `from`. Grant-before-revoke
    ///      guarantees the role is never left with zero holders. Idempotent: skips a step already
    ///      satisfied. Verifies `newAdmin` holds the role before revoking `from`.
    function _handover(address target, string memory label, address newAdmin, address from)
        internal
    {
        if (target == address(0)) return;
        require(newAdmin != address(0), "TransferAdmin: config.admin is zero");
        if (newAdmin == from) {
            console.log("Skip", label, "- config.admin == broadcaster (nothing to hand over)");
            return;
        }

        IAccessControl ac = IAccessControl(target);

        if (!ac.hasRole(DEFAULT_ADMIN_ROLE, newAdmin)) {
            ac.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
            console.log("  granted DEFAULT_ADMIN_ROLE on", label, "to", newAdmin);
        } else {
            console.log("  already admin on", label, ":", newAdmin);
        }

        // Never revoke the broadcaster unless the new admin is confirmed in place.
        require(
            ac.hasRole(DEFAULT_ADMIN_ROLE, newAdmin),
            string.concat("TransferAdmin: new admin not set on ", label)
        );

        if (ac.hasRole(DEFAULT_ADMIN_ROLE, from)) {
            ac.revokeRole(DEFAULT_ADMIN_ROLE, from);
            console.log("  revoked DEFAULT_ADMIN_ROLE on", label, "from", from);
        } else {
            console.log("  broadcaster already not admin on", label);
        }
    }

    function _printHeader(address newAdmin, address from) internal pure {
        console.log("=== TransferAdmin ===");
        console.log("From (broadcaster):", from);
        console.log("To (config.admin): ", newAdmin);
    }

    /// @dev Reads the FINAL admin (handover target) from config.toml `.admin`.
    function _finalAdmin() internal view returns (address admin) {
        string memory path = vm.envOr("DEPLOY_CONFIG_PATH", string("./config.toml"));
        string memory toml = vm.readFile(path);
        admin = toml.readAddress(".admin");
        // Zero => broadcaster (i.e. "no handover"); _handover then no-ops.
        if (admin == address(0)) admin = _broadcaster();
    }

    /// @dev Mirrors forge-script's signer resolution: PRIVATE_KEY env, else tx.origin.
    function _broadcaster() internal view returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return vm.addr(pk);
        return msg.sender;
    }
}
