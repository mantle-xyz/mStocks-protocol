// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/**
 * @title  ICompliance
 * @notice Provides an interface for compliance checks.
 */
interface ICompliance {
    function checkIsCompliant(address token, address user) external view;
}
