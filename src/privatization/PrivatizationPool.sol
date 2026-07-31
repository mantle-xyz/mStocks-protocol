// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMintAndBurnable} from "../tokenIssuer/IMintAndBurnable.sol";

/// @notice Privatization / take-private (delisting) claim pool — 方案一 of
///         docs/corporate-actions-td.md.
///
///         One pool per delisting event. An old mStocks security is retired and holders
///         swap it, at a FIXED per-share rate, for new mStocks and/or USDC. Because the
///         rate is fixed and the old token's supply is frozen (issuer `setMintAllowed(false)`),
///         there is no need for a record-date snapshot, a Merkle tree, or escrow: whoever
///         holds the old token can surrender any amount and receive the proportional
///         consideration.
///
///         Flow (holder-initiated pull, no push):
///           1. holder `approve`s this pool to move `amount` of the old token
///           2. holder calls {claim} → pool pulls + burns the old token and transfers the
///              new token and/or USDC out of its pre-funded inventory.
///
///         Setup by the operator before opening claims:
///           - `setMintAllowed(false)` on the old token (freeze supply)
///           - grant this pool ISSUER_ROLE on the old token (so it can burn what it pulls in)
///           - fund this pool with the new mStocks (minted via that token's issuer) and USDC
///
///         Rates are expressed per {RATE_SCALE} (1e18) units of old-token *raw* amount; the
///         operator bakes any UI-multiplier conversion into the rate at deploy time (the old
///         token's multiplier is frozen at delisting, so the rate is constant). Fractional
///         remainders are handled by the operator's choice of rate (round-down truncation
///         here); any cash-in-lieu is delivered through `usdcRate`.
contract PrivatizationPool is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Fixed-point scale for {newRate} / {usdcRate}. 1e18 == "1.0 per old raw unit".
    uint256 public constant RATE_SCALE = 1e18;

    /// @notice The retired security being surrendered.
    address public immutable oldToken;
    /// @notice New mStocks delivered as consideration (address(0) if cash-only).
    address public immutable newToken;
    /// @notice USDC (or other settlement stablecoin) delivered as consideration (address(0) if stock-only).
    address public immutable usdc;

    /// @notice New-token raw delivered per {RATE_SCALE} of old-token raw surrendered.
    uint256 public immutable newRate;
    /// @notice USDC (its own decimals) delivered per {RATE_SCALE} of old-token raw surrendered.
    uint256 public immutable usdcRate;

    /// @notice Claims are accepted up to and including this timestamp.
    uint64 public immutable deadline;
    /// @notice May {sweepUnclaimed} after the deadline.
    address public immutable admin;

    event Claimed(address indexed holder, uint256 oldAmount, uint256 newOut, uint256 usdcOut);
    event Swept(address indexed to, uint256 newLeft, uint256 usdcLeft);

    error ZeroAddress();
    error NoConsiderationConfigured();
    error ClaimClosed();
    error ClaimStillOpen();
    error ZeroAmount();
    error NothingToDeliver();
    error NotAdmin();

    constructor(
        address oldToken_,
        address newToken_,
        address usdc_,
        uint256 newRate_,
        uint256 usdcRate_,
        uint64 deadline_,
        address admin_
    ) {
        if (oldToken_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        // Each configured leg must have a token AND a non-zero rate, and at least one leg
        // must exist — otherwise a claim would burn the old token for nothing.
        bool hasStock = newToken_ != address(0) && newRate_ != 0;
        bool hasCash = usdc_ != address(0) && usdcRate_ != 0;
        if (!hasStock && !hasCash) revert NoConsiderationConfigured();

        oldToken = oldToken_;
        newToken = newToken_;
        usdc = usdc_;
        newRate = newRate_;
        usdcRate = usdcRate_;
        deadline = deadline_;
        admin = admin_;
    }

    /// @notice Consideration for surrendering `oldAmount` (raw) of the old token.
    function previewClaim(uint256 oldAmount) public view returns (uint256 newOut, uint256 usdcOut) {
        newOut = newToken == address(0) ? 0 : Math.mulDiv(oldAmount, newRate, RATE_SCALE);
        usdcOut = usdc == address(0) ? 0 : Math.mulDiv(oldAmount, usdcRate, RATE_SCALE);
    }

    /// @notice Surrender `amount` (raw) of the old token and receive the fixed-rate
    ///         consideration. Caller must have `approve`d this pool for `amount` first.
    ///
    ///         The old tokens are pulled in and burned; the new token / USDC are transferred
    ///         from this pool's pre-funded inventory. A compliance-blocked holder's new-token
    ///         transfer reverts, rolling back the whole claim (old token stays with them) —
    ///         they can retry once unblocked, so no escrow is needed.
    function claim(uint256 amount) external nonReentrant {
        if (block.timestamp > deadline) revert ClaimClosed();
        if (amount == 0) revert ZeroAmount();

        (uint256 newOut, uint256 usdcOut) = previewClaim(amount);
        if (newOut == 0 && usdcOut == 0) revert NothingToDeliver();

        // Pull the old token in, then burn it (this pool holds ISSUER_ROLE on the old token).
        IERC20(oldToken).safeTransferFrom(msg.sender, address(this), amount);
        IMintAndBurnable(oldToken).burn(amount);

        // Deliver consideration from pre-funded inventory.
        if (newOut != 0) IERC20(newToken).safeTransfer(msg.sender, newOut);
        if (usdcOut != 0) IERC20(usdc).safeTransfer(msg.sender, usdcOut);

        emit Claimed(msg.sender, amount, newOut, usdcOut);
    }

    /// @notice After the deadline, sweep the remaining (unclaimed) consideration to a custody
    ///         address. Holders who never claimed keep their frozen old token and simply
    ///         forgo the consideration (see docs/corporate-actions-td.md §6.4).
    function sweepUnclaimed(address to) external nonReentrant {
        if (msg.sender != admin) revert NotAdmin();
        if (block.timestamp <= deadline) revert ClaimStillOpen();
        if (to == address(0)) revert ZeroAddress();

        uint256 newLeft;
        uint256 usdcLeft;
        if (newToken != address(0)) {
            newLeft = IERC20(newToken).balanceOf(address(this));
            if (newLeft != 0) IERC20(newToken).safeTransfer(to, newLeft);
        }
        if (usdc != address(0)) {
            usdcLeft = IERC20(usdc).balanceOf(address(this));
            if (usdcLeft != 0) IERC20(usdc).safeTransfer(to, usdcLeft);
        }
        emit Swept(to, newLeft, usdcLeft);
    }
}
