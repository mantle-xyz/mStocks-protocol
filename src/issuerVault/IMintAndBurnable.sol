// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Minimal mint/burn interface for tokens managed by IssuerVault.
///         Both operations act on the caller's balance.
interface IMintAndBurnable {
    function mint(uint256 amount) external returns (bool);
    function burn(uint256 amount) external returns (bool);
}
