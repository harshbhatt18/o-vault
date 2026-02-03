// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from "./IPriceOracle.sol";

/// @notice Minimal Chainlink Aggregator V3 interface.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkOracle
/// @notice Price oracle adapter for Chainlink price feeds.
/// @dev Includes staleness checks and decimal normalization to 18 decimals.
///      Used by StreamVault for NAV validation and manipulation detection.
contract ChainlinkOracle is IPriceOracle {
    AggregatorV3Interface public immutable FEED;
    address public immutable ASSET;
    uint256 public immutable STALENESS_THRESHOLD;
    uint8 public immutable FEED_DECIMALS;

    // Target precision: 18 decimals
    uint8 public constant TARGET_DECIMALS = 18;

    error StalePrice();
    error InvalidPrice();
    error InvalidRound();

    /// @param _feed Chainlink price feed address (e.g., USDC/USD).
    /// @param _asset The asset this oracle provides prices for.
    /// @param _stalenessThreshold Maximum age of price data in seconds (e.g., 3600 for 1 hour).
    constructor(address _feed, address _asset, uint256 _stalenessThreshold) {
        FEED = AggregatorV3Interface(_feed);
        ASSET = _asset;
        STALENESS_THRESHOLD = _stalenessThreshold;
        FEED_DECIMALS = AggregatorV3Interface(_feed).decimals();
    }

    /// @notice Get the current price normalized to 18 decimals.
    /// @return price The price in 18 decimal precision.
    /// @return updatedAt Timestamp of the last price update.
    function getPrice() external view override returns (uint256 price, uint256 updatedAt) {
        (uint80 roundId, int256 answer,, uint256 _updatedAt, uint80 answeredInRound) = FEED.latestRoundData();

        // Validate round completeness
        if (answeredInRound < roundId) revert InvalidRound();

        // Validate price is positive
        if (answer <= 0) revert InvalidPrice();

        // Check staleness
        if (block.timestamp - _updatedAt > STALENESS_THRESHOLD) revert StalePrice();

        // Normalize to 18 decimals
        // forge-lint: disable-next-line(unsafe-typecast)
        // casting to 'uint256' is safe because we validated answer > 0 above
        price = _normalize(uint256(answer));
        updatedAt = _updatedAt;
    }

    /// @notice The asset this oracle provides prices for.
    function asset() external view override returns (address) {
        return ASSET;
    }

    /// @notice Check if the oracle price is stale.
    function isStale() external view override returns (bool) {
        (,,, uint256 updatedAt,) = FEED.latestRoundData();
        return block.timestamp - updatedAt > STALENESS_THRESHOLD;
    }

    /// @notice Get the raw Chainlink price without normalization (for debugging).
    function getRawPrice() external view returns (int256 answer, uint256 updatedAt) {
        (, answer,, updatedAt,) = FEED.latestRoundData();
    }

    /// @dev Normalize price from feed decimals to 18 decimals.
    function _normalize(uint256 price) internal view returns (uint256) {
        if (FEED_DECIMALS < TARGET_DECIMALS) {
            return price * (10 ** (TARGET_DECIMALS - FEED_DECIMALS));
        } else if (FEED_DECIMALS > TARGET_DECIMALS) {
            return price / (10 ** (FEED_DECIMALS - TARGET_DECIMALS));
        }
        return price;
    }
}
