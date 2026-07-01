// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IPauseRegistry} from "./IPauseRegistry.sol";

/// @notice Upgradeable mixin that lets a token consult an external {IPauseRegistry}
///         during transfers and revert when paused.
abstract contract PauseGuardUpgradeable is Initializable {
    IPauseRegistry public pauseManager;

    error TokenPaused();
    error PauseManagerCantBeZero();
    error InvalidPauseManagerContract();

    event PauseManagerSet(address indexed token, address indexed oldPauseManager, address indexed newPauseManager);

    function __PauseGuard_init(address _pauseManager) internal onlyInitializing {
        __PauseGuard_init_unchained(_pauseManager);
    }

    function __PauseGuard_init_unchained(address _pauseManager) internal onlyInitializing {
        _setPauseManager(_pauseManager);
    }

    /// @notice Sets the pause registry address. Validates the target is a contract that
    ///         responds to {IPauseRegistry.isTokenPaused}.
    function _setPauseManager(address _pauseManager) internal {
        if (_pauseManager == address(0)) revert PauseManagerCantBeZero();

        uint256 size;
        assembly { size := extcodesize(_pauseManager) }
        if (size == 0) revert InvalidPauseManagerContract();

        try IPauseRegistry(_pauseManager).isTokenPaused(address(this)) {
            // OK
        } catch (bytes memory) {
            revert InvalidPauseManagerContract();
        }

        emit PauseManagerSet(address(this), address(pauseManager), _pauseManager);
        pauseManager = IPauseRegistry(_pauseManager);
    }

    /// @notice Reverts with {TokenPaused} if this token is paused.
    function _checkTokenIsPaused() internal view {
        if (pauseManager.isTokenPaused(address(this))) revert TokenPaused();
    }

    /// @dev Storage gap for upgrade-safe inheritance.
    uint256[49] private __gap;
}
