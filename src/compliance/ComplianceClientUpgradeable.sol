// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./ICompliance.sol";

/**
 * @title  ComplianceClientUpgradeable
 * @notice This abstract contract manages state for upgradeable compliance
 *         clients
 */
abstract contract ComplianceClientUpgradeable is Initializable {
    /// Compliance contract
    ICompliance public compliance;

    /**
     * @notice Emitted when the compliance address is set
     * @param  token         The token contract emitting this event
     * @param  oldCompliance The old compliance address
     * @param  newCompliance The new compliance address
     */
    event ComplianceSet(address indexed token, address indexed oldCompliance, address indexed newCompliance);

    /// Error emitted when the compliance address is zero
    error ComplianceZeroAddress();

    /// Error emitted when the address does not implement ICompliance
    error InvalidComplianceContract();

    /**
     * @notice Initialize the contract by setting compliance variable
     *
     * @param  _compliance Address of the compliance contract
     *
     * @dev    Function should be called by the inheriting contract on
     *         initialization
     */
    function __ComplianceClientInitializable_init(address _compliance) internal onlyInitializing {
        __ComplianceClientInitializable_init_unchained(_compliance);
    }

    /**
     * @dev Internal function to future-proof parent linearization. Matches OZ
     *      upgradeable suggestions
     */
    function __ComplianceClientInitializable_init_unchained(address _compliance) internal onlyInitializing {
        _setCompliance(_compliance);
    }

    /**
     * @notice Sets the compliance address for this client
     * @param  _compliance The new compliance address
     * @dev    Validates that the address is a contract and implements ICompliance
     */
    function _setCompliance(address _compliance) internal {
        if (_compliance == address(0)) {
            revert ComplianceZeroAddress();
        }
        // Validate the address is a contract
        uint256 size;
        assembly {
            size := extcodesize(_compliance)
        }
        if (size == 0) revert InvalidComplianceContract();
        // Validate the address implements ICompliance
        try ICompliance(_compliance).checkIsCompliant(address(this), address(this)) {
        // Valid compliance contract
        }
        catch (bytes memory) {
            revert InvalidComplianceContract();
        }
        address oldCompliance = address(compliance);
        compliance = ICompliance(_compliance);
        emit ComplianceSet(address(this), oldCompliance, _compliance);
    }

    /**
     * @notice Checks whether an address has been blocked
     * @param  account The account to check
     * @dev    This function will revert if the account is not compliant
     */
    function _checkIsCompliant(address account) internal view {
        compliance.checkIsCompliant(address(this), account);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
