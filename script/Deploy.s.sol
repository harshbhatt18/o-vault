// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StreamVault} from "../src/StreamVault.sol";
import {AaveV3YieldSource} from "../src/AaveV3YieldSource.sol";
import {MorphoYieldSource} from "../src/MorphoYieldSource.sol";

/// @title Deploy StreamVault
/// @notice Deployment script for StreamVault and optional yield source adapters.
/// @dev Run with: forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast --verify
///
/// Required environment variables:
///   PRIVATE_KEY        - Deployer private key
///   ASSET_ADDRESS      - Underlying asset (e.g., USDC)
///   OPERATOR_ADDRESS   - Operator/keeper address
///   FEE_RECIPIENT      - Address to receive fees (optional, defaults to operator)
///
/// Optional environment variables:
///   PERFORMANCE_FEE_BPS  - Performance fee in bps (default: 1000 = 10%)
///   MANAGEMENT_FEE_BPS   - Annual management fee in bps (default: 200 = 2%)
///   SMOOTHING_PERIOD     - EMA smoothing period in seconds (default: 3600 = 1 hour)
///   VAULT_NAME           - ERC-20 name (default: "StreamVault")
///   VAULT_SYMBOL         - ERC-20 symbol (default: "svTOKEN")
///
/// Aave adapter (optional):
///   AAVE_POOL            - Aave V3 Pool address
///   AAVE_ATOKEN          - aToken address for the asset
///
/// Morpho adapter (optional):
///   MORPHO_VAULT         - MetaMorpho vault address
contract DeployStreamVault is Script {
    function run() external {
        // ─── Load Configuration ─────────────────────────────────────────────

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address asset = vm.envAddress("ASSET_ADDRESS");
        address operatorAddr = vm.envAddress("OPERATOR_ADDRESS");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", operatorAddr);

        uint256 performanceFeeBps = vm.envOr("PERFORMANCE_FEE_BPS", uint256(1_000));
        uint256 managementFeeBps = vm.envOr("MANAGEMENT_FEE_BPS", uint256(200));
        uint256 smoothingPeriod = vm.envOr("SMOOTHING_PERIOD", uint256(3_600));

        string memory vaultName = vm.envOr("VAULT_NAME", string("StreamVault"));
        string memory vaultSymbol = vm.envOr("VAULT_SYMBOL", string("svTOKEN"));

        console.log("=== StreamVault Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Asset:", asset);
        console.log("Operator:", operatorAddr);
        console.log("Fee Recipient:", feeRecipient);
        console.log("Performance Fee (bps):", performanceFeeBps);
        console.log("Management Fee (bps):", managementFeeBps);
        console.log("Smoothing Period (s):", smoothingPeriod);

        // ─── Deploy Vault ───────────────────────────────────────────────────

        vm.startBroadcast(deployerKey);

        StreamVault vault = new StreamVault(
            IERC20(asset),
            operatorAddr,
            feeRecipient,
            performanceFeeBps,
            managementFeeBps,
            smoothingPeriod,
            vaultName,
            vaultSymbol
        );

        console.log("StreamVault deployed at:", address(vault));

        // ─── Deploy Aave Adapter (optional) ─────────────────────────────────

        address aavePool = vm.envOr("AAVE_POOL", address(0));
        if (aavePool != address(0)) {
            address aaveAToken = vm.envAddress("AAVE_ATOKEN");

            AaveV3YieldSource aaveAdapter = new AaveV3YieldSource(asset, aavePool, aaveAToken, address(vault));

            console.log("AaveV3YieldSource deployed at:", address(aaveAdapter));

            // Note: Operator must call vault.addYieldSource(aaveAdapter) after deployment
        }

        // ─── Deploy Morpho Adapter (optional) ───────────────────────────────

        address morphoVault = vm.envOr("MORPHO_VAULT", address(0));
        if (morphoVault != address(0)) {
            MorphoYieldSource morphoAdapter = new MorphoYieldSource(morphoVault, address(vault));

            console.log("MorphoYieldSource deployed at:", address(morphoAdapter));

            // Note: Operator must call vault.addYieldSource(morphoAdapter) after deployment
        }

        vm.stopBroadcast();

        // ─── Post-Deployment Checklist ──────────────────────────────────────

        console.log("");
        console.log("=== Post-Deployment Checklist ===");
        console.log("1. Verify contracts on block explorer");
        console.log("2. Operator: call vault.addYieldSource() for each adapter");
        console.log("3. Test deposit/withdraw flow on testnet before mainnet");
        console.log("4. Set up monitoring for vault events");
        console.log("5. Document operator runbook (settlement cadence, harvest timing)");
    }
}

/// @title Deploy to Testnet (Sepolia)
/// @notice Pre-configured deployment for Sepolia testnet
contract DeploySepolia is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address operatorAddr = vm.envAddress("OPERATOR_ADDRESS");

        // Sepolia USDC (Circle testnet faucet)
        address usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

        console.log("=== Sepolia Testnet Deployment ===");

        vm.startBroadcast(deployerKey);

        StreamVault vault = new StreamVault(
            IERC20(usdc),
            operatorAddr,
            operatorAddr, // feeRecipient = operator for testnet
            1_000, // 10% performance fee
            200, // 2% management fee
            3_600, // 1 hour smoothing
            "StreamVault USDC (Sepolia)",
            "svUSDC"
        );

        console.log("StreamVault (Sepolia):", address(vault));

        vm.stopBroadcast();
    }
}
