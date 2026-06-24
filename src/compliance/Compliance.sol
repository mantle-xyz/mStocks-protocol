// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./ICompliance.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/**
 * @title  Compliance
 * @notice Provides an interface for compliance checks.
 * @notice This contract is responsible for enforcing compliance rules for SecuritiesToken contracts and
 *         associated systems. It manages a per-token blocklist and
 *         a global sanctions list.
 *
 *         The sanctions list uses an epoch pattern: bumping `sanctionEpoch` in
 *         {setSanctionedAddresses} or {resetSanctionedAddresses} invalidates all previous
 *         sanctions in O(1) gas, regardless of how many addresses were previously sanctioned.
 *
 *         Role hierarchy:
 *          - DEFAULT_ADMIN_ROLE (Owner)
 *              ├── Manages grant/revoke of all roles
 *              └── Manages blocklist and sanctions list
 *          - OPS_ROLE
 *              └── Manages blocklist and sanctions list
 *          - COMPLIANCE_ROLE
 *              └── Manages blocklist and sanctions list
 */
contract Compliance is ICompliance, AccessControlEnumerable {
    /// Operational role for day-to-day management
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// Compliance-specific role for blocklist and sanctions list management
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// Per-token mapping of blocked user addresses
    mapping(address /*token*/ => mapping(address /*user*/ => bool)) public blockedAddresses;

    /// Current sanctions epoch. Incrementing this value clears all sanctions in O(1).
    /// Starts at 1 so that 0 is always a stale value and can be used as the explicit
    /// "unsanctioned" sentinel — safe against underflow and unambiguous to readers.
    uint256 private sanctionEpoch;

    /// Maps each address to the epoch in which it was sanctioned.
    /// An address is currently sanctioned iff sanctionAddressEpoch[addr] == sanctionEpoch.
    /// An address is unsanctioned iff sanctionAddressEpoch[addr] != sanctionEpoch (including 0).
    mapping(address => uint256) private sanctionAddressEpoch;

    /**
     * @notice Emitted when addresses are added to the blocklist for a token
     * @param  token     The token address for which the blocklist was updated
     * @param  addresses The addresses that were added to the blocklist
     */
    event AddedToBlocklist(address indexed token, address[] addresses);

    /**
     * @notice Emitted when addresses are removed from the blocklist for a token
     * @param  token     The token address for which the blocklist was updated
     * @param  addresses The addresses that were removed from the blocklist
     */
    event RemovedFromBlocklist(address indexed token, address[] addresses);

    /**
     * @notice Emitted when addresses are added to the global sanctions list
     * @param  addresses The addresses that were added to the sanctions list
     */
    event AddedToSanctionsList(address[] addresses);

    /**
     * @notice Emitted when addresses are removed from the global sanctions list
     * @param  addresses The addresses that were removed from the sanctions list
     */
    event RemovedFromSanctionsList(address[] addresses);

    /**
     * @notice Emitted when the sanctions list is replaced wholesale
     * @dev    oldList is not emitted — it cannot be enumerated without a backing array.
     *         Callers should treat this event as a full reset: all previously sanctioned
     *         addresses are cleared and only newList is now sanctioned.
     * @param  newList The new list of sanctioned addresses
     */
    event SanctionedAddressesSet(address[] newList);

    /// Error thrown when a user is blocked via the blocklist
    error UserBlocked();

    /// Error thrown when a user is sanctioned via the sanctions list
    error UserSanctioned();

    /// Error thrown when an empty addresses array is provided
    error EmptyAddressesArray();

    /// Error thrown when caller lacks a blocklist management role
    error MissingBlocklistRole();

    /// Error thrown when the admin address is zero
    error ZeroAddress();

    /// @param admin The address that will be granted the default admin role
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(COMPLIANCE_ROLE, DEFAULT_ADMIN_ROLE);
        // Start at epoch 1 so epoch 0 (default mapping value) is never "active"
        sanctionEpoch = 1;
    }

    /**
     * @notice Modifier that restricts access to blocklist management roles
     * @dev    Allows DEFAULT_ADMIN_ROLE, OPS_ROLE, or COMPLIANCE_ROLE
     */
    modifier onlyBlocklistRole() {
        _checkBlocklistRole();
        _;
    }

    function _checkBlocklistRole() private view {
        if (
            !hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !hasRole(OPS_ROLE, _msgSender())
                && !hasRole(COMPLIANCE_ROLE, _msgSender())
        ) revert MissingBlocklistRole();
    }

    /**
     * @notice Check if a user is compliant with compliance rules
     * @param  token The token address
     * @param  user  The user address
     * @dev    Reverts if the user is not compliant.
     *         Token-level suspension is handled by PauseManager, not by this contract.
     *         This function only checks user-level compliance.
     */
    function checkIsCompliant(address token, address user) external view override {
        if (blockedAddresses[token][user]) revert UserBlocked();
        if (sanctionAddressEpoch[user] == sanctionEpoch) revert UserSanctioned();
    }

    /**
     * @notice Returns whether an address is currently sanctioned
     * @param  user The address to check
     * @return True if the address is sanctioned in the current epoch
     */
    function sanctionedAddresses(address user) external view returns (bool) {
        return sanctionAddressEpoch[user] == sanctionEpoch;
    }

    /**
     * @notice Add addresses to the blocklist for a given token
     * @param  token     The token address
     * @param  addresses The addresses to add to the blocklist
     * @dev    Callable by DEFAULT_ADMIN_ROLE, OPS_ROLE, or COMPLIANCE_ROLE
     */
    function addToBlocklist(address token, address[] calldata addresses) external onlyBlocklistRole {
        if (addresses.length == 0) revert EmptyAddressesArray();

        for (uint256 i = 0; i < addresses.length; ++i) {
            if (addresses[i] == address(0)) revert ZeroAddress();
            blockedAddresses[token][addresses[i]] = true;
        }
        emit AddedToBlocklist(token, addresses);
    }

    /**
     * @notice Remove addresses from the blocklist for a given token
     * @param  token     The token address
     * @param  addresses The addresses to remove from the blocklist
     * @dev    Callable by DEFAULT_ADMIN_ROLE, OPS_ROLE, or COMPLIANCE_ROLE
     */
    function removeFromBlocklist(address token, address[] calldata addresses) external onlyBlocklistRole {
        if (addresses.length == 0) revert EmptyAddressesArray();

        for (uint256 i = 0; i < addresses.length; ++i) {
            if (addresses[i] == address(0)) revert ZeroAddress();
            blockedAddresses[token][addresses[i]] = false;
        }
        emit RemovedFromBlocklist(token, addresses);
    }

    /**
     * @notice Add addresses to the global sanctions list
     * @param  addresses The addresses to add to the sanctions list
     * @dev    Callable by DEFAULT_ADMIN_ROLE, OPS_ROLE, or COMPLIANCE_ROLE
     */
    function addToSanctionsList(address[] calldata addresses) external onlyBlocklistRole {
        if (addresses.length == 0) revert EmptyAddressesArray();

        uint256 currentEpoch = sanctionEpoch;
        address[] memory effectivelyAdded = new address[](addresses.length);
        uint256 count = 0;
        for (uint256 i = 0; i < addresses.length; ++i) {
            if (addresses[i] == address(0)) revert ZeroAddress();
            if (sanctionAddressEpoch[addresses[i]] == currentEpoch) continue;
            sanctionAddressEpoch[addresses[i]] = currentEpoch;
            effectivelyAdded[count++] = addresses[i];
        }
        assembly { mstore(effectivelyAdded, count) }
        emit AddedToSanctionsList(effectivelyAdded);
    }

    /**
     * @notice Remove addresses from the global sanctions list
     * @param  addresses The addresses to remove from the sanctions list
     * @dev    Callable by DEFAULT_ADMIN_ROLE, OPS_ROLE, or COMPLIANCE_ROLE
     */
    function removeFromSanctionsList(address[] calldata addresses) external onlyBlocklistRole {
        if (addresses.length == 0) revert EmptyAddressesArray();

        uint256 currentEpoch = sanctionEpoch;
        address[] memory effectivelyRemoved = new address[](addresses.length);
        uint256 count = 0;
        for (uint256 i = 0; i < addresses.length; ++i) {
            if (addresses[i] == address(0)) revert ZeroAddress();
            if (sanctionAddressEpoch[addresses[i]] != currentEpoch) continue;
            // Reset to 0 — the explicit unsanctioned sentinel.
            // Using 0 (rather than sanctionEpoch - 1) is safe regardless of the current
            // epoch value and clearly communicates intent.
            sanctionAddressEpoch[addresses[i]] = 0;
            effectivelyRemoved[count++] = addresses[i];
        }
        assembly { mstore(effectivelyRemoved, count) }
        emit RemovedFromSanctionsList(effectivelyRemoved);
    }

    /**
     * @notice Clears the entire sanctions list in O(1) gas
     * @dev    Bumps the internal epoch counter, instantly invalidating all previously
     *         sanctioned addresses regardless of list size. No new addresses are added.
     *         Callable by DEFAULT_ADMIN_ROLE, OPS_ROLE, or COMPLIANCE_ROLE.
     */
    function resetSanctionedAddresses() external onlyBlocklistRole {
        sanctionEpoch++;
        emit SanctionedAddressesSet(new address[](0));
    }

    /**
     * @notice Replaces the entire sanctions list with `newAddresses`
     * @param  newAddresses The new list of addresses to sanction.
     *                      Passing an empty array clears all sanctions.
     * @dev    Bumps the internal epoch counter, which invalidates ALL previously sanctioned
     *         addresses in O(1) gas regardless of list size. Then writes only the new list.
     *         Duplicate entries in `newAddresses` are silently deduplicated.
     *         Zero address is not allowed.
     *         Callable by DEFAULT_ADMIN_ROLE, OPS_ROLE, or COMPLIANCE_ROLE.
     */
    function setSanctionedAddresses(address[] calldata newAddresses) external onlyBlocklistRole {
        // O(1) invalidation of all previous sanctions
        uint256 newEpoch = ++sanctionEpoch;

        // Write the new list into the fresh epoch
        for (uint256 i = 0; i < newAddresses.length; ++i) {
            address addr = newAddresses[i];
            if (addr == address(0)) revert ZeroAddress();
            // Deduplicate: skip if already written in this epoch
            if (sanctionAddressEpoch[addr] == newEpoch) continue;
            sanctionAddressEpoch[addr] = newEpoch;
        }

        emit SanctionedAddressesSet(newAddresses);
    }
}
