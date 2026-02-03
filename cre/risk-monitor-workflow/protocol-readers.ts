/**
 * Protocol Readers for CRE Risk Monitor
 *
 * Uses CRE EVMClient for on-chain reads with DON consensus.
 * Each read goes through DON consensus — multiple nodes read independently, results verified.
 *
 * Uses encodeCallMsg() to structure the call and bytesToHex() to decode the Uint8Array result.
 */

import {
  cre,
  encodeCallMsg,
  LAST_FINALIZED_BLOCK_NUMBER,
  bytesToHex,
  type Runtime,
} from "@chainlink/cre-sdk";

type EVMClient = InstanceType<typeof cre.capabilities.EVMClient>;
import { encodeFunctionData, decodeFunctionResult } from "viem";
import type { ProtocolHealth, VaultState } from "./risk-model";

// Zero address used as `from` for read-only calls
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

// ═══════════════════════════════════════════════════════════════════════════
// ABI Definitions (minimal for the functions we need)
// ═══════════════════════════════════════════════════════════════════════════

const YIELD_SOURCE_ABI = [
  {
    name: "getPoolUtilization",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "utilizationBps", type: "uint256" }],
  },
  {
    name: "getAvailableLiquidity",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "liquidity", type: "uint256" }],
  },
  {
    name: "getMarketUtilization",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "utilizationBps", type: "uint256" }],
  },
] as const;

const STREAM_VAULT_ABI = [
  {
    name: "totalAssets",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "assets", type: "uint256" }],
  },
  {
    name: "getSourceBalance",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "source", type: "address" }],
    outputs: [{ name: "balance", type: "uint256" }],
  },
  {
    name: "idleBalance",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "balance", type: "uint256" }],
  },
  {
    name: "getPendingEpochWithdrawals",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "pending", type: "uint256" }],
  },
  {
    name: "getCurrentEpochInfo",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "epochId", type: "uint256" },
      { name: "startTime", type: "uint256" },
      { name: "minDuration", type: "uint256" },
    ],
  },
] as const;

// ═══════════════════════════════════════════════════════════════════════════
// Helper: Execute a contract read via CRE EVMClient
// ═══════════════════════════════════════════════════════════════════════════

function callContractRead(
  runtime: Runtime<any>,
  evmClient: EVMClient,
  contractAddress: string,
  calldata: `0x${string}`
): `0x${string}` {
  const result = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: ZERO_ADDRESS,
        to: contractAddress as `0x${string}`,
        data: calldata,
      }),
      blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
    })
    .result();

  // result.data is Uint8Array — convert to hex for viem decoding
  return bytesToHex(result.data) as `0x${string}`;
}

// ═══════════════════════════════════════════════════════════════════════════
// Protocol Health Reader
// ═══════════════════════════════════════════════════════════════════════════

export function readProtocolHealth(
  runtime: Runtime<any>,
  evmClient: EVMClient,
  config: any
): ProtocolHealth {
  runtime.log("  Reading Aave V3 yield source metrics...");

  // Read Aave utilization from our yield source adapter
  const aaveUtilHex = callContractRead(
    runtime,
    evmClient,
    config.aaveSourceAddress,
    encodeFunctionData({
      abi: YIELD_SOURCE_ABI,
      functionName: "getPoolUtilization",
    })
  );
  const aaveUtilizationBps = Number(
    decodeFunctionResult({
      abi: YIELD_SOURCE_ABI,
      functionName: "getPoolUtilization",
      data: aaveUtilHex,
    })
  );

  // Read Aave available liquidity
  const aaveLiquidityHex = callContractRead(
    runtime,
    evmClient,
    config.aaveSourceAddress,
    encodeFunctionData({
      abi: YIELD_SOURCE_ABI,
      functionName: "getAvailableLiquidity",
    })
  );
  const aaveAvailableLiquidity = decodeFunctionResult({
    abi: YIELD_SOURCE_ABI,
    functionName: "getAvailableLiquidity",
    data: aaveLiquidityHex,
  }) as bigint;

  runtime.log("  Reading Morpho vault metrics...");

  // Read Morpho utilization from our yield source adapter
  const morphoUtilHex = callContractRead(
    runtime,
    evmClient,
    config.morphoSourceAddress,
    encodeFunctionData({
      abi: YIELD_SOURCE_ABI,
      functionName: "getMarketUtilization",
    })
  );
  const morphoUtilizationBps = Number(
    decodeFunctionResult({
      abi: YIELD_SOURCE_ABI,
      functionName: "getMarketUtilization",
      data: morphoUtilHex,
    })
  );

  // Read Morpho available liquidity
  const morphoLiquidityHex = callContractRead(
    runtime,
    evmClient,
    config.morphoSourceAddress,
    encodeFunctionData({
      abi: YIELD_SOURCE_ABI,
      functionName: "getAvailableLiquidity",
    })
  );
  const morphoAvailableLiquidity = decodeFunctionResult({
    abi: YIELD_SOURCE_ABI,
    functionName: "getAvailableLiquidity",
    data: morphoLiquidityHex,
  }) as bigint;

  return {
    aaveUtilizationBps,
    aaveAvailableLiquidity,
    aaveOracleDeviation: 0, // Would come from Chainlink price feed comparison
    morphoUtilizationBps,
    morphoAvailableLiquidity,
    morphoMatchingRateBps: 10000, // MetaMorpho doesn't expose matching rate
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Vault State Reader
// ═══════════════════════════════════════════════════════════════════════════

export function readVaultState(
  runtime: Runtime<any>,
  evmClient: EVMClient,
  config: any
): VaultState {
  runtime.log("  Reading StreamVault state...");

  // Read total assets
  const totalAssetsHex = callContractRead(
    runtime,
    evmClient,
    config.vaultAddress,
    encodeFunctionData({
      abi: STREAM_VAULT_ABI,
      functionName: "totalAssets",
    })
  );
  const totalAssets = decodeFunctionResult({
    abi: STREAM_VAULT_ABI,
    functionName: "totalAssets",
    data: totalAssetsHex,
  }) as bigint;

  // Read Aave balance
  const aaveBalanceHex = callContractRead(
    runtime,
    evmClient,
    config.vaultAddress,
    encodeFunctionData({
      abi: STREAM_VAULT_ABI,
      functionName: "getSourceBalance",
      args: [config.aaveSourceAddress as `0x${string}`],
    })
  );
  const aaveBalance = decodeFunctionResult({
    abi: STREAM_VAULT_ABI,
    functionName: "getSourceBalance",
    data: aaveBalanceHex,
  }) as bigint;

  // Read Morpho balance
  const morphoBalanceHex = callContractRead(
    runtime,
    evmClient,
    config.vaultAddress,
    encodeFunctionData({
      abi: STREAM_VAULT_ABI,
      functionName: "getSourceBalance",
      args: [config.morphoSourceAddress as `0x${string}`],
    })
  );
  const morphoBalance = decodeFunctionResult({
    abi: STREAM_VAULT_ABI,
    functionName: "getSourceBalance",
    data: morphoBalanceHex,
  }) as bigint;

  // Read idle balance
  const idleBalanceHex = callContractRead(
    runtime,
    evmClient,
    config.vaultAddress,
    encodeFunctionData({
      abi: STREAM_VAULT_ABI,
      functionName: "idleBalance",
    })
  );
  const idleBalance = decodeFunctionResult({
    abi: STREAM_VAULT_ABI,
    functionName: "idleBalance",
    data: idleBalanceHex,
  }) as bigint;

  // Read pending withdrawals
  const pendingHex = callContractRead(
    runtime,
    evmClient,
    config.vaultAddress,
    encodeFunctionData({
      abi: STREAM_VAULT_ABI,
      functionName: "getPendingEpochWithdrawals",
    })
  );
  const pendingWithdrawals = decodeFunctionResult({
    abi: STREAM_VAULT_ABI,
    functionName: "getPendingEpochWithdrawals",
    data: pendingHex,
  }) as bigint;

  // Read epoch info
  const epochInfoHex = callContractRead(
    runtime,
    evmClient,
    config.vaultAddress,
    encodeFunctionData({
      abi: STREAM_VAULT_ABI,
      functionName: "getCurrentEpochInfo",
    })
  );
  const [_epochId, startTime, minDuration] = decodeFunctionResult({
    abi: STREAM_VAULT_ABI,
    functionName: "getCurrentEpochInfo",
    data: epochInfoHex,
  }) as [bigint, bigint, bigint];

  return {
    totalAssets,
    aaveBalance,
    morphoBalance,
    idleBalance,
    pendingWithdrawals,
    currentEpochStart: Number(startTime),
    epochMinDuration: Number(minDuration),
    aaveSourceAddress: config.aaveSourceAddress,
    morphoSourceAddress: config.morphoSourceAddress,
  };
}
