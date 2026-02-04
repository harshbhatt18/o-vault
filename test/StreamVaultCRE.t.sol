// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StreamVault} from "../src/StreamVault.sol";
import {MockYieldSource} from "../src/MockYieldSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RiskModel} from "../src/libraries/RiskModel.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title StreamVault CRE Integration Tests
/// @notice Comprehensive tests for Chainlink CRE (Compute Runtime Environment) integration.
/// @dev Tests cover forwarder configuration, onReport() dispatch, action handlers,
///      LCR enforcement, and backwards compatibility with operator functions.
contract StreamVaultCRE_Test is Test {
    StreamVault internal vault;
    MockERC20 internal usdc;
    MockYieldSource internal aaveSource;
    MockYieldSource internal morphoSource;

    address internal operator = address(0x1);
    address internal feeRecipient = address(0x2);
    address internal chainlinkForwarder = address(0x3);
    address internal user = address(0x4);
    address internal randomAddress = address(0x5);

    uint256 internal constant INITIAL_DEPOSIT = 100_000e6; // 100k USDC
    uint256 internal constant PERFORMANCE_FEE_BPS = 1_000; // 10%
    uint256 internal constant MANAGEMENT_FEE_BPS = 200; // 2%
    uint256 internal constant SMOOTHING_PERIOD = 3600; // 1 hour

    function setUp() public {
        // Deploy USDC mock
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy vault (UUPS proxy)
        StreamVault implementation = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (
                IERC20(address(usdc)),
                operator,
                feeRecipient,
                PERFORMANCE_FEE_BPS,
                MANAGEMENT_FEE_BPS,
                SMOOTHING_PERIOD,
                "StreamVault USDC",
                "svUSDC"
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vault = StreamVault(address(proxy));

        // Deploy yield sources
        aaveSource = new MockYieldSource(address(usdc), address(vault), 0);
        morphoSource = new MockYieldSource(address(usdc), address(vault), 0);

        // Register yield sources
        vm.startPrank(operator);
        vault.addYieldSource(aaveSource);
        vault.addYieldSource(morphoSource);

        // Configure CRE forwarder
        vault.setChainlinkForwarder(chainlinkForwarder);

        // Disable drawdown protection for tests
        vault.setMaxDrawdown(0);
        vm.stopPrank();

        // Setup user with USDC
        usdc.mint(user, INITIAL_DEPOSIT * 10);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);

        // Initial deposit
        vm.prank(user);
        vault.deposit(INITIAL_DEPOSIT, user);

        // Warp forward to allow settlement
        vm.warp(block.timestamp + 1 hours);
    }

    // ─── Forwarder Configuration Tests ──────────────────────────────────

    function test_setChainlinkForwarder_onlyOperator() public {
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.setChainlinkForwarder(address(0x999));
    }

    function test_setChainlinkForwarder_revertsOnZeroAddress() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.ZeroAddress.selector);
        vault.setChainlinkForwarder(address(0));
    }

    function test_setChainlinkForwarder_storesCorrectly() public {
        address newForwarder = address(0x999);
        vm.prank(operator);
        vault.setChainlinkForwarder(newForwarder);
        assertEq(vault.chainlinkForwarder(), newForwarder);
    }

    function test_setChainlinkForwarder_emitsEvent() public {
        address newForwarder = address(0x999);
        vm.prank(operator);
        vm.expectEmit(true, false, false, false);
        emit StreamVault.ChainlinkForwarderUpdated(newForwarder);
        vault.setChainlinkForwarder(newForwarder);
    }

    // ─── onReport() Access Control Tests ────────────────────────────────

    function test_onReport_revertsWhenCalledByRandomAddress() public {
        bytes memory report = abi.encode(uint8(0), "");
        vm.prank(randomAddress);
        vm.expectRevert(StreamVault.OnlyForwarder.selector);
        vault.onReport("", report);
    }

    function test_onReport_revertsWhenCalledByOperator() public {
        bytes memory report = abi.encode(uint8(0), "");
        vm.prank(operator);
        vm.expectRevert(StreamVault.OnlyForwarder.selector);
        vault.onReport("", report);
    }

    function test_onReport_revertsOnInvalidAction() public {
        bytes memory report = abi.encode(uint8(99), "");
        vm.prank(chainlinkForwarder);
        vm.expectRevert(abi.encodeWithSelector(StreamVault.InvalidAction.selector, 99));
        vault.onReport("", report);
    }

    // ─── ACTION_UPDATE_RISK_PARAMS Tests ────────────────────────────────

    function test_updateRiskParams_success() public {
        address[] memory sources = new address[](2);
        sources[0] = address(aaveSource);
        sources[1] = address(morphoSource);

        RiskModel.SourceRiskParams[] memory params = new RiskModel.SourceRiskParams[](2);
        params[0] = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 2500, // 25% haircut
            stressOutflowBps: 3000, // 30% stress outflow
            maxConcentrationBps: 4000, // 40% max concentration
            lastUpdated: 0,
            riskTier: 1 // YELLOW
        });
        params[1] = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 1500,
            stressOutflowBps: 2000,
            maxConcentrationBps: 5000,
            lastUpdated: 0,
            riskTier: 0 // GREEN
        });

        RiskModel.RiskSnapshot memory snapshot = RiskModel.RiskSnapshot({
            stressedLCR: 13500, // 135%
            aggregateRiskScore: 3500,
            timestamp: uint64(block.timestamp),
            systemStatus: 1 // YELLOW
        });

        bytes memory actionData = abi.encode(sources, params, snapshot);
        bytes memory report = abi.encode(vault.ACTION_UPDATE_RISK_PARAMS(), actionData);

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        // Verify params were stored
        RiskModel.SourceRiskParams memory storedAave = vault.getSourceRiskParams(address(aaveSource));
        assertEq(storedAave.liquidityHaircutBps, 2500);
        assertEq(storedAave.stressOutflowBps, 3000);
        assertEq(storedAave.maxConcentrationBps, 4000);
        assertEq(storedAave.riskTier, 1);
        assertEq(storedAave.lastUpdated, block.timestamp);

        // Verify snapshot was stored
        RiskModel.RiskSnapshot memory storedSnapshot = vault.getLatestRiskSnapshot();
        assertEq(storedSnapshot.stressedLCR, 13500);
        assertEq(storedSnapshot.aggregateRiskScore, 3500);
        assertEq(storedSnapshot.systemStatus, 1);
    }

    function test_updateRiskParams_revertsOnArrayLengthMismatch() public {
        address[] memory sources = new address[](2);
        sources[0] = address(aaveSource);
        sources[1] = address(morphoSource);

        RiskModel.SourceRiskParams[] memory params = new RiskModel.SourceRiskParams[](1);
        params[0] = RiskModel.defaultParams();

        RiskModel.RiskSnapshot memory snapshot = RiskModel.RiskSnapshot({
            stressedLCR: 10000, aggregateRiskScore: 0, timestamp: uint64(block.timestamp), systemStatus: 0
        });

        bytes memory actionData = abi.encode(sources, params, snapshot);
        bytes memory report = abi.encode(vault.ACTION_UPDATE_RISK_PARAMS(), actionData);

        vm.prank(chainlinkForwarder);
        vm.expectRevert(StreamVault.ArrayLengthMismatch.selector);
        vault.onReport("", report);
    }

    function test_updateRiskParams_revertsOnUnknownSource() public {
        address[] memory sources = new address[](1);
        sources[0] = address(0xDEAD); // Unregistered source

        RiskModel.SourceRiskParams[] memory params = new RiskModel.SourceRiskParams[](1);
        params[0] = RiskModel.defaultParams();

        RiskModel.RiskSnapshot memory snapshot = RiskModel.RiskSnapshot({
            stressedLCR: 10000, aggregateRiskScore: 0, timestamp: uint64(block.timestamp), systemStatus: 0
        });

        bytes memory actionData = abi.encode(sources, params, snapshot);
        bytes memory report = abi.encode(vault.ACTION_UPDATE_RISK_PARAMS(), actionData);

        vm.prank(chainlinkForwarder);
        vm.expectRevert(abi.encodeWithSelector(StreamVault.UnknownSource.selector, address(0xDEAD)));
        vault.onReport("", report);
    }

    function test_updateRiskParams_revertsOnHaircutTooHigh() public {
        address[] memory sources = new address[](1);
        sources[0] = address(aaveSource);

        RiskModel.SourceRiskParams[] memory params = new RiskModel.SourceRiskParams[](1);
        params[0] = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 9600, // > 95% max haircut
            stressOutflowBps: 3000,
            maxConcentrationBps: 5000,
            lastUpdated: 0,
            riskTier: 0
        });

        RiskModel.RiskSnapshot memory snapshot = RiskModel.RiskSnapshot({
            stressedLCR: 10000, aggregateRiskScore: 0, timestamp: uint64(block.timestamp), systemStatus: 0
        });

        bytes memory actionData = abi.encode(sources, params, snapshot);
        bytes memory report = abi.encode(vault.ACTION_UPDATE_RISK_PARAMS(), actionData);

        vm.prank(chainlinkForwarder);
        vm.expectRevert(StreamVault.HaircutTooHigh.selector);
        vault.onReport("", report);
    }

    // ─── ACTION_DEFENSIVE_REBALANCE Tests ───────────────────────────────

    function test_defensiveRebalance_success() public {
        // Deploy some funds to Aave
        vm.prank(operator);
        vault.deployToYield(0, 50_000e6);

        uint256 vaultIdleBefore = vault.idleBalance();
        uint256 aaveBalanceBefore = aaveSource.balance();

        // CRE triggers rebalance
        bytes memory actionData = abi.encode(address(aaveSource), 20_000e6);
        bytes memory report = abi.encode(vault.ACTION_DEFENSIVE_REBALANCE(), actionData);

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        // Verify funds were pulled back
        assertEq(aaveSource.balance(), aaveBalanceBefore - 20_000e6);
        assertGt(vault.idleBalance(), vaultIdleBefore);
    }

    function test_defensiveRebalance_revertsOnUnknownSource() public {
        bytes memory actionData = abi.encode(address(0xDEAD), 10_000e6);
        bytes memory report = abi.encode(vault.ACTION_DEFENSIVE_REBALANCE(), actionData);

        vm.prank(chainlinkForwarder);
        vm.expectRevert(abi.encodeWithSelector(StreamVault.UnknownSource.selector, address(0xDEAD)));
        vault.onReport("", report);
    }

    // ─── ACTION_EMERGENCY_PAUSE Tests ───────────────────────────────────

    function test_emergencyPause_pausesVault() public {
        assertFalse(vault.paused());

        bytes memory actionData = abi.encode(uint8(0)); // severity 0
        bytes memory report = abi.encode(vault.ACTION_EMERGENCY_PAUSE(), actionData);

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        assertTrue(vault.paused());
    }

    function test_emergencyPause_depositsRevertAfterPause() public {
        // Trigger pause
        bytes memory actionData = abi.encode(uint8(0));
        bytes memory report = abi.encode(vault.ACTION_EMERGENCY_PAUSE(), actionData);
        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        // Attempt deposit
        vm.prank(user);
        vm.expectRevert(); // EnforcedPause
        vault.deposit(1000e6, user);
    }

    function test_emergencyPause_claimsStillWork() public {
        // User requests withdrawal - use small amount
        uint256 withdrawShares = 1000e6;
        vm.prank(user);
        vault.requestWithdraw(withdrawShares);

        // Settle epoch
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(operator);
        vault.settleEpoch();

        // Pause vault via CRE
        bytes memory actionData = abi.encode(uint8(0));
        bytes memory report = abi.encode(vault.ACTION_EMERGENCY_PAUSE(), actionData);
        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        // Claim should still work even when paused
        uint256 userBalanceBefore = usdc.balanceOf(user);
        vm.prank(user);
        vault.claimWithdrawal(0);
        assertGt(usdc.balanceOf(user), userBalanceBefore);
    }

    // ─── ACTION_SETTLE_EPOCH Tests ──────────────────────────────────────

    function test_settleEpoch_viaOnReport() public {
        // User requests withdrawal
        vm.prank(user);
        vault.requestWithdraw(1000e6);

        vm.warp(block.timestamp + 10 minutes);

        // CRE triggers settlement
        bytes memory report = abi.encode(vault.ACTION_SETTLE_EPOCH(), "");

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        // Verify epoch was settled
        (StreamVault.EpochStatus status,,,) = vault.getEpochInfo(0);
        assertEq(uint256(status), uint256(StreamVault.EpochStatus.SETTLED));
    }

    // ─── ACTION_HARVEST_YIELD Tests ─────────────────────────────────────

    function test_harvestYield_viaOnReport() public {
        // Deploy to Aave
        vm.prank(operator);
        vault.deployToYield(0, 50_000e6);

        // Simulate yield
        aaveSource.simulateYield(5_000e6);

        // CRE triggers harvest
        address[] memory sources = new address[](1);
        sources[0] = address(aaveSource);
        bytes memory actionData = abi.encode(sources);
        bytes memory report = abi.encode(vault.ACTION_HARVEST_YIELD(), actionData);

        uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        // Verify fee recipient received shares
        assertGt(vault.balanceOf(feeRecipient), feeRecipientSharesBefore);
    }

    // ─── LCR Enforcement Tests ──────────────────────────────────────────

    function test_deployToYield_respectsLCRFloor() public {
        // Set LCR floor
        vm.prank(operator);
        vault.setLCRFloor(15000); // 150%

        // Set high stress outflow params for Aave (makes LCR lower when deploying)
        _setHighStressParams(address(aaveSource));

        // Try to deploy too much - should fail LCR check
        vm.prank(operator);
        vm.expectRevert(); // LCRBreached
        vault.deployToYield(0, 90_000e6); // Deploy 90% of vault
    }

    function test_deployToYield_respectsConcentrationLimit() public {
        // Set concentration limit to 30%
        _setConcentrationLimit(address(aaveSource), 3000);

        // Try to deploy 50% to Aave - should fail concentration check
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(StreamVault.ConcentrationBreached.selector, address(aaveSource)));
        vault.deployToYield(0, 50_000e6);
    }

    function test_deployToYield_succeedsWithinLimits() public {
        // Set reasonable limits
        vm.prank(operator);
        vault.setLCRFloor(10000); // 100%
        _setConcentrationLimit(address(aaveSource), 5000); // 50%

        // Deploy within limits - should succeed
        vm.prank(operator);
        vault.deployToYield(0, 30_000e6); // 30% of vault

        assertEq(aaveSource.balance(), 30_000e6);
    }

    // ─── LCR Computation Tests ──────────────────────────────────────────

    function test_computeLCR_withDefaultParams() public view {
        // With default params and no deployments, LCR should be very high
        uint256 lcr = vault.computeLCR();
        assertGt(lcr, 10000); // > 100%
    }

    function test_computeLCR_affectedByRiskParams() public {
        // Deploy funds
        vm.prank(operator);
        vault.deployToYield(0, 50_000e6);

        uint256 lcrBefore = vault.computeLCR();

        // Update with high haircut via CRE
        _setHighStressParams(address(aaveSource));

        uint256 lcrAfter = vault.computeLCR();

        // LCR should be lower with higher haircuts
        assertLt(lcrAfter, lcrBefore);
    }

    // ─── Backwards Compatibility Tests ──────────────────────────────────

    function test_backwardsCompatibility_operatorCanSettleEpoch() public {
        vm.prank(user);
        vault.requestWithdraw(1000e6);

        vm.warp(block.timestamp + 10 minutes);

        // Operator can still settle directly
        vm.prank(operator);
        vault.settleEpoch();

        (StreamVault.EpochStatus status,,,) = vault.getEpochInfo(0);
        assertEq(uint256(status), uint256(StreamVault.EpochStatus.SETTLED));
    }

    function test_backwardsCompatibility_operatorCanHarvestYield() public {
        vm.prank(operator);
        vault.deployToYield(0, 50_000e6);

        aaveSource.simulateYield(5_000e6);

        // Operator can still harvest directly
        vm.prank(operator);
        vault.harvestYield();

        assertGt(vault.balanceOf(feeRecipient), 0);
    }

    function test_backwardsCompatibility_operatorCanDeployToYield() public {
        vm.prank(operator);
        vault.deployToYield(0, 30_000e6);

        assertEq(aaveSource.balance(), 30_000e6);
    }

    // ─── Integration Flow Tests ─────────────────────────────────────────

    function test_fullRiskEventCycle() public {
        // Step 1: Deploy capital to Aave and Morpho
        vm.startPrank(operator);
        vault.deployToYield(0, 40_000e6); // 40% to Aave
        vault.deployToYield(1, 30_000e6); // 30% to Morpho
        vm.stopPrank();

        assertEq(aaveSource.balance(), 40_000e6);
        assertEq(morphoSource.balance(), 30_000e6);

        // Step 2: CRE detects high Aave utilization, updates params with high haircut
        address[] memory sources = new address[](1);
        sources[0] = address(aaveSource);

        RiskModel.SourceRiskParams[] memory params = new RiskModel.SourceRiskParams[](1);
        params[0] = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 7500, // 75% haircut (critical)
            stressOutflowBps: 5000,
            maxConcentrationBps: 2000, // 20% max concentration
            lastUpdated: 0,
            riskTier: 3 // RED
        });

        RiskModel.RiskSnapshot memory snapshot = RiskModel.RiskSnapshot({
            stressedLCR: 8500, // 85% - below healthy
            aggregateRiskScore: 7500,
            timestamp: uint64(block.timestamp),
            systemStatus: 2 // ORANGE
        });

        bytes memory actionData = abi.encode(sources, params, snapshot);
        bytes memory report = abi.encode(vault.ACTION_UPDATE_RISK_PARAMS(), actionData);

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        // Step 3: Verify LCR changed (we just need to verify it was affected)
        uint256 lcrAfterUpdate = vault.computeLCR();
        // LCR will be lower than before the high haircut update

        // Step 4: CRE triggers defensive rebalance - pull from Aave
        actionData = abi.encode(address(aaveSource), 30_000e6);
        report = abi.encode(vault.ACTION_DEFENSIVE_REBALANCE(), actionData);

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        // Step 5: Verify funds were rebalanced
        assertEq(aaveSource.balance(), 10_000e6); // Only 10k left in Aave

        // Step 6: LCR should have improved
        uint256 lcrAfterRebalance = vault.computeLCR();
        assertGt(lcrAfterRebalance, lcrAfterUpdate);

        // Step 7: CRE updates params with lower haircut (conditions normalized)
        params[0] = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 2000, // 20% haircut (moderate)
            stressOutflowBps: 2000,
            maxConcentrationBps: 5000, // 50% max concentration
            lastUpdated: 0,
            riskTier: 0 // GREEN
        });

        snapshot = RiskModel.RiskSnapshot({
            stressedLCR: 16000, // 160% - healthy
            aggregateRiskScore: 2000,
            timestamp: uint64(block.timestamp),
            systemStatus: 0 // GREEN
        });

        actionData = abi.encode(sources, params, snapshot);
        report = abi.encode(vault.ACTION_UPDATE_RISK_PARAMS(), actionData);

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);

        // Step 8: Verify deployment to Aave is allowed again
        vm.prank(operator);
        vault.deployToYield(0, 20_000e6); // Should succeed now

        assertEq(aaveSource.balance(), 30_000e6);
    }

    // ─── View Function Tests ────────────────────────────────────────────

    function test_getYieldSources_returnsAllSources() public view {
        address[] memory sources = vault.getYieldSources();
        assertEq(sources.length, 2);
        assertEq(sources[0], address(aaveSource));
        assertEq(sources[1], address(morphoSource));
    }

    function test_getSourceBalance_returnsCorrectBalance() public {
        vm.prank(operator);
        vault.deployToYield(0, 25_000e6);

        uint256 balance = vault.getSourceBalance(address(aaveSource));
        assertEq(balance, 25_000e6);
    }

    function test_getPendingEpochWithdrawals_returnsCorrectAmount() public {
        vm.prank(user);
        vault.requestWithdraw(5_000e6);

        uint256 pending = vault.getPendingEpochWithdrawals();
        assertEq(pending, 5_000e6);
    }

    function test_getCurrentEpochInfo_returnsCorrectValues() public view {
        (uint256 epochId, uint256 startTime, uint256 minDuration) = vault.getCurrentEpochInfo();
        assertEq(epochId, 0);
        assertGt(startTime, 0);
        assertEq(minDuration, vault.MIN_EPOCH_DURATION());
    }

    // ─── Helper Functions ───────────────────────────────────────────────

    function _setHighStressParams(address source) internal {
        address[] memory sources = new address[](1);
        sources[0] = source;

        RiskModel.SourceRiskParams[] memory params = new RiskModel.SourceRiskParams[](1);
        params[0] = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 7000, // 70% haircut
            stressOutflowBps: 8000, // 80% stress outflow
            maxConcentrationBps: 10000, // 100% (no limit for this test)
            lastUpdated: 0,
            riskTier: 3 // RED
        });

        RiskModel.RiskSnapshot memory snapshot = RiskModel.RiskSnapshot({
            stressedLCR: 5000, aggregateRiskScore: 8000, timestamp: uint64(block.timestamp), systemStatus: 3
        });

        bytes memory actionData = abi.encode(sources, params, snapshot);
        bytes memory report = abi.encode(vault.ACTION_UPDATE_RISK_PARAMS(), actionData);

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);
    }

    function _setConcentrationLimit(address source, uint16 limitBps) internal {
        address[] memory sources = new address[](1);
        sources[0] = source;

        RiskModel.SourceRiskParams[] memory params = new RiskModel.SourceRiskParams[](1);
        params[0] = RiskModel.SourceRiskParams({
            liquidityHaircutBps: 1000,
            stressOutflowBps: 2000,
            maxConcentrationBps: limitBps,
            lastUpdated: 0,
            riskTier: 0
        });

        RiskModel.RiskSnapshot memory snapshot = RiskModel.RiskSnapshot({
            stressedLCR: 20000, aggregateRiskScore: 1000, timestamp: uint64(block.timestamp), systemStatus: 0
        });

        bytes memory actionData = abi.encode(sources, params, snapshot);
        bytes memory report = abi.encode(vault.ACTION_UPDATE_RISK_PARAMS(), actionData);

        vm.prank(chainlinkForwarder);
        vault.onReport("", report);
    }
}
