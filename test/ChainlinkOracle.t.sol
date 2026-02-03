// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

/// @title ChainlinkOracle Tests
/// @notice Comprehensive tests for the Chainlink price oracle adapter.
contract ChainlinkOracle_Test is Test {
    ChainlinkOracle internal oracle;
    MockChainlinkAggregator internal mockFeed;

    address internal constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    uint256 internal constant STALENESS_THRESHOLD = 3600; // 1 hour

    function setUp() public {
        // Warp to a reasonable timestamp to avoid underflow
        vm.warp(1_000_000);

        // USDC/USD feed typically has 8 decimals, price ~1e8 ($1.00)
        mockFeed = new MockChainlinkAggregator(8, 1e8);
        oracle = new ChainlinkOracle(address(mockFeed), USDC, STALENESS_THRESHOLD);
    }

    // ─── Constructor Tests ───────────────────────────────────────────────

    function test_constructor_setsCorrectValues() public view {
        assertEq(address(oracle.FEED()), address(mockFeed));
        assertEq(oracle.ASSET(), USDC);
        assertEq(oracle.STALENESS_THRESHOLD(), STALENESS_THRESHOLD);
        assertEq(oracle.FEED_DECIMALS(), 8);
    }

    // ─── getPrice Tests ──────────────────────────────────────────────────

    function test_getPrice_returnsNormalizedPrice() public view {
        (uint256 price, uint256 updatedAt) = oracle.getPrice();

        // 1e8 (8 decimals) normalized to 18 decimals = 1e18
        assertEq(price, 1e18, "Price should be 1e18 for $1.00");
        assertEq(updatedAt, block.timestamp);
    }

    function test_getPrice_normalizesFrom8To18Decimals() public {
        // Set price to $1.50 (1.5e8 in 8 decimals)
        mockFeed.setPrice(15e7);

        (uint256 price, ) = oracle.getPrice();

        // 1.5e8 normalized to 18 decimals = 1.5e18
        assertEq(price, 15e17, "Price should be 1.5e18 for $1.50");
    }

    function test_getPrice_revertsOnStalePrice() public {
        // Set price updated 2 hours ago
        mockFeed.setStalePrice(1e8, block.timestamp - 7200);

        vm.expectRevert(ChainlinkOracle.StalePrice.selector);
        oracle.getPrice();
    }

    function test_getPrice_revertsOnNegativePrice() public {
        mockFeed.setPrice(-1e8);

        vm.expectRevert(ChainlinkOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function test_getPrice_revertsOnZeroPrice() public {
        mockFeed.setPrice(0);

        vm.expectRevert(ChainlinkOracle.InvalidPrice.selector);
        oracle.getPrice();
    }

    function test_getPrice_revertsOnIncompleteRound() public {
        mockFeed.setIncompleteRound(1e8);

        vm.expectRevert(ChainlinkOracle.InvalidRound.selector);
        oracle.getPrice();
    }

    // ─── isStale Tests ───────────────────────────────────────────────────

    function test_isStale_returnsFalseWhenFresh() public view {
        assertFalse(oracle.isStale(), "Fresh price should not be stale");
    }

    function test_isStale_returnsTrueWhenStale() public {
        mockFeed.setStalePrice(1e8, block.timestamp - 7200);

        assertTrue(oracle.isStale(), "Old price should be stale");
    }

    function test_isStale_boundaryCondition() public {
        // Exactly at staleness threshold
        mockFeed.setStalePrice(1e8, block.timestamp - STALENESS_THRESHOLD);

        // At exact threshold, should NOT be stale (uses > not >=)
        assertFalse(oracle.isStale());

        // Just past threshold
        mockFeed.setStalePrice(1e8, block.timestamp - STALENESS_THRESHOLD - 1);
        assertTrue(oracle.isStale());
    }

    // ─── asset Tests ─────────────────────────────────────────────────────

    function test_asset_returnsCorrectAddress() public view {
        assertEq(oracle.asset(), USDC);
    }

    // ─── getRawPrice Tests ───────────────────────────────────────────────

    function test_getRawPrice_returnsUnmodifiedData() public {
        mockFeed.setPrice(12345678);

        (int256 answer, uint256 updatedAt) = oracle.getRawPrice();

        assertEq(answer, 12345678);
        assertEq(updatedAt, block.timestamp);
    }

    // ─── Decimal Normalization Edge Cases ────────────────────────────────

    function test_getPrice_normalizes6DecimalFeed() public {
        // Create feed with 6 decimals (like some exotic pairs)
        MockChainlinkAggregator feed6 = new MockChainlinkAggregator(6, 1e6);
        ChainlinkOracle oracle6 = new ChainlinkOracle(address(feed6), USDC, STALENESS_THRESHOLD);

        (uint256 price, ) = oracle6.getPrice();

        // 1e6 normalized to 18 decimals = 1e18
        assertEq(price, 1e18);
    }

    function test_getPrice_normalizes18DecimalFeed() public {
        // Create feed with 18 decimals (no normalization needed)
        MockChainlinkAggregator feed18 = new MockChainlinkAggregator(18, 1e18);
        ChainlinkOracle oracle18 = new ChainlinkOracle(address(feed18), USDC, STALENESS_THRESHOLD);

        (uint256 price, ) = oracle18.getPrice();

        assertEq(price, 1e18, "18-decimal feed should not be modified");
    }

    // ─── Fuzz Tests ──────────────────────────────────────────────────────

    function testFuzz_getPrice_normalizesAnyPositivePrice(int256 rawPrice) public {
        vm.assume(rawPrice > 0);
        vm.assume(rawPrice < type(int256).max / 1e10); // Prevent overflow

        mockFeed.setPrice(rawPrice);

        (uint256 price, ) = oracle.getPrice();

        // Verify normalization: price should be rawPrice * 1e10 (18-8=10)
        assertEq(price, uint256(rawPrice) * 1e10);
    }

    function testFuzz_isStale_correctForAnyTimestamp(uint256 timeDelta) public {
        // Warp forward to ensure we have headroom for large timeDelta values
        vm.warp(block.timestamp + 400 days);

        timeDelta = bound(timeDelta, 0, 365 days);

        mockFeed.setStalePrice(1e8, block.timestamp - timeDelta);

        if (timeDelta > STALENESS_THRESHOLD) {
            assertTrue(oracle.isStale());
        } else {
            assertFalse(oracle.isStale());
        }
    }
}
