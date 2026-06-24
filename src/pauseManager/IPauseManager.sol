// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/**
 * @title  IPauseManager
 * @notice Interface for checking token pause states
 */
interface IPauseManager {
    function isTokenPaused(address _token) external view returns (bool);
}
