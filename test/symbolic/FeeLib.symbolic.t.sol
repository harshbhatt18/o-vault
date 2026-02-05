// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeeLib} from "../../src/libraries/FeeLib.sol";

/// @title FeeLib Symbolic Tests
/// @notice Halmos symbolic tests for FeeLib pure functions.
/// @dev Run with: halmos --root . --contract FeeLibSymbolicTest --solver-timeout-assertion 0
///
/// Best Practices Applied (from Halmos docs):
/// 1. Use vm.assume() instead of bound() for efficiency
/// 2. Avoid complex division with symbolic values (causes SMT solver issues)
/// 3. Focus on assertion violations (Panic(1))
/// 4. Keep tests simple and focused on single properties
contract FeeLibSymbolicTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant SECONDS_PER_YEAR = 365.25 days;

    // ═══════════════════════════════════════════════════════════════════════════
    // PERFORMANCE FEE - Zero input edge cases (fast, no division)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Performance fee with 0 profit should always be 0
    function check_performanceFee_zeroProfit(uint256 feeBps) public pure {
        vm.assume(feeBps <= BPS);
        uint256 fee = FeeLib.computePerformanceFee(0, feeBps);
        assert(fee == 0);
    }

    /// @notice Performance fee with 0 fee rate should always be 0
    function check_performanceFee_zeroRate(uint256 profit) public pure {
        uint256 fee = FeeLib.computePerformanceFee(profit, 0);
        assert(fee == 0);
    }

    /// @notice Performance fee with both zero should be 0
    function check_performanceFee_bothZero() public pure {
        uint256 fee = FeeLib.computePerformanceFee(0, 0);
        assert(fee == 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PERFORMANCE FEE - Bounded properties (avoid SMT division issues)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Performance fee should never exceed profit (using concrete values)
    /// @dev Use concrete fee rates to avoid division complexity
    function check_performanceFee_neverExceedsProfit_10pct(uint256 profit) public pure {
        vm.assume(profit > 0);
        vm.assume(profit <= type(uint128).max); // Avoid overflow in mulDiv

        uint256 fee = FeeLib.computePerformanceFee(profit, 1000); // 10%
        assert(fee <= profit);
    }

    function check_performanceFee_neverExceedsProfit_50pct(uint256 profit) public pure {
        vm.assume(profit > 0);
        vm.assume(profit <= type(uint128).max);

        uint256 fee = FeeLib.computePerformanceFee(profit, 5000); // 50% (max allowed)
        assert(fee <= profit);
    }

    /// @notice 100% fee rate takes all profit
    function check_performanceFee_100pct_takesAll(uint256 profit) public pure {
        vm.assume(profit > 0);
        vm.assume(profit <= type(uint128).max);

        uint256 fee = FeeLib.computePerformanceFee(profit, BPS); // 100%
        assert(fee == profit);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MANAGEMENT FEE - Zero input edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Management fee with 0 assets should be 0
    function check_managementFee_zeroAssets(uint256 feeBps, uint256 elapsed) public pure {
        vm.assume(feeBps <= 500);
        vm.assume(elapsed <= 365 days);

        uint256 fee = FeeLib.computeManagementFee(0, feeBps, elapsed, SECONDS_PER_YEAR);
        assert(fee == 0);
    }

    /// @notice Management fee with 0 rate should be 0
    function check_managementFee_zeroRate(uint256 netAssets, uint256 elapsed) public pure {
        vm.assume(elapsed <= 365 days);

        uint256 fee = FeeLib.computeManagementFee(netAssets, 0, elapsed, SECONDS_PER_YEAR);
        assert(fee == 0);
    }

    /// @notice Management fee with 0 elapsed time should be 0
    function check_managementFee_zeroElapsed(uint256 netAssets, uint256 feeBps) public pure {
        vm.assume(feeBps <= 500);

        uint256 fee = FeeLib.computeManagementFee(netAssets, feeBps, 0, SECONDS_PER_YEAR);
        assert(fee == 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WITHDRAWAL FEE - Zero input edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Withdrawal fee with 0 payout should be 0
    function check_withdrawalFee_zeroPayout(uint256 feeBps) public pure {
        vm.assume(feeBps <= 100); // max 1%

        uint256 fee = FeeLib.computeWithdrawalFee(0, feeBps);
        assert(fee == 0);
    }

    /// @notice Withdrawal fee with 0 rate should be 0
    function check_withdrawalFee_zeroRate(uint256 payout) public pure {
        uint256 fee = FeeLib.computeWithdrawalFee(payout, 0);
        assert(fee == 0);
    }

    /// @notice Withdrawal fee never exceeds payout (concrete 1% rate)
    function check_withdrawalFee_neverExceedsPayout(uint256 payout) public pure {
        vm.assume(payout > 0);
        vm.assume(payout <= type(uint128).max);

        uint256 fee = FeeLib.computeWithdrawalFee(payout, 100); // 1% max
        assert(fee <= payout);
        assert(payout - fee > 0); // net payout always positive
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EMA SHARE CONVERSION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Converting 0 assets should always return 0 shares
    function check_convert_zeroAssets(uint256 totalSupply, uint256 emaTotalAssets) public pure {
        uint8 decimalsOffset = 3; // StreamVault uses 3

        uint256 shares = FeeLib.convertToSharesAtEma(0, totalSupply, emaTotalAssets, decimalsOffset);
        assert(shares == 0);
    }

    /// @notice First depositor gets assets * 10^offset shares
    function check_convert_firstDepositor(uint256 assets) public pure {
        vm.assume(assets > 0);
        vm.assume(assets <= 1e18); // Bound to avoid overflow

        uint8 decimalsOffset = 3;
        uint256 shares = FeeLib.convertToSharesAtEma(assets, 0, 0, decimalsOffset);

        uint256 expectedShares = assets * (10 ** decimalsOffset);
        assert(shares == expectedShares);
    }

    /// @notice With decimalsOffset=3, depositing 1000+ gets at least 1 share (inflation protection)
    function check_convert_inflationProtection(uint256 assets, uint256 totalSupply, uint256 emaTotalAssets) public pure {
        vm.assume(assets >= 1000);
        vm.assume(assets <= 1e12);
        vm.assume(totalSupply > 0);
        vm.assume(totalSupply <= 1e18);
        vm.assume(emaTotalAssets > 0);
        vm.assume(emaTotalAssets <= 1e18);

        uint8 decimalsOffset = 3;
        uint256 shares = FeeLib.convertToSharesAtEma(assets, totalSupply, emaTotalAssets, decimalsOffset);

        // With offset=3, the virtual 1000 shares in numerator prevents dust attacks
        assert(shares > 0);
    }
}
