// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IComplianceRegistry} from "../../src/complianceRegistry/IComplianceRegistry.sol";

/// @notice Stands in for a ScaledToken where only its compliance registry matters.
///
///         WarrantRegistry reads `compliance()` off a program's token and calls nothing
///         else on it, so this exposes exactly that and no ERC-20 surface — a mock that
///         implemented transfers too would invite tests to lean on behaviour the contract
///         under test never exercises.
contract MockComplianceGuardedToken {
    IComplianceRegistry public compliance;

    constructor(IComplianceRegistry _compliance) {
        compliance = _compliance;
    }

    /// @dev Lets a test drop the registry, which is what an uninitialized token proxy
    ///      looks like from the outside.
    function setCompliance(IComplianceRegistry _compliance) external {
        compliance = _compliance;
    }
}

/// @notice A token that reverts on `compliance()`, standing in for the common case: a
///         plain ERC-20 that was never compliance-guarded at all.
contract MockUnguardedToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
