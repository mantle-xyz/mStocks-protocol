// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IComplianceRegistry} from "./IComplianceRegistry.sol";

/// @notice Upgradeable mixin that lets a token enforce per-transfer compliance checks
///         by delegating to an external {IComplianceRegistry}.
abstract contract ComplianceGuardUpgradeable is Initializable {
    /// @notice Compliance registry currently in effect.
    IComplianceRegistry public compliance;

    event ComplianceSet(address indexed token, address indexed oldCompliance, address indexed newCompliance);

    error ComplianceZeroAddress();
    error InvalidComplianceContract();

    function __ComplianceGuard_init(address _compliance) internal onlyInitializing {
        __ComplianceGuard_init_unchained(_compliance);
    }

    function __ComplianceGuard_init_unchained(address _compliance) internal onlyInitializing {
        _setCompliance(_compliance);
    }

    /// @notice Sets the compliance registry address. Validates the target is a contract
    ///         that responds to {IComplianceRegistry.checkIsCompliant}.
    function _setCompliance(address _compliance) internal {
        if (_compliance == address(0)) revert ComplianceZeroAddress();

        uint256 size;
        assembly { size := extcodesize(_compliance) }
        if (size == 0) revert InvalidComplianceContract();

        try IComplianceRegistry(_compliance).checkIsCompliant(address(this), address(this)) {
            // OK
        } catch (bytes memory) {
            revert InvalidComplianceContract();
        }

        address oldCompliance = address(compliance);
        compliance = IComplianceRegistry(_compliance);
        emit ComplianceSet(address(this), oldCompliance, _compliance);
    }

    /// @notice Reverts if `account` fails the compliance check for this token.
    function _checkIsCompliant(address account) internal view {
        compliance.checkIsCompliant(address(this), account);
    }

    /// @dev Storage gap for upgrade-safe inheritance.
    uint256[49] private __gap;
}
