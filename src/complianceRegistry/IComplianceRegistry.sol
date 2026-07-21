// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Compliance check interface used by token transfer hooks.
interface IComplianceRegistry {
    /// @notice Reverts if `user` is not compliant for the given `token` context.
    function checkIsCompliant(address token, address user) external view;
}
