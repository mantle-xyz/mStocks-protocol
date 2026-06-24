// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IScaledUIAmount} from "./IScaledUIAmount.sol";
import {IScaledUIAmountNewUIMultiplier} from "./IScaledUIAmountNewUIMultiplier.sol";
import {IScaledUIAmountConversion} from "./IScaledUIAmountConversion.sol";
import {IScaledUIAmountBalances} from "./IScaledUIAmountBalances.sol";
import {IERC8056Scheduled} from "./IERC8056Scheduled.sol";

/**
 * @dev Abstract upgradeable base contract for EIP-8056 Scaled UI Amount extension.
 * @notice See https://eips.ethereum.org/EIPS/eip-8056 for the full specification.
 *
 * This is the **upgradeable** version of ERC8056Base, designed for BeaconProxy
 * deployments. It uses OpenZeppelin upgradeable contracts and follows the
 * standard `__init` / `__init_unchained` initialization pattern.
 *
 * This implementation provides a UI multiplier mechanism that allows token
 * amounts to be displayed differently from their actual on-chain values.
 * Common use cases include stock splits, rebasing tokens, and RWA adjustments.
 *
 * The multiplier uses 18 decimals precision, where 1e18 represents 1.0x.
 * For example, a 2:1 stock split would use a multiplier of 2e18.
 *
 * Multiplier changes can be scheduled for a future timestamp, allowing
 * users and integrators to prepare for upcoming changes.
 *
 * To use this contract, inherit from it and implement {_authorizeMultiplierUpdate}
 * to define who can update the multiplier. Optionally override
 * {_validateMultiplier} and {_beforeMultiplierUpdate} for additional checks.
 *
 * Example:
 * ```solidity
 * contract MyToken is ERC8056BaseUpgradeable, OwnableUpgradeable {
 *     /// @custom:oz-upgrades-unsafe-allow constructor
 *     constructor() { _disableInitializers(); }
 *
 *     function initialize(string memory name_, string memory symbol_, uint256 supply, address owner)
 *         public initializer
 *     {
 *         __erc8056Base_init(name_, symbol_);
 *         __Ownable_init(owner);
 *         _mint(owner, supply * 10 ** decimals());
 *     }
 *
 *     function _authorizeMultiplierUpdate() internal override onlyOwner {}
 * }
 * ```
 *
 * See {ERC8056TokenUpgradeable} for a ready-to-deploy concrete implementation.
 *
 * ## Implemented Interfaces
 *
 * - {IScaledUIAmount} (EIP-8056 core, ID: 0xa60bf13d)
 * - {IScaledUIAmountNewUIMultiplier} (EIP-8056 required extension, ID: 0x4bd27648)
 * - {IScaledUIAmountConversion} (EIP-8056 optional extension, ID: 0x57854fc3)
 * - {IScaledUIAmountBalances} (EIP-8056 optional extension, ID: 0xd890fd71)
 * - {IERC8056Scheduled} (BSC extension, ID: 0xeb0093dd) — Not part of EIP-8056
 *
 * SECURITY CONSIDERATIONS:
 *
 * 1. Multiplier Thresholds (see {_validateMultiplier}):
 *    - Extremely high multipliers may cause overflow in UI calculations
 *    - Extremely low multipliers may cause precision loss (toUIAmount returning 0)
 *    - Consider implementing min/max bounds based on your use case
 *
 * 2. Pending Change Overwrites and Acceleration (see {_beforeMultiplierUpdate}):
 *    - By default, scheduled multiplier changes can be overwritten
 *    - The new effectiveAtTimestamp is only constrained to be in the future; an overwrite
 *      MAY shorten the previously announced window to as little as the next block
 *    - Integrators MUST NOT rely on the originally announced effectiveAt for risk-management
 *      timing; they MUST monitor {IERC8056Scheduled-UIMultiplierChangeOverwritten} events
 *    - Consider overriding {_beforeMultiplierUpdate} to prevent overwrites or acceleration
 *    - When overwrites occur, {IERC8056Scheduled-UIMultiplierChangeOverwritten} is emitted
 *
 * 3. Access Control:
 *    - The {_authorizeMultiplierUpdate} function MUST be overridden with proper access control
 *    - Consider using a multisig or timelock contract for production deployments
 */
abstract contract ERC8056BaseUpgradeable is
    ERC20Upgradeable,
    IScaledUIAmount,
    IScaledUIAmountNewUIMultiplier,
    IScaledUIAmountConversion,
    IScaledUIAmountBalances,
    IERC8056Scheduled,
    IERC165
{
    using Math for uint256;

    /**
     * @dev Multiplier precision: 1e18 = 1.0x multiplier.
     */
    uint256 internal constant MULTIPLIER_DECIMALS = 1e18;

    uint256 private _uiMultiplier;
    uint256 private _nextUiMultiplier;
    uint256 private _nextUiMultiplierEffectiveAt;

    /**
     * @notice Internal initialization function for ERC8056BaseUpgradeable
     * @param  name_   The initial name of the token
     * @param  symbol_ The initial symbol of the token
     */
    function __erc8056Base_init(string memory name_, string memory symbol_) internal onlyInitializing {
        __ERC20_init(name_, symbol_);
        __erc8056Base_init_unchained();
    }

    /**
     * @notice Unchained initialization function for ERC8056Base-specific state
     */
    function __erc8056Base_init_unchained() internal onlyInitializing {
        _uiMultiplier = MULTIPLIER_DECIMALS;
        _nextUiMultiplier = MULTIPLIER_DECIMALS;
        _nextUiMultiplierEffectiveAt = type(uint256).max;
        emit UIMultiplierUpdated(0, MULTIPLIER_DECIMALS, block.timestamp);
    }

    /**
     * @dev See {IScaledUIAmount-uiMultiplier}.
     *
     * Returns the currently active multiplier. If a scheduled change has
     * passed its effective timestamp, returns the new multiplier.
     */
    function uiMultiplier() public view virtual override returns (uint256) {
        if (block.timestamp >= _nextUiMultiplierEffectiveAt) {
            return _nextUiMultiplier;
        }
        return _uiMultiplier;
    }

    /**
     * @dev See {IScaledUIAmountNewUIMultiplier-newUIMultiplier}.
     *
     * Returns the pending UI multiplier scheduled to take effect at {effectiveAt}.
     * When no pending change exists, returns the same value as {uiMultiplier}.
     *
     * See {IERC8056Scheduled-pendingMultiplier} for a tuple-based alternative
     * that also returns the effective timestamp.
     */
    function newUIMultiplier() public view virtual override returns (uint256) {
        if (!hasPendingMultiplier()) {
            return uiMultiplier();
        }
        return _nextUiMultiplier;
    }

    /**
     * @dev See {IScaledUIAmountNewUIMultiplier-effectiveAt}.
     *
     * Returns the timestamp at which the pending multiplier becomes effective.
     * When no pending change exists, returns 0.
     */
    function effectiveAt() public view virtual override returns (uint256) {
        if (!hasPendingMultiplier()) {
            return 0;
        }
        return _nextUiMultiplierEffectiveAt;
    }

    /**
     * @dev See {IScaledUIAmountConversion-toUIAmount}.
     *
     * Converts a raw token amount to its UI representation using the current
     * multiplier. Uses {Math-mulDiv} for overflow-safe 512-bit arithmetic.
     *
     * Result is rounded toward zero (integer division truncation).
     * `fromUIAmount(toUIAmount(x)) <= x` — round-trip is NOT lossless.
     *
     * Integrators MUST NOT:
     * - Assert `fromUIAmount(toUIAmount(x)) == x` in invariants or revert checks
     * - Use this function for internal accounting; store raw amounts and call
     *   this only at the display boundary
     */
    function toUIAmount(uint256 rawAmount) public view virtual override returns (uint256) {
        return rawAmount.mulDiv(uiMultiplier(), MULTIPLIER_DECIMALS);
    }

    /**
     * @dev See {IScaledUIAmountConversion-fromUIAmount}.
     *
     * Converts a UI amount back to raw token amount. Uses {Math-mulDiv} for
     * overflow-safe 512-bit arithmetic.
     *
     * Result is rounded toward zero (integer division truncation).
     * `fromUIAmount(toUIAmount(x)) <= x` — round-trip is NOT lossless.
     *
     * Integrators MUST NOT:
     * - Assert `fromUIAmount(toUIAmount(x)) == x` in invariants or revert checks
     * - Use this function for internal accounting; store raw amounts and call
     *   this only at the display boundary
     */
    function fromUIAmount(uint256 uiAmount) public view virtual override returns (uint256) {
        return uiAmount.mulDiv(MULTIPLIER_DECIMALS, uiMultiplier());
    }

    /**
     * @dev See {IScaledUIAmountBalances-balanceOfUI}.
     *
     * Returns the UI-adjusted balance of `account`.
     *
     * NOTE: This function deliberately reverts when the multiplier is so extreme
     * that `balance × multiplier` would overflow `uint256`. Returning 0 in that
     * case would mislead frontends into showing an empty balance. A revert is a
     * clearer signal that the UI value is currently unrepresentable.
     */
    function balanceOfUI(address account) public view virtual override returns (uint256) {
        return toUIAmount(balanceOf(account));
    }

    /**
     * @dev See {IScaledUIAmountBalances-totalSupplyUI}.
     *
     * Returns the UI-adjusted total supply.
     *
     * NOTE: Like {balanceOfUI}, this reverts under extreme multipliers rather
     * than returning a misleading 0.
     */
    function totalSupplyUI() public view virtual override returns (uint256) {
        return toUIAmount(totalSupply());
    }

    /**
     * @dev See {IERC8056Scheduled-pendingMultiplier}.
     *
     * Returns the pending multiplier and its effective timestamp as a tuple.
     * When {hasPendingMultiplier} returns false, returns (0, 0).
     *
     * This is a BSC extension providing richer semantics than the EIP-standard
     * {newUIMultiplier} and {effectiveAt} individual getters.
     */
    function pendingMultiplier()
        public
        view
        virtual
        override
        returns (uint256 multiplier, uint256 effectiveAtTimestamp)
    {
        if (!hasPendingMultiplier()) {
            return (0, 0);
        }
        return (_nextUiMultiplier, _nextUiMultiplierEffectiveAt);
    }

    /**
     * @dev See {IERC8056Scheduled-hasPendingMultiplier}.
     */
    function hasPendingMultiplier() public view virtual override returns (bool) {
        return block.timestamp < _nextUiMultiplierEffectiveAt && _nextUiMultiplierEffectiveAt != type(uint256).max;
    }

    /**
     * @dev Overflow-safe variant of {toUIAmount} used internally by {_update}.
     *
     * Uses {Math-tryMul} instead of {Math-mulDiv} so that an intermediate
     * overflow does not revert the enclosing ERC-20 transfer. Returns
     * `(false, 0)` when `rawAmount × uiMultiplier` exceeds `uint256`.
     *
     * The public {toUIAmount} retains full {Math-mulDiv} 512-bit precision for
     * display and off-chain use; this function is only for the transfer path
     * where a revert would break ERC-20 backwards compatibility.
     */
    function _tryToUIAmount(uint256 rawAmount) internal view returns (bool ok, uint256 ui) {
        uint256 mult = uiMultiplier();
        (bool mulOk, uint256 prod) = Math.tryMul(rawAmount, mult);
        if (!mulOk) return (false, 0);
        return (true, prod / MULTIPLIER_DECIMALS);
    }

    /**
     * @dev Hook for access control. Must be overridden in derived contracts.
     *
     * This function should revert if `msg.sender` is not authorized to
     * update the multiplier.
     *
     * Example using OwnableUpgradeable:
     * ```solidity
     * function _authorizeMultiplierUpdate() internal override onlyOwner {}
     * ```
     *
     * Example using AccessControlUpgradeable:
     * ```solidity
     * function _authorizeMultiplierUpdate() internal override onlyRole(ADMIN_ROLE) {}
     * ```
     */
    function _authorizeMultiplierUpdate() internal virtual;

    /**
     * @dev Hook for validating multiplier values.
     *
     * Override this function to add min/max threshold checks. The default
     * implementation only requires the multiplier to be positive.
     *
     * SECURITY WARNING - MULTIPLIER THRESHOLDS:
     *
     * Without proper bounds, an authorized caller could set problematic multiplier values:
     *
     * 1. Extremely HIGH multipliers (e.g., > 1e30):
     *    - The computed uiAmount may exceed meaningful numeric ranges, producing
     *      values that are misleading or unusable for display purposes
     *    - For very large raw balances combined with very large multipliers, the
     *      final result may exceed uint256 capacity
     *
     * 2. Extremely LOW multipliers (e.g., < 1e12):
     *    - May cause precision loss in {toUIAmount}, returning 0 for small balances
     *    - Users may see zero balances despite holding tokens
     *
     * RECOMMENDATION: For production deployments, override this function to enforce
     * reasonable bounds based on your use case. Common ranges:
     *   - Stock splits: 1e17 (0.1x) to 1e20 (100x)
     *   - Rebasing tokens: 1e15 (0.001x) to 1e21 (1000x)
     *
     * @param newMultiplier The new multiplier value to validate
     *
     * Example:
     * ```solidity
     * function _validateMultiplier(uint256 newMultiplier) internal pure override {
     *     require(newMultiplier >= 1e15, "Multiplier too low");   // min 0.001x
     *     require(newMultiplier <= 1e21, "Multiplier too high");  // max 1000x
     * }
     * ```
     */
    function _validateMultiplier(uint256 newMultiplier) internal virtual {
        require(newMultiplier > 0, "ERC8056: multiplier must be positive");
    }

    /**
     * @dev Hook called before a multiplier update is applied.
     *
     * Override this function to add custom logic, such as preventing
     * overwrites of pending changes.
     *
     * SECURITY WARNING - REENTRANCY:
     *
     * This hook is called BEFORE state updates. If your override includes
     * external calls, consider adding reentrancy protection (e.g., OpenZeppelin's
     * ReentrancyGuard) to {setUIMultiplier} to prevent unexpected behavior.
     *
     * SECURITY WARNING - PENDING CHANGE OVERWRITES:
     *
     * By default, this implementation allows overwriting scheduled multiplier changes.
     * This may cause issues in the following scenarios:
     *
     * 1. User Confusion:
     *    - Users monitoring {IScaledUIAmount-UIMultiplierUpdated} events may plan based on scheduled changes
     *    - Overwritten changes are discarded ({IERC8056Scheduled-UIMultiplierChangeOverwritten} is emitted for tracking)
     *
     * 2. Multi-sig/DAO Governance:
     *    - Different proposals may accidentally overwrite each other
     *    - The final state may not match any approved proposal
     *
     * 3. Audit Trail:
     *    - While {IERC8056Scheduled-UIMultiplierChangeOverwritten} provides visibility, integrators must
     *      explicitly listen for this event to track overwrites
     *
     * RECOMMENDATION: For production deployments requiring strict scheduling,
     * override this function to prevent overwrites:
     *
     * @param newMultiplier The new multiplier value
     * @param effectiveAtTimestamp When the new multiplier should take effect
     *
     * Example (prevent overwriting pending changes):
     * ```solidity
     * function _beforeMultiplierUpdate(uint256, uint256) internal view override {
     *     require(!hasPendingMultiplier(), "Cannot overwrite pending change");
     * }
     * ```
     *
     * Example (prevent acceleration of a pending change):
     * ```solidity
     * function _beforeMultiplierUpdate(uint256, uint256 effectiveAtTimestamp) internal view override {
     *     if (hasPendingMultiplier()) {
     *         require(
     *             effectiveAtTimestamp >= effectiveAt(),
     *             "Cannot accelerate pending multiplier"
     *         );
     *     }
     * }
     * ```
     */
    function _beforeMultiplierUpdate(uint256 newMultiplier, uint256 effectiveAtTimestamp) internal virtual {}

    /**
     * @dev Hook called when a pending multiplier change is overwritten.
     *
     * Override to customize or disable the {IERC8056Scheduled-UIMultiplierChangeOverwritten} event.
     * For example, to disable the event entirely:
     * ```solidity
     * function _onMultiplierOverwrite(uint256, uint256, uint256, uint256) internal override {}
     * ```
     */
    function _onMultiplierOverwrite(
        uint256 overwrittenMultiplier,
        uint256 overwrittenEffectiveAt,
        uint256 newMultiplier,
        uint256 newEffectiveAt
    ) internal virtual {
        emit UIMultiplierChangeOverwritten(overwrittenMultiplier, overwrittenEffectiveAt, newMultiplier, newEffectiveAt);
    }

    /**
     * @dev Internal function to set the UI multiplier.
     *
     * This function validates the multiplier, calls the before-update hook,
     * and schedules the new multiplier. If a pending change exists and hasn't
     * taken effect yet, {_onMultiplierOverwrite} will be called.
     *
     * Requirements:
     *
     * - `effectiveAtTimestamp` must be in the future (> current block timestamp)
     * - `newMultiplier` must pass {_validateMultiplier} checks
     *
     * @param newMultiplier The new multiplier value (1e18 = 1.0x)
     * @param effectiveAtTimestamp When the new multiplier should take effect
     */
    function _setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) internal virtual {
        require(effectiveAtTimestamp > block.timestamp, "ERC8056: effective time must be in future");
        require(effectiveAtTimestamp < type(uint256).max, "ERC8056: effectiveAt overflow");

        _validateMultiplier(newMultiplier);
        _beforeMultiplierUpdate(newMultiplier, effectiveAtTimestamp);

        uint256 currentMult = uiMultiplier();

        // Check if we're overwriting a pending change that hasn't taken effect yet
        if (block.timestamp < _nextUiMultiplierEffectiveAt && _nextUiMultiplierEffectiveAt != type(uint256).max) {
            _onMultiplierOverwrite(_nextUiMultiplier, _nextUiMultiplierEffectiveAt, newMultiplier, effectiveAtTimestamp);
        } else if (block.timestamp >= _nextUiMultiplierEffectiveAt) {
            // Seal any pending change that has already become active
            _uiMultiplier = _nextUiMultiplier;
        }

        _nextUiMultiplier = newMultiplier;
        _nextUiMultiplierEffectiveAt = effectiveAtTimestamp;

        emit UIMultiplierUpdated(currentMult, newMultiplier, effectiveAtTimestamp);
    }

    /**
     * @dev Sets the UI multiplier.
     *
     * Note: How the multiplier is updated is an implementation detail per EIP-8056.
     * This function is not part of any standard interface. Authorized access is
     * enforced via {_authorizeMultiplierUpdate}.
     *
     * Requirements:
     *
     * - Caller must be authorized (see {_authorizeMultiplierUpdate})
     * - `newMultiplier` must be valid (see {_validateMultiplier})
     * - `effectiveAtTimestamp` must be > current block timestamp
     */
    function setUIMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) public virtual {
        _authorizeMultiplierUpdate();
        _setUIMultiplier(newMultiplier, effectiveAtTimestamp);
    }

    /**
     * @dev Override of ERC20Upgradeable internal transfer hook to emit {IScaledUIAmount-TransferWithUIAmount}.
     *
     * Per BEP-677, implementations MUST emit a {TransferWithUIAmount} event on every
     * token transfer, mint, and burn. Any override MUST call `super._update` to
     * preserve both ERC20 accounting and this event emission. Do NOT emit this
     * event separately instead of calling super — that would silently skip token
     * balance updates.
     *
     * Uses {_tryToUIAmount} to compute `uiAmount`, falling back to `0` when the
     * multiplication would overflow `uint256` rather than reverting. This
     * preserves ERC-20 backwards compatibility per EIP-8056. See
     * {IScaledUIAmount-TransferWithUIAmount} for the three sources of
     * `uiAmount = 0` (genuine zero, truncation, overflow sentinel) and the
     * unified consumer handling path.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        (bool ok, uint256 ui) = _tryToUIAmount(value);
        emit TransferWithUIAmount(from, to, value, ok ? ui : 0);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     *
     * Returns true for the following interface IDs:
     * - IERC165:                        0x01ffc9a7
     * - IERC20:                         0x36372b07
     * - IScaledUIAmount (EIP-8056 core):          0xa60bf13d
     * - IScaledUIAmountNewUIMultiplier (required): 0x4bd27648
     * - IScaledUIAmountConversion (optional):      0x57854fc3
     * - IScaledUIAmountBalances (optional):        0xd890fd71
     * - IERC8056Scheduled (BSC extension):         0xeb0093dd
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC20).interfaceId
            || interfaceId == type(IScaledUIAmount).interfaceId
            || interfaceId == type(IScaledUIAmountNewUIMultiplier).interfaceId
            || interfaceId == type(IScaledUIAmountConversion).interfaceId
            || interfaceId == type(IScaledUIAmountBalances).interfaceId
            || interfaceId == type(IERC8056Scheduled).interfaceId;
    }

    /**
     * @dev Reserved storage gap. See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * MAINTAINERS — when adding state variables, ALL of the following MUST hold:
     * 1. Declare the new variable BEFORE __gap (after the existing 3 variables)
     * 2. Decrement __gap size by exactly the number of new slots used
     *    (uint256 = 1 slot; mapping = 1 slot; struct = sum of fields rounded up
     *    to the 32-byte boundary)
     * 3. Do NOT reorder existing variables (_uiMultiplier, _nextUiMultiplier,
     *    _nextUiMultiplierEffectiveAt) — slot order is part of the on-chain
     *    storage layout contract
     * 4. Run `npx hardhat test` (includes the validateUpgrade layout test) and
     *    verify `.openzeppelin/.json` reflects the expected layout
     *    before deploying any upgrade
     * 5. If a future OpenZeppelin release adds state variables to a parent
     *    contract (e.g. ERC20Upgradeable), this gap may need to shrink even
     *    without any changes here — check OZ release notes before upgrading
     *
     * Current allocation: 47 gap + 3 used = 50 reserved slots total.
     *
     * If extensive storage additions are anticipated, consider migrating to
     * ERC-7201 namespaced storage (https://eips.ethereum.org/EIPS/eip-7201).
     */
    uint256[47] private __gap;
}
