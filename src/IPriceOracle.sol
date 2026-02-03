// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceOracle
/// @notice Interface for price oracles used by StreamVault for NAV validation.
/// @dev Implementations should return prices in 18-decimal precision.
interface IPriceOracle {
    /// @notice Get the current price of the asset in USD (18 decimals).
    /// @return price The price in USD with 18 decimal places.
    /// @return updatedAt Timestamp of the last price update.
    function getPrice() external view returns (uint256 price, uint256 updatedAt);

    /// @notice The asset this oracle provides prices for.
    function asset() external view returns (address);

    /// @notice Check if the oracle price is stale.
    /// @return True if the price is considered stale.
    function isStale() external view returns (bool);
}
