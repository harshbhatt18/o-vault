// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StreamVault} from "../src/StreamVault.sol";
import {AaveV3YieldSource} from "../src/AaveV3YieldSource.sol";
import {MorphoBlueYieldSource, MarketParams, IMorphoBlue} from "../src/MorphoBlueYieldSource.sol";
import {IYieldSource} from "../src/IYieldSource.sol";

/// @title Deploy StreamVault to Base Sepolia
/// @notice Deploys the full StreamVault system with:
///         - Real Aave V3 integration (Base Sepolia deployment)
///         - Real Morpho Blue integration (direct market supply)
///         - CRE forwarder configured
///         - LCR floor set
///
/// @dev Run with:
///   source .env
///   forge script script/DeployBaseSepolia.s.sol --rpc-url base_sepolia --broadcast
contract DeployBaseSepolia is Script {
    // ─── Base Sepolia Addresses ──────────────────────────────────────────
    address constant USDC = 0xba50Cd2A20f6DA35D788639E581bca8d0B5d4D5f;
    address constant AAVE_POOL = 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27;
    address constant AAVE_AUSDC = 0x10F1A9D11CDf50041f3f8cB7191CBE2f31750ACC;
    address constant CRE_FORWARDER = 0x82300bd7c3958625581cc2F77bC6464dcEcDF3e5;

    // Morpho Blue core — deterministic CREATE2 address (same on all chains)
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // WETH on Base Sepolia (OP Stack standard)
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("==============================================");
        console.log("  StreamVault Base Sepolia Deployment");
        console.log("==============================================");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ─── 1. Deploy StreamVault (UUPS Proxy) ───────────────────────────
        StreamVault implementation = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (
                IERC20(USDC),
                deployer, // operator = deployer for testnet
                deployer, // feeRecipient = deployer for testnet
                1_000, // 10% performance fee
                200, // 2% annual management fee
                3_600, // 1 hour EMA smoothing
                "StreamVault USDC (Base Sepolia)",
                "svUSDC"
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        StreamVault vault = StreamVault(address(proxy));
        console.log("[1/8] StreamVault implementation:", address(implementation));
        console.log("[1/8] StreamVault proxy:", address(vault));

        // ─── 2. Deploy AaveV3YieldSource ─────────────────────────────────
        AaveV3YieldSource aaveSource = new AaveV3YieldSource(USDC, AAVE_POOL, AAVE_AUSDC, address(vault));
        console.log("[2/8] AaveV3YieldSource deployed:", address(aaveSource));

        // ─── 3. Create Morpho Blue Market ────────────────────────────────
        // LLTV=0 and IRM=address(0) are both enabled by default in Morpho Blue.
        // LLTV=0 → supply-only market (no borrowing possible).
        // IRM=address(0) → 0% interest rate (sufficient for testnet demonstration).
        MarketParams memory morphoMarketParams =
            MarketParams({loanToken: USDC, collateralToken: WETH, oracle: address(0), irm: address(0), lltv: 0});

        // createMarket reverts if the market already exists, so wrap in try-catch
        try IMorphoBlue(MORPHO_BLUE).createMarket(morphoMarketParams) {
            console.log("[3/8] Morpho Blue market created");
        } catch {
            console.log("[3/8] Morpho Blue market already exists");
        }

        // ─── 4. Deploy MorphoBlueYieldSource ─────────────────────────────
        MorphoBlueYieldSource morphoSource = new MorphoBlueYieldSource(MORPHO_BLUE, morphoMarketParams, address(vault));
        console.log("[4/8] MorphoBlueYieldSource deployed:", address(morphoSource));

        // ─── 5. Register yield sources ───────────────────────────────────
        vault.addYieldSource(IYieldSource(address(aaveSource)));
        console.log("[5/8] Aave source registered");

        vault.addYieldSource(IYieldSource(address(morphoSource)));
        console.log("[6/8] Morpho Blue source registered");

        // ─── 6. Configure CRE ────────────────────────────────────────────
        // For testnet: set deployer as forwarder so we can simulate CRE reports
        vault.setChainlinkForwarder(deployer);
        console.log("[7/8] CRE Forwarder set to deployer (for testing)");

        // Set LCR floor at 120%
        vault.setLCRFloor(12_000);
        console.log("[8/8] LCR floor set to 120% (12000 bps)");

        vm.stopBroadcast();

        // ─── Summary ────────────────────────────────────────────────────
        console.log("");
        console.log("==============================================");
        console.log("  Deployment Complete!");
        console.log("==============================================");
        console.log("");
        console.log("  VAULT_ADDRESS=", address(vault));
        console.log("  AAVE_SOURCE_ADDRESS=", address(aaveSource));
        console.log("  MORPHO_BLUE_SOURCE_ADDRESS=", address(morphoSource));
        console.log("  MORPHO_BLUE_MARKET_ID=");
        console.logBytes32(morphoSource.MARKET_ID());
        console.log("");
        console.log("View on BaseScan:");
        console.log("  https://sepolia.basescan.org/address/", address(vault));
    }
}
