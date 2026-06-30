// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Pause-state query interface used by token transfer hooks.
interface IPauseRegistry {
    /// @notice Returns true if `_token` is currently paused (individually or globally).
    function isTokenPaused(address _token) external view returns (bool);
}
