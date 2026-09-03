// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ScaledToken} from "./ScaledToken.sol";

/// @notice Deploys a ScaledToken implementation + UpgradeableBeacon on behalf of a
///         ScaledTokenFactory. Kept as a standalone contract so ScaledToken's large creation
///         bytecode is NOT embedded in ScaledTokenFactory's own deployed runtime bytecode.
///
///         ScaledTokenFactory is upgradeable, so this beacon deployment happens inside its
///         `initialize()` — a regular function, not a constructor. Inlining `new ScaledToken(...)`
///         there (as the pre-upgrade version did in its constructor) would count the entire
///         ScaledToken creation bytecode toward the factory's RUNTIME size, pushing it past the
///         EIP-170 24,576-byte contract size limit. Routing the CREATE through this separate
///         contract keeps it out of the factory's bytecode entirely.
///
///         Stateless and holds no privileges — every ScaledTokenFactory implementation can safely
///         share one instance.
contract ScaledTokenBeaconDeployer {
    /// @notice Deploys a fresh ScaledToken implementation and an UpgradeableBeacon pointing at it,
    ///         owned by `beaconOwner`. Called once per ScaledTokenFactory, from `initialize()`.
    function deployBeacon(uint256 minMultiplierNotice, address beaconOwner) external returns (address beacon) {
        beacon = address(new UpgradeableBeacon(address(new ScaledToken(minMultiplierNotice)), beaconOwner));
    }
}
