// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RiskModel} from "../../src/libraries/RiskModel.sol";

/// @title RiskModel Symbolic Tests
/// @notice Halmos symbolic tests for RiskModel pure functions.
/// @dev Run with: halmos --root . --contract RiskModelSymbolicTest --solver-timeout-assertion 0
///
/// Best Practices Applied (from Halmos docs):
/// 1. Use vm.assume() instead of bound()
/// 2. Avoid symbolic division - use concrete denominators where possible
/// 3. Keep tests focused on single properties
/// 4. Test edge cases (zero, max values) explicitly
contract RiskModelSymbolicTest is Test {
    uint256 constant BPS = 10_000;

    // ═══════════════════════════════════════════════════════════════════════════
    // HQLA - Edge cases (no division complexity)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice HQLA with 0 haircut equals balance
    function check_hqla_zeroHaircut(uint256 balance) public pure {
        uint256 hqla = RiskModel.computeSourceHQLA(balance, 0);
        assert(hqla == balance);
    }

    /// @notice HQLA with 100% haircut is 0
    function check_hqla_fullHaircut(uint256 balance) public pure {
        uint256 hqla = RiskModel.computeSourceHQLA(balance, uint16(BPS));
        assert(hqla == 0);
    }

    /// @notice HQLA with 0 balance is always 0
    function check_hqla_zeroBalance(uint16 haircutBps) public pure {
        uint256 hqla = RiskModel.computeSourceHQLA(0, haircutBps);
        assert(hqla == 0);
    }

    /// @notice HQLA with haircut > 100% returns 0
    function check_hqla_excessiveHaircut(uint256 balance, uint16 haircutBps) public pure {
        vm.assume(haircutBps >= BPS);

        uint256 hqla = RiskModel.computeSourceHQLA(balance, haircutBps);
        assert(hqla == 0);
    }

    /// @notice HQLA never exceeds balance (concrete 50% haircut)
    function check_hqla_neverExceedsBalance_50pct(uint256 balance) public pure {
        vm.assume(balance <= type(uint128).max);

        uint256 hqla = RiskModel.computeSourceHQLA(balance, 5000); // 50%
        assert(hqla <= balance);
        assert(hqla == balance / 2); // Exactly half
    }

    /// @notice HQLA at 10% haircut is 90% of balance
    function check_hqla_10pctHaircut(uint256 balance) public pure {
        vm.assume(balance <= type(uint128).max);

        uint256 hqla = RiskModel.computeSourceHQLA(balance, 1000); // 10%
        assert(hqla == (balance * 9000) / BPS);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STRESSED OUTFLOW - Edge cases
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Stressed outflow with 0 rate is 0
    function check_stressedOutflow_zeroRate(uint256 balance) public pure {
        uint256 outflow = RiskModel.computeSourceStressedOutflow(balance, 0);
        assert(outflow == 0);
    }

    /// @notice Stressed outflow with 100% rate equals balance
    function check_stressedOutflow_fullRate(uint256 balance) public pure {
        uint256 outflow = RiskModel.computeSourceStressedOutflow(balance, uint16(BPS));
        assert(outflow == balance);
    }

    /// @notice Stressed outflow with 0 balance is 0
    function check_stressedOutflow_zeroBalance(uint16 stressOutflowBps) public pure {
        uint256 outflow = RiskModel.computeSourceStressedOutflow(0, stressOutflowBps);
        assert(outflow == 0);
    }

    /// @notice Stressed outflow at 30% (default) is 30% of balance
    function check_stressedOutflow_30pct(uint256 balance) public pure {
        vm.assume(balance <= type(uint128).max);

        uint256 outflow = RiskModel.computeSourceStressedOutflow(balance, 3000); // 30%
        assert(outflow == (balance * 3000) / BPS);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONCENTRATION BREACH - Edge cases (avoid symbolic division)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice 0 balance never breaches concentration
    function check_concentration_zeroBalanceNeverBreaches(uint256 totalAssets, uint16 maxBps) public pure {
        bool breached = RiskModel.isConcentrationBreached(0, totalAssets, maxBps);
        assert(!breached);
    }

    /// @notice Any balance breaches when totalAssets is 0
    function check_concentration_zeroTotalAssetsBreaches(uint256 sourceBalance) public pure {
        vm.assume(sourceBalance > 0);

        bool breached = RiskModel.isConcentrationBreached(sourceBalance, 0, uint16(BPS));
        assert(breached);
    }

    /// @notice 100% max concentration never breaches (except totalAssets=0)
    function check_concentration_fullAllocationNeverBreaches(uint256 sourceBalance, uint256 totalAssets) public pure {
        vm.assume(totalAssets > 0);
        vm.assume(sourceBalance <= totalAssets);

        bool breached = RiskModel.isConcentrationBreached(sourceBalance, totalAssets, uint16(BPS));
        assert(!breached);
    }

    /// @notice Equal balance and totalAssets at 100% limit doesn't breach
    function check_concentration_equalBalanceAndTotal(uint256 amount) public pure {
        vm.assume(amount > 0);

        bool breached = RiskModel.isConcentrationBreached(amount, amount, uint16(BPS));
        assert(!breached);
    }

    /// @notice Balance > totalAssets always breaches at < 100% limit
    function check_concentration_balanceExceedsTotalBreaches(uint256 totalAssets) public pure {
        vm.assume(totalAssets > 0);
        vm.assume(totalAssets < type(uint256).max);

        uint256 sourceBalance = totalAssets + 1;
        bool breached = RiskModel.isConcentrationBreached(sourceBalance, totalAssets, 5000); // 50%
        assert(breached);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PARAMETER VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Default params are always valid
    function check_defaultParamsValid() public pure {
        RiskModel.SourceRiskParams memory params = RiskModel.defaultParams();
        bool valid = RiskModel.validateParams(params);
        assert(valid);
    }

    /// @notice Haircut > MAX_HAIRCUT_BPS (9500) is invalid
    function check_excessiveHaircutInvalid(uint16 haircutBps) public pure {
        vm.assume(haircutBps > 9500);

        RiskModel.SourceRiskParams memory params = RiskModel.SourceRiskParams({
            liquidityHaircutBps: haircutBps,
            stressOutflowBps: 3000,
            maxConcentrationBps: 10000,
            lastUpdated: 0,
            riskTier: 0
        });

        bool valid = RiskModel.validateParams(params);
        assert(!valid);
    }

    /// @notice StressOutflow > BPS is invalid
    function check_excessiveStressOutflowInvalid(uint16 stressOutflowBps) public pure {
        vm.assume(stressOutflowBps > uint16(BPS));

        RiskModel.SourceRiskParams memory params = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 1000,
            stressOutflowBps: stressOutflowBps,
            maxConcentrationBps: 10000,
            lastUpdated: 0,
            riskTier: 0
        });

        bool valid = RiskModel.validateParams(params);
        assert(!valid);
    }

    /// @notice MaxConcentration > BPS is invalid
    function check_excessiveConcentrationInvalid(uint16 maxConcentrationBps) public pure {
        vm.assume(maxConcentrationBps > uint16(BPS));

        RiskModel.SourceRiskParams memory params = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 1000,
            stressOutflowBps: 3000,
            maxConcentrationBps: maxConcentrationBps,
            lastUpdated: 0,
            riskTier: 0
        });

        bool valid = RiskModel.validateParams(params);
        assert(!valid);
    }

    /// @notice RiskTier > 3 (RED) is invalid
    function check_invalidRiskTierInvalid(uint8 riskTier) public pure {
        vm.assume(riskTier > 3);

        RiskModel.SourceRiskParams memory params = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 1000,
            stressOutflowBps: 3000,
            maxConcentrationBps: 10000,
            lastUpdated: 0,
            riskTier: riskTier
        });

        bool valid = RiskModel.validateParams(params);
        assert(!valid);
    }

    /// @notice Valid params within all bounds pass validation
    function check_validParamsPass(
        uint16 haircutBps,
        uint16 stressOutflowBps,
        uint16 maxConcentrationBps,
        uint8 riskTier
    ) public pure {
        vm.assume(haircutBps <= 9500);
        vm.assume(stressOutflowBps <= uint16(BPS));
        vm.assume(maxConcentrationBps <= uint16(BPS));
        vm.assume(riskTier <= 3);

        RiskModel.SourceRiskParams memory params = RiskModel.SourceRiskParams({
            liquidityHaircutBps: haircutBps,
            stressOutflowBps: stressOutflowBps,
            maxConcentrationBps: maxConcentrationBps,
            lastUpdated: 0,
            riskTier: riskTier
        });

        bool valid = RiskModel.validateParams(params);
        assert(valid);
    }
}
