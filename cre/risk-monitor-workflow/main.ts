/**
 * StreamVault CRE Risk Monitor Workflow
 *
 * A decentralized risk oracle powered by Chainlink CRE that:
 * 1. Monitors real-time health metrics from yield sources (Aave V3, Morpho)
 * 2. Computes stress scenarios using Basel III-inspired LCR model
 * 3. Writes updated risk parameters and defensive actions back to StreamVault
 *
 * This runs deterministically across the DON with BFT consensus.
 */

import {
  cre,
  Runner,
  getNetwork,
  hexToBase64,
  bytesToHex,
  TxStatus,
  type Runtime,
  type CronPayload,
} from "@chainlink/cre-sdk";
import { computeRiskModel } from "./risk-model";
import { readProtocolHealth, readVaultState } from "./protocol-readers";

// ═══════════════════════════════════════════════════════════════════════════
// Config Type
// ═══════════════════════════════════════════════════════════════════════════

export type Config = {
  /** Cron expression: "0 *\/5 * * * *" (every 5 min) */
  schedule: string;
  /** Chain selector name e.g. "ethereum-testnet-sepolia-base-1" */
  chainSelectorName: string;
  /** Whether the target chain is a testnet */
  isTestnet: boolean;
  /** StreamVault contract address */
  vaultAddress: string;
  /** AaveV3YieldSource adapter address */
  aaveSourceAddress: string;
  /** MorphoYieldSource adapter address */
  morphoSourceAddress: string;
  /** Gas limit for onReport() transaction */
  gasLimit: string;
};

// ═══════════════════════════════════════════════════════════════════════════
// Workflow Initialization — registers cron trigger
// ═══════════════════════════════════════════════════════════════════════════

const initWorkflow = (config: Config) => {
  const cronCap = new cre.capabilities.CronCapability();
  return [
    cre.handler(
      cronCap.trigger({ schedule: config.schedule }),
      onRiskCheck
    ),
  ];
};

// ═══════════════════════════════════════════════════════════════════════════
// Workflow Entry Point
// ═══════════════════════════════════════════════════════════════════════════

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
main();

// ═══════════════════════════════════════════════════════════════════════════
// Main Risk Check Callback — executes on every DON cron tick
// ═══════════════════════════════════════════════════════════════════════════

const onRiskCheck = (
  runtime: Runtime<Config>,
  _payload: CronPayload
): string => {
  const config = runtime.config;

  runtime.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  runtime.log("CRE Risk Monitor: Starting health check");
  runtime.log(`  Execution time: ${runtime.now().toISOString()}`);
  runtime.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

  // Resolve chain selector (bigint) from the human-readable name
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: config.chainSelectorName,
    isTestnet: config.isTestnet,
  });

  if (!network) {
    runtime.log(`[ERROR] Unknown chain: ${config.chainSelectorName}`);
    return "error_unknown_chain";
  }

  const evmClient = new cre.capabilities.EVMClient(
    network.chainSelector.selector
  );

  // ─── Step 1: Read on-chain state ────────────────────────────────────
  runtime.log("[Step 1] Reading protocol health metrics...");

  const protocolHealth = readProtocolHealth(runtime, evmClient, config);
  const vaultState = readVaultState(runtime, evmClient, config);

  runtime.log(`  Aave utilization: ${protocolHealth.aaveUtilizationBps} bps`);
  runtime.log(`  Aave liquidity:   ${protocolHealth.aaveAvailableLiquidity}`);
  runtime.log(`  Morpho utilization: ${protocolHealth.morphoUtilizationBps} bps`);
  runtime.log(`  Morpho liquidity:   ${protocolHealth.morphoAvailableLiquidity}`);
  runtime.log(`  Vault TVL:          ${vaultState.totalAssets}`);
  runtime.log(`  Aave balance:       ${vaultState.aaveBalance}`);
  runtime.log(`  Morpho balance:     ${vaultState.morphoBalance}`);
  runtime.log(`  Idle balance:       ${vaultState.idleBalance}`);
  runtime.log(`  Pending withdrawals: ${vaultState.pendingWithdrawals}`);

  // ─── Step 2: Compute risk model ─────────────────────────────────────
  runtime.log("[Step 2] Computing risk model...");

  const nowUnixSeconds = Math.floor(runtime.now().getTime() / 1000);
  const riskResult = computeRiskModel(protocolHealth, vaultState, nowUnixSeconds);

  const statusLabels = ["GREEN", "YELLOW", "ORANGE", "RED"];
  runtime.log(`  Aave risk score:  ${riskResult.sourceScores.aave}/10000`);
  runtime.log(`  Morpho risk score: ${riskResult.sourceScores.morpho}/10000`);
  runtime.log(`  Stressed LCR:     ${riskResult.stressedLCR} bps`);
  runtime.log(`  System status:    ${statusLabels[riskResult.systemStatus]}`);
  runtime.log(`  Decided action:   ${riskResult.action}`);
  runtime.log(`  New params:`);
  runtime.log(`    Aave haircut:        ${riskResult.newParams.aaveHaircutBps} bps`);
  runtime.log(`    Aave concentration:  ${riskResult.newParams.aaveConcentrationBps} bps`);
  runtime.log(`    Morpho haircut:      ${riskResult.newParams.morphoHaircutBps} bps`);
  runtime.log(`    Morpho concentration: ${riskResult.newParams.morphoConcentrationBps} bps`);

  // ─── Step 3: Generate signed report if action needed ─────────────────
  if (riskResult.action === "NONE") {
    runtime.log("[Step 3] No action needed. System healthy.");
    return "healthy";
  }

  runtime.log(`[Step 3] Generating DON-signed report for: ${riskResult.action}`);

  // The encodedPayload is ABI-encoded hex (0x-prefixed) from the risk model.
  // It matches the Solidity decoding: abi.decode(report, (uint8, bytes))
  // We convert hex -> base64 for the CRE report API.
  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(riskResult.encodedPayload),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result();

  // ─── Step 4: Submit report on-chain via Forwarder ────────────────────
  runtime.log("[Step 4] Submitting report to vault via KeystoneForwarder...");
  runtime.log(`  Target: ${config.vaultAddress}`);

  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: config.vaultAddress,
      report: reportResponse,
      gasConfig: { gasLimit: config.gasLimit },
    })
    .result();

  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    runtime.log(
      `[ERROR] Transaction failed: ${writeResult.errorMessage || "unknown error"}`
    );
    runtime.log(`  Status: ${writeResult.txStatus}`);
    return "error_tx_failed";
  }

  const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32));
  runtime.log(`[Complete] Transaction successful!`);
  runtime.log(`  TX Hash: ${txHash}`);
  runtime.log(`  Action:  ${riskResult.action}`);

  return "action_taken";
};
