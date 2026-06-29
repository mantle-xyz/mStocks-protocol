// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Minimal mint/burn interface for tokens managed by CexTokenIssuer.
 *      Matches SecuritiesToken.mint / SecuritiesToken.burn (both mint to / burn from caller).
 */
interface IMintAndBurnable {
    /// Mints `amount` tokens to the caller. Caller must hold ISSUER_ROLE on the token.
    function mint(uint256 amount) external returns (bool);

    /// Burns `amount` tokens from the caller. Caller must hold ISSUER_ROLE on the token.
    function burn(uint256 amount) external returns (bool);
}
