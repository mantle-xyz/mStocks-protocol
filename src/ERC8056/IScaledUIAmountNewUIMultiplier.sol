// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Required extension interface for EIP-8056: Pending Multiplier.
 * @notice See https://eips.ethereum.org/EIPS/eip-8056 for the full specification.
 *
 * Compliant contracts MUST implement this extension to expose a pending UI
 * multiplier that has been scheduled but has not yet taken effect.
 *
 * Interface ID: 0x4bd27648
 */
interface IScaledUIAmountNewUIMultiplier {
    /**
     * @dev Returns the pending UI multiplier scheduled to take effect at {effectiveAt}.
     * Multiplier is represented with 18 decimals (1e18 = 1.0).
     *
     * When no pending change exists, MUST return the same value as
     * {IScaledUIAmount-uiMultiplier}.
     *
     * Integrators can determine whether a genuine pending change exists by
     * checking `effectiveAt() > block.timestamp`.
     */
    function newUIMultiplier() external view returns (uint256);

    /**
     * @dev Returns the timestamp at which the pending multiplier becomes effective.
     * When no pending change exists, MUST return 0.
     */
    function effectiveAt() external view returns (uint256);
}
