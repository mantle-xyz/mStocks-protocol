// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev BSC extension interface for EIP-8056 with scheduled multiplier changes.
 * @notice BSC Extension — NOT part of the EIP-8056 specification.
 * Implementations on other chains may not support this interface.
 *
 * This interface provides richer semantics for querying pending multiplier
 * changes: a tuple return, a boolean guard, and an overwrite audit event.
 *
 * Interface ID: 0xeb0093dd
 */
interface IERC8056Scheduled {
    /**
     * @dev Emitted when a pending multiplier change is overwritten before taking effect.
     * @param overwrittenMultiplier The multiplier value that was scheduled but overwritten
     * @param overwrittenEffectiveAt The timestamp when the overwritten multiplier was supposed to take effect
     * @param newMultiplier The new multiplier value that replaced it
     * @param newEffectiveAt The timestamp when the new multiplier will take effect
     */
    event UIMultiplierChangeOverwritten(
        uint256 overwrittenMultiplier, uint256 overwrittenEffectiveAt, uint256 newMultiplier, uint256 newEffectiveAt
    );

    /**
     * @dev Returns the pending multiplier and its effective timestamp.
     *
     * When {hasPendingMultiplier} returns false, MUST return (0, 0).
     * Because a scheduled change requires `effectiveAtTimestamp > block.timestamp`,
     * no genuine pending state can have `effectiveAt == 0`. Clients MAY therefore
     * use the (0, 0) sentinel directly, or call {hasPendingMultiplier} for an
     * explicit boolean check.
     *
     * @return multiplier The scheduled next multiplier value
     * @return effectiveAt The timestamp when the multiplier becomes active
     */
    function pendingMultiplier() external view returns (uint256 multiplier, uint256 effectiveAt);

    /**
     * @dev Returns true if there is a pending multiplier change that hasn't taken effect yet.
     */
    function hasPendingMultiplier() external view returns (bool);
}
