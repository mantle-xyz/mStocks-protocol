// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IComplianceRegistry} from "./IComplianceRegistry.sol";

/// @notice Per-token blocklist + global sanctions list. OPS_ROLE manages entries;
///         admin only grants the role (separation of duties). Sanctions use an epoch
///         counter so a full reset is O(1) regardless of list size.
contract ComplianceRegistry is IComplianceRegistry, AccessControlEnumerable {
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");

    /// @notice token => user => blocked.
    mapping(address => mapping(address => bool)) public isBlocked;

    /// @dev Current sanctions epoch (starts at 1; epoch 0 is the explicit unsanctioned sentinel).
    uint256 private currentEpoch;

    /// @dev address => epoch in which it was sanctioned. Active iff value == currentEpoch.
    mapping(address => uint256) private epochOfUser;

    event UsersBlocked(address indexed token, address[] users);
    event UsersUnblocked(address indexed token, address[] users);
    event UsersSanctioned(address[] users);
    event UsersUnsanctioned(address[] users);
    /// @dev Emitted on wholesale replacement / reset. `newList` is the post-state set
    ///      (empty on a reset). Old entries are invalidated via epoch bump.
    event SanctionsReplaced(address[] newList);

    error UserBlocked();
    error UserSanctioned();
    error EmptyAddressList();
    error MissingOpsRole();
    error ZeroAddress();
    error SelfGrantNotAllowed();
    error CannotRenounceLastAdmin();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setRoleAdmin(OPS_ROLE, DEFAULT_ADMIN_ROLE);
        currentEpoch = 1;
    }

    modifier onlyOps() {
        _requireOps();
        _;
    }

    function _requireOps() private view {
        if (!hasRole(OPS_ROLE, _msgSender())) revert MissingOpsRole();
    }

    /// @notice Reverts if `user` is blocked for `token` or globally sanctioned. Token-level
    ///         pause is handled separately by the pause registry, not here.
    function checkIsCompliant(address token, address user) external view override {
        if (isBlocked[token][user]) revert UserBlocked();
        if (epochOfUser[user] == currentEpoch) revert UserSanctioned();
    }

    /// @notice Returns whether `user` is currently sanctioned.
    function isSanctioned(address user) external view returns (bool) {
        return epochOfUser[user] == currentEpoch;
    }

    function blockUsers(address token, address[] calldata users) external onlyOps {
        if (users.length == 0) revert EmptyAddressList();
        for (uint256 i = 0; i < users.length; ++i) {
            if (users[i] == address(0)) revert ZeroAddress();
            isBlocked[token][users[i]] = true;
        }
        emit UsersBlocked(token, users);
    }

    function unblockUsers(address token, address[] calldata users) external onlyOps {
        if (users.length == 0) revert EmptyAddressList();
        for (uint256 i = 0; i < users.length; ++i) {
            if (users[i] == address(0)) revert ZeroAddress();
            isBlocked[token][users[i]] = false;
        }
        emit UsersUnblocked(token, users);
    }

    function sanctionUsers(address[] calldata users) external onlyOps {
        if (users.length == 0) revert EmptyAddressList();

        uint256 epoch = currentEpoch;
        address[] memory effectivelyAdded = new address[](users.length);
        uint256 count = 0;
        for (uint256 i = 0; i < users.length; ++i) {
            if (users[i] == address(0)) revert ZeroAddress();
            if (epochOfUser[users[i]] == epoch) continue;
            epochOfUser[users[i]] = epoch;
            effectivelyAdded[count++] = users[i];
        }
        assembly { mstore(effectivelyAdded, count) }
        emit UsersSanctioned(effectivelyAdded);
    }

    function unsanctionUsers(address[] calldata users) external onlyOps {
        if (users.length == 0) revert EmptyAddressList();

        uint256 epoch = currentEpoch;
        address[] memory effectivelyRemoved = new address[](users.length);
        uint256 count = 0;
        for (uint256 i = 0; i < users.length; ++i) {
            if (users[i] == address(0)) revert ZeroAddress();
            if (epochOfUser[users[i]] != epoch) continue;
            epochOfUser[users[i]] = 0;
            effectivelyRemoved[count++] = users[i];
        }
        assembly { mstore(effectivelyRemoved, count) }
        emit UsersUnsanctioned(effectivelyRemoved);
    }

    /// @notice O(1) clears the entire sanctions list by bumping the epoch counter.
    function clearSanctions() external onlyOps {
        currentEpoch++;
        emit SanctionsReplaced(new address[](0));
    }

    /// @notice Replaces the sanctions list with `newList` (O(1) invalidation of the
    ///         old set, then O(N) write of the new). Duplicates are silently deduped.
    ///         Empty input reverts — callers wanting to fully clear must use
    ///         {clearSanctions} explicitly, so an ops script that accidentally
    ///         passes an empty array cannot silently wipe the entire list.
    function replaceSanctions(address[] calldata newList) external onlyOps {
        if (newList.length == 0) revert EmptyAddressList();
        uint256 epoch = ++currentEpoch;
        for (uint256 i = 0; i < newList.length; ++i) {
            address addr = newList[i];
            if (addr == address(0)) revert ZeroAddress();
            if (epochOfUser[addr] == epoch) continue;
            epochOfUser[addr] = epoch;
        }
        emit SanctionsReplaced(newList);
    }

    /// @notice Disallows self-grant — admin must delegate OPS_ROLE to a separate account.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override(AccessControl, IAccessControl)
    {
        if (account == _msgSender()) revert SelfGrantNotAllowed();
        super.grantRole(role, account);
    }

    /// @notice Blocks renouncing the final DEFAULT_ADMIN_ROLE holder, which would
    ///         permanently strip this non-upgradeable contract of admin capability.
    function renounceRole(bytes32 role, address callerConfirmation)
        public
        virtual
        override(AccessControl, IAccessControl)
    {
        if (role == DEFAULT_ADMIN_ROLE && getRoleMemberCount(DEFAULT_ADMIN_ROLE) <= 1) {
            revert CannotRenounceLastAdmin();
        }
        super.renounceRole(role, callerConfirmation);
    }
}
