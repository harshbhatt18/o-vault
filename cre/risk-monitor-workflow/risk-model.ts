/**
 * StreamVault Risk Model
 *
 * Pure function implementation of the risk computation logic.
 * No CRE SDK dependencies — this runs identically on every DON node (deterministic).
 *
 * Three-layer model:
 * 1. Per-source risk scores (0-10000)
 * 2. Stress simulation — compute stressed LCR
 * 3. Action decision engine
 */

import { encodeAbiParameters, parseAbiParameters } from "viem";

// ═══════════════════════════════════════════════════════════════════════════
// Type Definitions
// ═══════════════════════════════════════════════════════════════════════════

export interface ProtocolHealth {
  aaveUtilizationBps: number; // 0-10000
  aaveAvailableLiquidity: bigint;
  aaveOracleDeviation: number; // absolute deviation in bps
  morphoUtilizationBps: number; // 0-10000
  morphoAvailableLiquidity: bigint;
  morphoMatchingRateBps: number; // 0-10000
}

export interface VaultState {
  totalAssets: bigint;
  aaveBalance: bigint;
  morphoBalance: bigint;
  idleBalance: bigint;
  pendingWithdrawals: bigint;
  currentEpochStart: number;
  epochMinDuration: number;
  aaveSourceAddress: string;
  morphoSourceAddress: string;
}

export interface RiskResult {
  sourceScores: { aave: number; morpho: number };
  stressedLCR: number; // basis points
  systemStatus: number; // 0=GREEN, 1=YELLOW, 2=ORANGE, 3=RED
  action:
    | "NONE"
    | "UPDATE_PARAMS"
    | "REBALANCE"
    | "EMERGENCY_PAUSE"
    | "SETTLE_EPOCH";
  encodedPayload: string; // ABI-encoded payload for onReport()
  newParams: {
    aaveHaircutBps: number;
    aaveConcentrationBps: number;
    morphoHaircutBps: number;
    morphoConcentrationBps: number;
  };
}

// Action type constants (must match Solidity)
const ACTION_UPDATE_RISK_PARAMS = 0;
const ACTION_DEFENSIVE_REBALANCE = 1;
const ACTION_EMERGENCY_PAUSE = 2;

// ═══════════════════════════════════════════════════════════════════════════
// Main Risk Model Function
// ═══════════════════════════════════════════════════════════════════════════

/**
 * @param health Protocol health metrics from on-chain reads
 * @param vault Vault state from on-chain reads
 * @param nowUnixSeconds Current timestamp from runtime.now() for determinism across DON nodes
 */
export function computeRiskModel(
  health: ProtocolHealth,
  vault: VaultState,
  nowUnixSeconds?: number
): RiskResult {
  // ═══════════════════════════════════════════════════════════════════════
  // LAYER 1: Per-Source Risk Scores (0-10000)
  // ═══════════════════════════════════════════════════════════════════════

  const aaveScore = computeSourceRiskScore(
    health.aaveUtilizationBps,
    health.aaveAvailableLiquidity,
    vault.aaveBalance,
    health.aaveOracleDeviation,
    vault.totalAssets
  );

  const morphoScore = computeSourceRiskScore(
    health.morphoUtilizationBps,
    health.morphoAvailableLiquidity,
    vault.morphoBalance,
    0, // Morpho doesn't have separate oracle deviation concern
    vault.totalAssets
  );

  // ═══════════════════════════════════════════════════════════════════════
  // LAYER 2: Stress Simulation — Compute Stressed LCR
  // ═══════════════════════════════════════════════════════════════════════

  // Map risk scores to haircuts (higher risk = higher haircut)
  const aaveHaircut = riskScoreToHaircut(aaveScore);
  const morphoHaircut = riskScoreToHaircut(morphoScore);

  // HQLA = Σ(balance * (10000 - haircut) / 10000) + idle
  const aaveHQLA =
    (vault.aaveBalance * BigInt(10000 - aaveHaircut)) / 10000n;
  const morphoHQLA =
    (vault.morphoBalance * BigInt(10000 - morphoHaircut)) / 10000n;
  const totalHQLA = aaveHQLA + morphoHQLA + vault.idleBalance;

  // Stressed outflows: pending withdrawals + stress multiplier on TVL
  const stressOutflowRate = 3000; // Assume 30% redemption stress scenario
  const stressedOutflows =
    vault.pendingWithdrawals +
    (vault.totalAssets * BigInt(stressOutflowRate)) / 10000n;

  // LCR = HQLA / Outflows (in basis points, 10000 = 100%)
  const stressedLCR =
    stressedOutflows > 0n
      ? Number((totalHQLA * 10000n) / stressedOutflows)
      : 99999; // No outflows = infinite LCR

  // ═══════════════════════════════════════════════════════════════════════
  // LAYER 3: Action Decision Engine
  // ═══════════════════════════════════════════════════════════════════════

  let systemStatus: number;
  let action: RiskResult["action"];

  if (stressedLCR >= 15000) {
    // > 150% — healthy
    systemStatus = 0; // GREEN
    action = "UPDATE_PARAMS"; // Still update params to reflect current state
  } else if (stressedLCR >= 12000) {
    // 120-150% — cautious
    systemStatus = 1; // YELLOW
    action = "UPDATE_PARAMS"; // Tighten params
  } else if (stressedLCR >= 10000) {
    // 100-120% — defensive
    systemStatus = 2; // ORANGE
    action = "REBALANCE"; // Pull capital from riskiest source
  } else {
    // < 100% — critical
    systemStatus = 3; // RED
    action = "EMERGENCY_PAUSE";
  }

  // Derive concentration limits from risk scores
  const aaveConcentration =
    aaveScore > 7000 ? 2000 : aaveScore > 4000 ? 4000 : 6000;
  const morphoConcentration =
    morphoScore > 7000 ? 2000 : morphoScore > 4000 ? 4000 : 6000;

  // Deterministic timestamp for the report snapshot
  const timestampSec = nowUnixSeconds ?? Math.floor(Date.now() / 1000);

  // ABI-encode the payload for Solidity's onReport()
  const encodedPayload = encodeReportPayload(
    action,
    {
      aaveHaircutBps: aaveHaircut,
      aaveConcentrationBps: aaveConcentration,
      aaveStressOutflowBps: riskScoreToStressOutflow(aaveScore),
      aaveRiskTier: scoreToTier(aaveScore),
      morphoHaircutBps: morphoHaircut,
      morphoConcentrationBps: morphoConcentration,
      morphoStressOutflowBps: riskScoreToStressOutflow(morphoScore),
      morphoRiskTier: scoreToTier(morphoScore),
      stressedLCR,
      systemStatus,
      aggregateRiskScore: Math.floor((aaveScore + morphoScore) / 2),
      timestampSec,
    },
    vault
  );

  return {
    sourceScores: { aave: aaveScore, morpho: morphoScore },
    stressedLCR,
    systemStatus,
    action,
    encodedPayload,
    newParams: {
      aaveHaircutBps: aaveHaircut,
      aaveConcentrationBps: aaveConcentration,
      morphoHaircutBps: morphoHaircut,
      morphoConcentrationBps: morphoConcentration,
    },
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Helper Functions
// ═══════════════════════════════════════════════════════════════════════════

function computeSourceRiskScore(
  utilizationBps: number,
  availableLiquidity: bigint,
  vaultExposure: bigint,
  oracleDeviationBps: number,
  totalVaultAssets: bigint
): number {
  // Utilization risk: non-linear. Near-zero below 80%, exponential above
  let utilizationRisk = 0;
  if (utilizationBps > 9500) utilizationRisk = 10000; // Critical: >95%
  else if (utilizationBps > 9000) utilizationRisk = 7000; // High: 90-95%
  else if (utilizationBps > 8000) utilizationRisk = 3000; // Moderate: 80-90%
  else utilizationRisk = (utilizationBps * 500) / 8000; // Low: linear below 80%

  // Liquidity risk: vault's position size vs available pool liquidity
  let liquidityRisk = 0;
  if (availableLiquidity > 0n) {
    const ratio = Number((vaultExposure * 10000n) / availableLiquidity);
    liquidityRisk = Math.min(ratio, 10000); // If vault is 100%+ of available liquidity, max risk
  } else if (vaultExposure > 0n) {
    liquidityRisk = 10000; // No liquidity available but we have exposure
  }

  // Oracle risk
  const oracleRisk = Math.min(oracleDeviationBps * 20, 10000); // 500bps deviation = max risk

  // Concentration risk: vault exposure as % of total vault
  const concentrationRisk =
    totalVaultAssets > 0n
      ? Number((vaultExposure * 10000n) / totalVaultAssets)
      : 0;

  // Weighted composite (weights sum to 10000)
  const score = Math.floor(
    (utilizationRisk * 3500 +
      liquidityRisk * 3000 +
      oracleRisk * 2000 +
      concentrationRisk * 1500) /
      10000
  );

  return Math.min(score, 10000);
}

function riskScoreToHaircut(score: number): number {
  // Maps risk score (0-10000) to liquidity haircut (0-9500 bps)
  // Low risk: minimal haircut. High risk: heavy haircut.
  if (score < 2000) return 500; // 5% haircut — healthy
  if (score < 4000) return 1500; // 15% haircut — moderate
  if (score < 6000) return 3000; // 30% haircut — elevated
  if (score < 8000) return 5000; // 50% haircut — high
  return 7500; // 75% haircut — critical
}

function riskScoreToStressOutflow(score: number): number {
  // Maps risk score to expected stress outflow rate
  if (score < 2000) return 1000; // 10% outflow
  if (score < 4000) return 2000; // 20% outflow
  if (score < 6000) return 3000; // 30% outflow
  if (score < 8000) return 5000; // 50% outflow
  return 7000; // 70% outflow
}

function scoreToTier(score: number): number {
  if (score < 2500) return 0; // GREEN
  if (score < 5000) return 1; // YELLOW
  if (score < 7500) return 2; // ORANGE
  return 3; // RED
}

function encodeReportPayload(
  action: RiskResult["action"],
  params: {
    aaveHaircutBps: number;
    aaveConcentrationBps: number;
    aaveStressOutflowBps: number;
    aaveRiskTier: number;
    morphoHaircutBps: number;
    morphoConcentrationBps: number;
    morphoStressOutflowBps: number;
    morphoRiskTier: number;
    stressedLCR: number;
    systemStatus: number;
    aggregateRiskScore: number;
    timestampSec: number;
  },
  vault: VaultState
): string {
  // The encoding MUST match: abi.decode(report, (uint8, bytes))
  // where the inner bytes decode per action type as specified in StreamVault

  if (action === "NONE") {
    return "0x";
  }

  if (action === "UPDATE_PARAMS") {
    // actionData encoding: (address[] sources, SourceRiskParams[] params, RiskSnapshot snapshot)
    const sources = [vault.aaveSourceAddress, vault.morphoSourceAddress];

    // SourceRiskParams struct: (uint16, uint16, uint16, uint64, uint8)
    const aaveParams = {
      liquidityHaircutBps: params.aaveHaircutBps,
      stressOutflowBps: params.aaveStressOutflowBps,
      maxConcentrationBps: params.aaveConcentrationBps,
      lastUpdated: 0n, // Will be set by contract
      riskTier: params.aaveRiskTier,
    };
    const morphoParams = {
      liquidityHaircutBps: params.morphoHaircutBps,
      stressOutflowBps: params.morphoStressOutflowBps,
      maxConcentrationBps: params.morphoConcentrationBps,
      lastUpdated: 0n,
      riskTier: params.morphoRiskTier,
    };

    // RiskSnapshot struct: (uint256, uint256, uint64, uint8)
    const snapshot = {
      stressedLCR: BigInt(params.stressedLCR),
      aggregateRiskScore: BigInt(params.aggregateRiskScore),
      timestamp: BigInt(params.timestampSec),
      systemStatus: params.systemStatus,
    };

    // Encode the action data
    const actionData = encodeAbiParameters(
      parseAbiParameters(
        "address[] sources, (uint16 liquidityHaircutBps, uint16 stressOutflowBps, uint16 maxConcentrationBps, uint64 lastUpdated, uint8 riskTier)[] params, (uint256 stressedLCR, uint256 aggregateRiskScore, uint64 timestamp, uint8 systemStatus) snapshot"
      ),
      [
        sources as `0x${string}`[],
        [aaveParams, morphoParams],
        snapshot,
      ]
    );

    // Encode the full report: (uint8 action, bytes actionData)
    return encodeAbiParameters(parseAbiParameters("uint8 action, bytes data"), [
      ACTION_UPDATE_RISK_PARAMS,
      actionData,
    ]);
  }

  if (action === "REBALANCE") {
    // Pull from the riskier source
    const riskierSource =
      params.aaveRiskTier >= params.morphoRiskTier
        ? vault.aaveSourceAddress
        : vault.morphoSourceAddress;
    const sourceBalance =
      params.aaveRiskTier >= params.morphoRiskTier
        ? vault.aaveBalance
        : vault.morphoBalance;

    // Withdraw 50% of the risky source's balance
    const withdrawAmount = sourceBalance / 2n;

    const actionData = encodeAbiParameters(
      parseAbiParameters("address source, uint256 amount"),
      [riskierSource as `0x${string}`, withdrawAmount]
    );

    return encodeAbiParameters(parseAbiParameters("uint8 action, bytes data"), [
      ACTION_DEFENSIVE_REBALANCE,
      actionData,
    ]);
  }

  if (action === "EMERGENCY_PAUSE") {
    const severity = params.systemStatus >= 3 ? 1 : 0; // severity 1 = pause + unwind
    const actionData = encodeAbiParameters(
      parseAbiParameters("uint8 severity"),
      [severity]
    );

    return encodeAbiParameters(parseAbiParameters("uint8 action, bytes data"), [
      ACTION_EMERGENCY_PAUSE,
      actionData,
    ]);
  }

  return "0x";
}
