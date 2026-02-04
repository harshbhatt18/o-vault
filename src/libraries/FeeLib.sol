// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeLib
/// @notice Pure fee calculation helpers used by StreamVault.
/// @dev Extracted from StreamVault for separation of concerns and readability.
///      All functions are `internal pure/view` — no storage access, no side effects.
library FeeLib {
    using Math for uint256;

    uint256 internal constant BPS = 10_000;

    /// @notice Compute performance fee on profit above high water mark.
    /// @param profit Profit amount in asset decimals.
    /// @param feeBps Performance fee rate in basis points.
    /// @return feeAssets Fee amount in asset decimals (floors in favour of vault).
    function computePerformanceFee(uint256 profit, uint256 feeBps) internal pure returns (uint256 feeAssets) {
        if (profit == 0 || feeBps == 0) return 0;
        feeAssets = profit.mulDiv(feeBps, BPS, Math.Rounding.Floor);
    }

    /// @notice Compute time-proportional management fee.
    /// @param netAssets Net AUM in asset decimals.
    /// @param feeBps Annual management fee in basis points.
    /// @param elapsed Seconds since last accrual.
    /// @param secondsPerYear Seconds in a year (365.25 days).
    /// @return feeAssets Fee amount in asset decimals.
    function computeManagementFee(uint256 netAssets, uint256 feeBps, uint256 elapsed, uint256 secondsPerYear)
        internal
        pure
        returns (uint256 feeAssets)
    {
        if (netAssets == 0 || feeBps == 0 || elapsed == 0) return 0;
        feeAssets = netAssets.mulDiv(feeBps * elapsed, secondsPerYear * BPS, Math.Rounding.Floor);
    }

    /// @notice Compute withdrawal fee on a payout.
    /// @param payout Gross payout amount in asset decimals.
    /// @param feeBps Withdrawal fee in basis points.
    /// @return fee Fee amount deducted from payout (floors in favour of vault).
    function computeWithdrawalFee(uint256 payout, uint256 feeBps) internal pure returns (uint256 fee) {
        if (payout == 0 || feeBps == 0) return 0;
        fee = payout.mulDiv(feeBps, BPS, Math.Rounding.Floor);
    }

    /// @notice Convert assets to shares using EMA-based NAV.
    /// @dev Mirrors OZ _convertToShares but substitutes emaTotalAssets for totalAssets().
    /// @param assets Amount of assets to convert.
    /// @param totalSupply Current share supply.
    /// @param emaTotalAssets EMA-smoothed total assets.
    /// @param decimalsOffset Virtual share offset exponent.
    /// @return shares Equivalent share amount.
    function convertToSharesAtEma(uint256 assets, uint256 totalSupply, uint256 emaTotalAssets, uint8 decimalsOffset)
        internal
        pure
        returns (uint256 shares)
    {
        return (assets == 0 || totalSupply == 0)
            ? assets.mulDiv(10 ** decimalsOffset, 1, Math.Rounding.Floor)
            : assets.mulDiv(totalSupply + 10 ** decimalsOffset, emaTotalAssets + 1, Math.Rounding.Floor);
    }
}
