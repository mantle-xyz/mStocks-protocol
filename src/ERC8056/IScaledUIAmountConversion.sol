// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @dev Optional extension interface for EIP-8056: On-chain amount conversion.
 * @notice See https://eips.ethereum.org/EIPS/eip-8056 for the full specification.
 *
 * Contracts MAY implement this extension to provide on-chain helpers for
 * converting between raw token amounts and their UI representations.
 *
 * ROUNDING: The rounding direction is implementation-defined and not specified
 * by EIP-8056. Round-trip conversion `fromUIAmount(toUIAmount(x))` is NOT
 * guaranteed to return `x`. Consult the implementation's NatDoc for the
 * specific rounding strategy in use.
 *
 * Interface ID: 0x57854fc3
 */
interface IScaledUIAmountConversion {
    /**
     * @dev Converts a raw token amount to its UI representation.
     */
    function toUIAmount(uint256 rawAmount) external view returns (uint256);

    /**
     * @dev Converts a UI amount back to its raw token amount.
     */
    function fromUIAmount(uint256 uiAmount) external view returns (uint256);
}
