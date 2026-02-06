// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StreamVault} from "../src/StreamVault.sol";
import {AaveV3YieldSource} from "../src/AaveV3YieldSource.sol";
import {MorphoBlueYieldSource, MarketParams} from "../src/MorphoBlueYieldSource.sol";

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
///   VAULT_NAME           - ERC-20 name (default: "StreamVault")
///   VAULT_SYMBOL         - ERC-20 symbol (default: "svTOKEN")
///
/// Aave adapter (optional):
///   AAVE_POOL            - Aave V3 Pool address
///   AAVE_ATOKEN          - aToken address for the asset
///
/// Morpho Blue adapter — direct market supply (optional):
///   MORPHO_BLUE              - Morpho Blue core address
///   MORPHO_BLUE_COLLATERAL   - Collateral token for the market
///   MORPHO_BLUE_ORACLE       - Oracle address (optional, default: address(0))
///   MORPHO_BLUE_IRM          - IRM address (optional, default: address(0))
///   MORPHO_BLUE_LLTV         - LLTV value (optional, default: 0)
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

        string memory vaultName = vm.envOr("VAULT_NAME", string("StreamVault"));
        string memory vaultSymbol = vm.envOr("VAULT_SYMBOL", string("svTOKEN"));

        console.log("=== StreamVault Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Asset:", asset);
        console.log("Operator:", operatorAddr);
        console.log("Fee Recipient:", feeRecipient);
        console.log("Performance Fee (bps):", performanceFeeBps);
        console.log("Management Fee (bps):", managementFeeBps);

        // ─── Deploy Vault ───────────────────────────────────────────────────

        vm.startBroadcast(deployerKey);

        // Deploy implementation (constructor disables initializers)
        StreamVault implementation = new StreamVault();
        console.log("StreamVault implementation:", address(implementation));

        // Deploy UUPS proxy with initialize calldata
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (IERC20(asset), operatorAddr, feeRecipient, performanceFeeBps, managementFeeBps, vaultName, vaultSymbol)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        StreamVault vault = StreamVault(address(proxy));

        console.log("StreamVault proxy:", address(vault));

        // ─── Deploy Aave Adapter (optional) ─────────────────────────────────

        address aavePool = vm.envOr("AAVE_POOL", address(0));
        if (aavePool != address(0)) {
            address aaveAToken = vm.envAddress("AAVE_ATOKEN");

            AaveV3YieldSource aaveAdapter = new AaveV3YieldSource(asset, aavePool, aaveAToken, address(vault));

            console.log("AaveV3YieldSource deployed at:", address(aaveAdapter));

            // Note: Operator must call vault.addYieldSource(aaveAdapter) after deployment
        }

        // ─── Deploy Morpho Blue Adapter (optional) ─────────────────────────

        _deployMorphoBlue(asset, address(vault));

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

    function _deployMorphoBlue(address asset, address vault) internal {
        address morphoBlue = vm.envOr("MORPHO_BLUE", address(0));
        if (morphoBlue == address(0)) return;

        MarketParams memory marketParams = MarketParams({
            loanToken: asset,
            collateralToken: vm.envAddress("MORPHO_BLUE_COLLATERAL"),
            oracle: vm.envOr("MORPHO_BLUE_ORACLE", address(0)),
            irm: vm.envOr("MORPHO_BLUE_IRM", address(0)),
            lltv: vm.envOr("MORPHO_BLUE_LLTV", uint256(0))
        });

        MorphoBlueYieldSource morphoBlueAdapter = new MorphoBlueYieldSource(morphoBlue, marketParams, vault);
        console.log("MorphoBlueYieldSource deployed at:", address(morphoBlueAdapter));

        // Note: Operator must call vault.addYieldSource(morphoBlueAdapter) after deployment
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

        StreamVault implementation = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (IERC20(usdc), operatorAddr, operatorAddr, 1_000, 200, "StreamVault USDC (Sepolia)", "svUSDC")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        StreamVault vault = StreamVault(address(proxy));

        console.log("StreamVault implementation:", address(implementation));
        console.log("StreamVault proxy:", address(vault));

        vm.stopBroadcast();
    }
}
