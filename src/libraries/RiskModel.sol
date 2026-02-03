// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title RiskModel
/// @notice Risk parameter structures and LCR computation for CRE-updated risk management.
/// @dev Implements Basel III-inspired Liquidity Coverage Ratio model with per-source risk parameters.
library RiskModel {
    /// @notice Risk parameters per yield source, updated by CRE risk oracle
    struct SourceRiskParams {
        uint16 liquidityHaircutBps; // Haircut applied to this source's balance in LCR calc (0-10000)
        uint16 stressOutflowBps; // Expected outflow under stress scenario (0-10000)
        uint16 maxConcentrationBps; // Max % of vault TVL deployable to this source (0-10000)
        uint64 lastUpdated; // Timestamp of last CRE update
        uint8 riskTier; // 0=GREEN, 1=YELLOW, 2=ORANGE, 3=RED
    }

    /// @notice Aggregate risk snapshot written by CRE workflow
    struct RiskSnapshot {
        uint256 stressedLCR; // LCR under stressed conditions (basis points, 10000 = 100%)
        uint256 aggregateRiskScore; // Composite risk score 0-10000
        uint64 timestamp; // When this snapshot was computed
        uint8 systemStatus; // 0=GREEN, 1=YELLOW, 2=ORANGE, 3=RED
    }

    /// @notice Risk tier enumeration for clarity
    uint8 internal constant TIER_GREEN = 0;
    uint8 internal constant TIER_YELLOW = 1;
    uint8 internal constant TIER_ORANGE = 2;
    uint8 internal constant TIER_RED = 3;

    /// @notice Maximum allowed haircut (95% = 9500 bps)
    uint16 internal constant MAX_HAIRCUT_BPS = 9500;

    /// @notice Basis points denominator
    uint256 internal constant BPS = 10_000;

    /// @notice Computes HQLA (High Quality Liquid Assets) for a single source
    /// @param balance The source's current balance
    /// @param haircutBps The haircut to apply (0-10000)
    /// @return hqla The haircut-adjusted balance
    function computeSourceHQLA(uint256 balance, uint16 haircutBps) internal pure returns (uint256 hqla) {
        if (haircutBps >= BPS) return 0;
        hqla = (balance * (BPS - haircutBps)) / BPS;
    }

    /// @notice Computes stressed outflows for a single source
    /// @param balance The source's current balance
    /// @param stressOutflowBps Expected outflow rate under stress (0-10000)
    /// @return outflow The expected stressed outflow amount
    function computeSourceStressedOutflow(uint256 balance, uint16 stressOutflowBps)
        internal
        pure
        returns (uint256 outflow)
    {
        outflow = (balance * stressOutflowBps) / BPS;
    }

    /// @notice Checks if a source's concentration would breach its limit
    /// @param sourceBalance The source's balance after proposed deployment
    /// @param totalAssets Total vault assets
    /// @param maxConcentrationBps Maximum concentration allowed (0-10000)
    /// @return breached True if concentration limit would be breached
    function isConcentrationBreached(uint256 sourceBalance, uint256 totalAssets, uint16 maxConcentrationBps)
        internal
        pure
        returns (bool breached)
    {
        if (totalAssets == 0) return sourceBalance > 0;
        uint256 concentrationBps = (sourceBalance * BPS) / totalAssets;
        breached = concentrationBps > maxConcentrationBps;
    }

    /// @notice Validates risk parameters are within acceptable bounds
    /// @param params The parameters to validate
    /// @return valid True if all parameters are valid
    function validateParams(SourceRiskParams memory params) internal pure returns (bool valid) {
        if (params.liquidityHaircutBps > MAX_HAIRCUT_BPS) return false;
        if (params.stressOutflowBps > uint16(BPS)) return false;
        if (params.maxConcentrationBps > uint16(BPS)) return false;
        if (params.riskTier > TIER_RED) return false;
        return true;
    }

    /// @notice Returns default risk parameters for a newly registered source
    /// @return params Default permissive parameters (no constraints until CRE sets them)
    function defaultParams() internal pure returns (SourceRiskParams memory params) {
        params = SourceRiskParams({
            liquidityHaircutBps: 1000, // 10% haircut
            stressOutflowBps: 3000, // 30% stress outflow
            maxConcentrationBps: 10000, // 100% max concentration (no limit by default)
            lastUpdated: 0,
            riskTier: TIER_GREEN
        });
    }
}
