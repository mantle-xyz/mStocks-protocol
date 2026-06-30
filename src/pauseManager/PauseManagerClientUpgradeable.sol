// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./IPauseManager.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title  PauseManagerClientUpgradeable
 * @notice Provides helper functionality to check if a token contract is paused.
 * @dev    This abstract contract integrates with the `IPauseManager` to enforce pause states via modifiers.
 */
abstract contract PauseManagerClientUpgradeable is Initializable {
    /// The instance of the `IPauseManager` contract used to check pause states.
    IPauseManager public pauseManager;

    /// Thrown when the token is paused
    error TokenPaused();

    /// Thrown when attempting to set the token pause manager to the zero address
    error PauseManagerCantBeZero();

    /// Thrown when the address does not implement IPauseManager
    error InvalidPauseManagerContract();

    /**
     * @notice Event emitted when the token pause manager is set
     * @param  token                 The token contract emitting this event
     * @param  oldPauseManager The old token pause manager address
     * @param  newPauseManager The new token pause manager address
     */
    event PauseManagerSet(address indexed token, address indexed oldPauseManager, address indexed newPauseManager);

    /**
     * @notice Initialize the contract by setting token pause manager variable
     *
     * @param  _pauseManager Address of the token pause manager contract
     *
     * @dev    Function should be called by the inheriting contract on
     *         initialization
     */
    function __PauseManagerClientInitializable_init(address _pauseManager) internal onlyInitializing {
        __PauseManagerClientInitializable_init_unchained(_pauseManager);
    }

    /**
     * @dev Internal function to future-proof parent linearization. Matches OZ
     *      upgradeable suggestions
     */
    function __PauseManagerClientInitializable_init_unchained(address _pauseManager) internal onlyInitializing {
        _setPauseManager(_pauseManager);
    }

    /**
     * @notice Sets the token pause manager address for this client
     *
     * @param _pauseManager The new token pause manager address
     * @dev   Validates that the address is a contract and implements IPauseManager
     */
    function _setPauseManager(address _pauseManager) internal {
        if (_pauseManager == address(0)) revert PauseManagerCantBeZero();

        // Validate the address is a contract
        uint256 size;
        assembly {
            size := extcodesize(_pauseManager)
        }
        if (size == 0) revert InvalidPauseManagerContract();
        // Validate the address implements IPauseManager
        try IPauseManager(_pauseManager).isTokenPaused(address(this)) {
        // Valid token pause manager contract
        }
        catch (bytes memory) {
            revert InvalidPauseManagerContract();
        }

        emit PauseManagerSet(address(this), address(pauseManager), _pauseManager);
        pauseManager = IPauseManager(_pauseManager);
    }

    /**
     * @notice Internal helper that reverts with {TokenPaused} if the calling token
     *         contract is currently paused (either individually or globally via the
     *         pause manager).
     * @dev    Intended to be called from inside the inheriting token's transfer hook
     *         (e.g. `_update`). Not a modifier — kept as a function to allow callers
     *         to mix this check with others in their own modifier chain.
     */
    function _checkTokenIsPaused() internal view {
        if (pauseManager.isTokenPaused(address(this))) {
            revert TokenPaused();
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
