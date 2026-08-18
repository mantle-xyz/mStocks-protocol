// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Hands DEFAULT_ADMIN_ROLE over from the deploy signer (broadcaster — e.g. a Ledger)
///         to each contract's configured FINAL admin, across every contract deployed by
///         Deploy.s.sol.
///
/// Per-contract admins: each contract's handover target is read from its own
/// `[section].finalAdmin` in config.toml (sections: compliance / pauseRegistry / factory /
/// tokenIssuer / token), so different multisigs can own different contracts. There is NO global
/// default and NO fallback — a missing or zero `finalAdmin` for any target being handed over
/// REVERTS, so a handover can never silently land on the broadcaster or a wrong default.
///
/// Deploy.s.sol bootstraps every contract with the broadcaster as the temporary
/// DEFAULT_ADMIN_ROLE holder. Once deployment is complete AND all operational wiring is done
/// (token creation, OPS_ROLE grants, issuer ISSUER_ROLE, etc.), run this to move admin to the
/// multisig(s). Per target it GRANTS the role to the new admin first, then REVOKES it from the
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
///     <compliance> <pauseRegistry> <factory> <tokenIssuer> "[<token1>,<token2>]" \
///     --rpc-url $RPC --ledger --sender <ledgerAddr> --broadcast -vvv
///
///   # single target with an explicit new admin:
///   forge script script/TransferAdmin.s.sol:TransferAdmin --sig "transferOne(address,address)" \
///     <target> <newAdmin> --rpc-url $RPC --ledger --sender <ledgerAddr> --broadcast
contract TransferAdmin is Script {
    using stdToml for string;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    /// @param compliance   ComplianceRegistry  (address(0) to skip)
    /// @param pauseRegistry PauseRegistry        (address(0) to skip)
    /// @param factory      ScaledTokenFactory   (address(0) to skip)
    /// @param tokenIssuer  TokenIssuer proxy    (address(0) to skip)
    /// @param tokens       ScaledToken proxies  (empty to skip)
    function run(
        address compliance,
        address pauseRegistry,
        address factory,
        address tokenIssuer,
        address[] calldata tokens
    ) external {
        address from = _broadcaster();
        console.log("=== TransferAdmin (per-contract admins) ===");
        console.log("From (broadcaster):", from);

        vm.startBroadcast();
        // Resolve each target's finalAdmin only when that target is actually being handed over —
        // _sectionAdmin reverts on a missing/zero value, so skipped (address(0)) targets don't
        // require a configured admin.
        if (compliance != address(0)) {
            _handover(compliance, "ComplianceRegistry", _sectionAdmin("compliance"), from);
        }
        if (pauseRegistry != address(0)) {
            _handover(pauseRegistry, "PauseRegistry", _sectionAdmin("pauseRegistry"), from);
        }
        if (factory != address(0)) {
            _handover(factory, "ScaledTokenFactory", _sectionAdmin("factory"), from);
        }
        if (tokenIssuer != address(0)) {
            _handover(tokenIssuer, "TokenIssuer", _sectionAdmin("tokenIssuer"), from);
        }
        if (tokens.length > 0) {
            address tokenAdmin = _sectionAdmin("token");
            for (uint256 i = 0; i < tokens.length; ++i) {
                _handover(tokens[i], "ScaledToken", tokenAdmin, from);
            }
        }
        vm.stopBroadcast();

        console.log("=== Handover complete ===");
    }

    /// @notice Hand a single contract's DEFAULT_ADMIN_ROLE over to an explicit `newAdmin`.
    ///         Used for per-contract admins that don't map cleanly to a config section.
    function transferOne(address target, address newAdmin) external {
        address from = _broadcaster();
        console.log("=== TransferAdmin (single) ===");
        console.log("From (broadcaster):", from);
        console.log("To (newAdmin):     ", newAdmin);

        vm.startBroadcast();
        _handover(target, "target", newAdmin, from);
        vm.stopBroadcast();
    }

    /// @dev Grant DEFAULT_ADMIN_ROLE to `newAdmin`, then revoke it from `from`. Grant-before-revoke
    ///      guarantees the role is never left with zero holders. Idempotent: skips a step already
    ///      satisfied. Verifies `newAdmin` holds the role before revoking `from`.
    function _handover(address target, string memory label, address newAdmin, address from) internal {
        if (target == address(0)) return;
        require(newAdmin != address(0), "TransferAdmin: finalAdmin is zero");
        if (newAdmin == from) {
            console.log("Skip", label, "- finalAdmin == broadcaster (nothing to hand over)");
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
        require(ac.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), string.concat("TransferAdmin: new admin not set on ", label));

        if (ac.hasRole(DEFAULT_ADMIN_ROLE, from)) {
            ac.revokeRole(DEFAULT_ADMIN_ROLE, from);
            console.log("  revoked DEFAULT_ADMIN_ROLE on", label, "from", from);
        } else {
            console.log("  broadcaster already not admin on", label);
        }
    }

    /// @dev Resolves a contract's FINAL admin from config.toml `[section].finalAdmin`. There is no
    ///      global default and no fallback: a missing or zero value REVERTS, so a handover can never
    ///      silently target the broadcaster or a wrong default. Only called for targets actually
    ///      being handed over.
    function _sectionAdmin(string memory section) internal view returns (address admin) {
        string memory path = vm.envOr("DEPLOY_CONFIG_PATH", string("./config.toml"));
        string memory toml = vm.readFile(path);

        string memory sectionKey = string.concat(".", section, ".finalAdmin");
        require(
            vm.keyExistsToml(toml, sectionKey),
            string.concat("TransferAdmin: missing [", section, "].finalAdmin in config")
        );
        admin = toml.readAddress(sectionKey);
        require(admin != address(0), string.concat("TransferAdmin: [", section, "].finalAdmin is zero"));
    }

    /// @dev Mirrors forge-script's signer resolution: PRIVATE_KEY env, else tx.origin.
    function _broadcaster() internal view returns (address) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) return vm.addr(pk);
        return msg.sender;
    }
}
