// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockChainlinkAggregator
/// @notice Mock Chainlink Aggregator V3 for testing price oracle functionality.
contract MockChainlinkAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        answer = _initialAnswer;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _answer, uint256 startedAt, uint256 _updatedAt, uint80 _answeredInRound)
    {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    /// @notice Set the price (for testing).
    function setPrice(int256 _price) external {
        answer = _price;
        updatedAt = block.timestamp;
        roundId++;
        answeredInRound = roundId;
    }

    /// @notice Set stale price (updatedAt in the past).
    function setStalePrice(int256 _price, uint256 _updatedAt) external {
        answer = _price;
        updatedAt = _updatedAt;
        roundId++;
        answeredInRound = roundId;
    }

    /// @notice Simulate incomplete round.
    function setIncompleteRound(int256 _price) external {
        answer = _price;
        updatedAt = block.timestamp;
        roundId++;
        // answeredInRound stays behind roundId (incomplete)
    }
}
