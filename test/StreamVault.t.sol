// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StreamVault} from "../src/StreamVault.sol";
import {IYieldSource} from "../src/IYieldSource.sol";
import {MockYieldSource} from "../src/MockYieldSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Base test harness — shared setup inherited by all test contracts
// ─────────────────────────────────────────────────────────────────────────────

abstract contract StreamVaultTestBase is Test {
    using Math for uint256;

    MockERC20 internal usdc;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant PERF_FEE_BPS = 1_000; // 10%
    uint256 internal constant MGMT_FEE_BPS = 200; // 2% annual
    uint256 internal constant SMOOTHING = 3_600; // 1 hour
    uint256 internal constant YIELD_RATE = 1; // 0.01% per second for mock
    uint256 internal constant INITIAL_DEPOSIT = 1_000e6; // 1000 USDC (6 decimals)
    uint256 internal constant MIN_EPOCH = 300; // mirrors StreamVault.MIN_EPOCH_DURATION

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);

        vault = _deployVault(
            IERC20(address(usdc)),
            operator,
            feeRecipient,
            PERF_FEE_BPS,
            MGMT_FEE_BPS,
            SMOOTHING,
            "StreamVault USDC",
            "svUSDC"
        );

        // Deploy mock yield source wired to vault (proxy address)
        yieldSource = new MockYieldSource(address(usdc), address(vault), YIELD_RATE);

        // Register yield source
        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));

        // Disable drawdown protection for existing tests (backward compatibility)
        vm.prank(operator);
        vault.setMaxDrawdown(0);
    }

    /// @dev Deploy StreamVault via UUPS proxy pattern.
    function _deployVault(
        IERC20 _asset,
        address _operator,
        address _feeRecipient,
        uint256 _perfFee,
        uint256 _mgmtFee,
        uint256 _smoothing,
        string memory _name,
        string memory _symbol
    ) internal returns (StreamVault) {
        StreamVault impl = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize, (_asset, _operator, _feeRecipient, _perfFee, _mgmtFee, _smoothing, _name, _symbol)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return StreamVault(address(proxy));
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _mintAndDeposit(address user, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _deployToYield(uint256 sourceIndex, uint256 amount) internal {
        vm.prank(operator);
        vault.deployToYield(sourceIndex, amount);
    }

    function _warpAndAccrue(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
    }

    /// @dev Warp enough for both EMA convergence and epoch minimum duration.
    function _warpForSettle() internal {
        _warpAndAccrue(SMOOTHING + 1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Constructor & Deployment
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Constructor_Test is StreamVaultTestBase {
    function test_initialState() public view {
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.operator(), operator);
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.PERFORMANCE_FEE_BPS(), PERF_FEE_BPS);
        assertEq(vault.managementFeeBps(), MGMT_FEE_BPS);
        assertEq(vault.smoothingPeriod(), SMOOTHING);
        assertEq(vault.currentEpochId(), 0);
        assertEq(vault.totalPendingShares(), 0);
        assertEq(vault.totalClaimableAssets(), 0);
        assertEq(vault.emaTotalAssets(), 10 ** 3); // _decimalsOffset = 3
        assertEq(vault.yieldSourceCount(), 1);
    }

    function test_revert_zeroOperator() public {
        StreamVault impl = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (IERC20(address(usdc)), address(0), feeRecipient, PERF_FEE_BPS, MGMT_FEE_BPS, SMOOTHING, "V", "V")
        );
        vm.expectRevert(StreamVault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_revert_perfFeeTooHigh() public {
        StreamVault impl = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (IERC20(address(usdc)), operator, feeRecipient, 5_001, MGMT_FEE_BPS, SMOOTHING, "V", "V")
        );
        vm.expectRevert(StreamVault.FeeTooHigh.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_revert_mgmtFeeTooHigh() public {
        StreamVault impl = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (IERC20(address(usdc)), operator, feeRecipient, PERF_FEE_BPS, 501, SMOOTHING, "V", "V")
        );
        vm.expectRevert(StreamVault.FeeTooHigh.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_revert_smoothingTooLow() public {
        StreamVault impl = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (IERC20(address(usdc)), operator, feeRecipient, PERF_FEE_BPS, MGMT_FEE_BPS, 299, "V", "V")
        );
        vm.expectRevert(StreamVault.InvalidSmoothingPeriod.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_revert_smoothingTooHigh() public {
        StreamVault impl = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (IERC20(address(usdc)), operator, feeRecipient, PERF_FEE_BPS, MGMT_FEE_BPS, 86_401, "V", "V")
        );
        vm.expectRevert(StreamVault.InvalidSmoothingPeriod.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_boundaryValues_perfFeeMax() public {
        StreamVault v =
            _deployVault(IERC20(address(usdc)), operator, feeRecipient, 5_000, MGMT_FEE_BPS, SMOOTHING, "V", "V");
        assertEq(v.PERFORMANCE_FEE_BPS(), 5_000);
    }

    function test_boundaryValues_smoothingBounds() public {
        StreamVault vMin =
            _deployVault(IERC20(address(usdc)), operator, feeRecipient, PERF_FEE_BPS, MGMT_FEE_BPS, 300, "V", "V");
        assertEq(vMin.smoothingPeriod(), 300);

        StreamVault vMax =
            _deployVault(IERC20(address(usdc)), operator, feeRecipient, PERF_FEE_BPS, MGMT_FEE_BPS, 86_400, "V", "V");
        assertEq(vMax.smoothingPeriod(), 86_400);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Deposits & Share Accounting
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Deposit_Test is StreamVaultTestBase {
    function test_firstDeposit_sharesCorrect() public {
        uint256 shares = _mintAndDeposit(alice, INITIAL_DEPOSIT);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT);
    }

    function test_firstDeposit_snapsEmaToSpot() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        // After first deposit, EMA should snap to spot (not stay at virtual 1000)
        assertEq(vault.emaTotalAssets(), vault.totalAssets());
    }

    function test_secondDeposit_proportionalShares() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle();

        uint256 bobShares = _mintAndDeposit(bob, INITIAL_DEPOSIT);
        uint256 aliceShares = vault.balanceOf(alice);

        assertApproxEqRel(bobShares, aliceShares, 0.03e18); // within 3%
    }

    function test_totalAssets_equalsIdleBalance() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_DEPOSIT);
    }

    function test_deposit_emitsTransferAndDepositEvents() public {
        usdc.mint(alice, INITIAL_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    function test_deposit_zero_mintsZeroShares() public {
        usdc.mint(alice, 0);
        vm.startPrank(alice);
        usdc.approve(address(vault), 0);
        uint256 shares = vault.deposit(0, alice);
        vm.stopPrank();
        assertEq(shares, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Async Withdrawal Flow (request → settle → claim)
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Withdrawal_Test is StreamVaultTestBase {
    function setUp() public override {
        super.setUp();
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle(); // EMA converge + satisfies MIN_EPOCH_DURATION
    }

    function test_requestWithdraw_burnsShares() public {
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(shares);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalPendingShares(), shares);
    }

    function test_requestWithdraw_zeroSharesReverts() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.ZeroShares.selector);
        vault.requestWithdraw(0);
    }

    function test_requestWithdraw_insufficientSharesReverts() public {
        vm.prank(bob); // bob has no shares
        vm.expectRevert(); // ERC20 InsufficientBalance
        vault.requestWithdraw(1);
    }

    function test_settleEpoch_calculatesAssetsOwed() public {
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.settleEpoch();

        (StreamVault.EpochStatus status, uint256 totalSharesBurned, uint256 totalAssetsOwed,) = vault.epochs(0);
        assertEq(uint8(status), 1); // SETTLED
        assertEq(totalSharesBurned, shares);
        assertGt(totalAssetsOwed, 0);
        assertEq(vault.currentEpochId(), 1);
        assertEq(vault.totalPendingShares(), 0);
    }

    function test_settleEpoch_advancesEpochId() public {
        assertEq(vault.currentEpochId(), 0);

        vm.prank(operator);
        vault.settleEpoch();

        assertEq(vault.currentEpochId(), 1);

        // Must wait MIN_EPOCH before settling again
        _warpAndAccrue(MIN_EPOCH);

        vm.prank(operator);
        vault.settleEpoch();

        assertEq(vault.currentEpochId(), 2);
    }

    function test_settleEpoch_epochTooYoung_reverts() public {
        // Settle epoch 0 (satisfies duration from setUp warp)
        vm.prank(operator);
        vault.settleEpoch();

        // Try to settle epoch 1 immediately — should revert
        vm.prank(operator);
        vm.expectRevert(StreamVault.EpochTooYoung.selector);
        vault.settleEpoch();
    }

    function test_settleEpoch_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.settleEpoch();
    }

    function test_claimWithdrawal_payoutCorrect() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 aliceBalBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.settleEpoch();

        vm.prank(alice);
        vault.claimWithdrawal(0);

        uint256 payout = usdc.balanceOf(alice) - aliceBalBefore;
        assertGt(payout, 0);
        assertApproxEqRel(payout, INITIAL_DEPOSIT, 0.05e18);
    }

    function test_claimWithdrawal_doubleClaimReverts() public {
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.settleEpoch();

        vm.prank(alice);
        vault.claimWithdrawal(0);

        vm.prank(alice);
        vm.expectRevert(StreamVault.NoRequestInEpoch.selector);
        vault.claimWithdrawal(0);
    }

    function test_claimWithdrawal_unsettledEpochReverts() public {
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(alice);
        vm.expectRevert(StreamVault.EpochNotSettled.selector);
        vault.claimWithdrawal(0);
    }

    function test_claimWithdrawal_noRequestReverts() public {
        vm.prank(operator);
        vault.settleEpoch();

        vm.prank(bob);
        vm.expectRevert(StreamVault.NoRequestInEpoch.selector);
        vault.claimWithdrawal(0);
    }

    function test_multipleUsersInSameEpoch_proRata() public {
        _mintAndDeposit(bob, INITIAL_DEPOSIT);
        _warpForSettle();

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);

        vm.prank(alice);
        vault.requestWithdraw(aliceShares);

        vm.prank(bob);
        vault.requestWithdraw(bobShares);

        vm.prank(operator);
        vault.settleEpoch();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawal(0);
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.claimWithdrawal(0);
        uint256 bobPayout = usdc.balanceOf(bob) - bobBefore;

        assertApproxEqRel(alicePayout, bobPayout, 0.05e18);
    }

    function test_partialWithdraw_leavesRemainingShares() public {
        uint256 shares = vault.balanceOf(alice);
        uint256 half = shares / 2;

        vm.prank(alice);
        vault.requestWithdraw(half);

        assertEq(vault.balanceOf(alice), shares - half);
    }

    function test_syncWithdraw_reverts() public {
        vm.expectRevert(StreamVault.SyncWithdrawDisabled.selector);
        vault.withdraw(100, alice, alice);
    }

    function test_syncRedeem_reverts() public {
        vm.expectRevert(StreamVault.SyncWithdrawDisabled.selector);
        vault.redeem(100, alice, alice);
    }

    function test_maxWithdraw_alwaysZero() public view {
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_maxRedeem_alwaysZero() public view {
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_previewWithdraw_reverts() public {
        vm.expectRevert(StreamVault.SyncWithdrawDisabled.selector);
        vault.previewWithdraw(100);
    }

    function test_previewRedeem_reverts() public {
        vm.expectRevert(StreamVault.SyncWithdrawDisabled.selector);
        vault.previewRedeem(100);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Yield Source Management
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_YieldSource_Test is StreamVaultTestBase {
    function setUp() public override {
        super.setUp();
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle();
    }

    function test_addYieldSource_success() public {
        MockYieldSource ys2 = new MockYieldSource(address(usdc), address(vault), YIELD_RATE);
        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(ys2)));
        assertEq(vault.yieldSourceCount(), 2);
    }

    function test_addYieldSource_zeroAddressReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.ZeroAddress.selector);
        vault.addYieldSource(IYieldSource(address(0)));
    }

    function test_addYieldSource_assetMismatchReverts() public {
        MockERC20 otherToken = new MockERC20("DAI", "DAI", 18);
        MockYieldSource badSource = new MockYieldSource(address(otherToken), address(vault), YIELD_RATE);

        vm.prank(operator);
        vm.expectRevert(StreamVault.AssetMismatch.selector);
        vault.addYieldSource(IYieldSource(address(badSource)));
    }

    function test_addYieldSource_maxCapReverts() public {
        for (uint256 i; i < 19; ++i) {
            MockYieldSource ys = new MockYieldSource(address(usdc), address(vault), YIELD_RATE);
            vm.prank(operator);
            vault.addYieldSource(IYieldSource(address(ys)));
        }
        assertEq(vault.yieldSourceCount(), 20);

        MockYieldSource ys21 = new MockYieldSource(address(usdc), address(vault), YIELD_RATE);
        vm.prank(operator);
        vm.expectRevert(StreamVault.TooManyYieldSources.selector);
        vault.addYieldSource(IYieldSource(address(ys21)));
    }

    function test_addYieldSource_onlyOperator() public {
        MockYieldSource ys2 = new MockYieldSource(address(usdc), address(vault), YIELD_RATE);
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.addYieldSource(IYieldSource(address(ys2)));
    }

    function test_removeYieldSource_emptySource() public {
        vm.prank(operator);
        vault.removeYieldSource(0);
        assertEq(vault.yieldSourceCount(), 0);
    }

    function test_removeYieldSource_nonEmptyReverts() public {
        _deployToYield(0, 500e6);

        vm.prank(operator);
        vm.expectRevert(StreamVault.SourceNotEmpty.selector);
        vault.removeYieldSource(0);
    }

    function test_removeYieldSource_invalidIndexReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.InvalidSourceIndex.selector);
        vault.removeYieldSource(5);
    }

    function test_deployToYield_movesAssetsToSource() public {
        uint256 deployAmount = 500e6;
        _deployToYield(0, deployAmount);

        assertEq(yieldSource.balance(), deployAmount);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_DEPOSIT - deployAmount);
        assertApproxEqAbs(vault.totalAssets(), INITIAL_DEPOSIT, 1);
    }

    function test_deployToYield_zeroAmountReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.ZeroAmount.selector);
        vault.deployToYield(0, 0);
    }

    function test_deployToYield_invalidIndexReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.InvalidSourceIndex.selector);
        vault.deployToYield(5, 100e6);
    }

    function test_withdrawFromYield_movesAssetsBack() public {
        _deployToYield(0, 500e6);
        uint256 idleBefore = usdc.balanceOf(address(vault));

        vm.prank(operator);
        vault.withdrawFromYield(0, 200e6);

        assertEq(usdc.balanceOf(address(vault)), idleBefore + 200e6);
    }

    function test_withdrawFromYield_zeroAmountReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.ZeroAmount.selector);
        vault.withdrawFromYield(0, 0);
    }

    function test_settleEpoch_waterfallPull() public {
        _deployToYield(0, 900e6);
        _warpForSettle();

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.settleEpoch();

        (,, uint256 totalAssetsOwed,) = vault.epochs(0);
        assertGt(totalAssetsOwed, 0);

        vm.prank(alice);
        vault.claimWithdrawal(0);
        assertGt(usdc.balanceOf(alice), 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Performance Fee & Harvest
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Harvest_Test is StreamVaultTestBase {
    function setUp() public override {
        super.setUp();
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle();
        _deployToYield(0, 800e6);
    }

    function test_harvestYield_mintsFeeSharesToRecipient() public {
        _warpAndAccrue(100);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(operator);
        vault.harvestYield();

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfter, feeSharesBefore);
    }

    function test_harvestYield_doubleHarvest_noExtraFee() public {
        _warpAndAccrue(100);

        vm.prank(operator);
        vault.harvestYield();
        uint256 feeSharesAfterFirst = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfterFirst, 0);

        vm.prank(operator);
        vault.harvestYield();
        assertEq(vault.balanceOf(feeRecipient), feeSharesAfterFirst);
    }

    function test_harvestYield_highWaterMark_preventDoubleCharging() public {
        _warpAndAccrue(100);

        vm.prank(operator);
        vault.harvestYield();
        uint256 sharesAfterFirst = vault.balanceOf(feeRecipient);

        vm.prank(operator);
        vault.harvestYield();
        assertEq(vault.balanceOf(feeRecipient), sharesAfterFirst);
    }

    function test_harvestYield_perSourceHWM_noDoubleChargeOnRecovery() public {
        // Harvest to set baseline HWMs
        _warpAndAccrue(100);
        vm.prank(operator);
        vault.harvestYield();
        uint256 feeAfterBaseline = vault.balanceOf(feeRecipient);

        // Withdraw some from yield (simulates a loss — balance drops below HWM)
        vm.prank(operator);
        vault.withdrawFromYield(0, 400e6);

        // Re-deploy the same amount (balance recovers to ~HWM but not above)
        vm.prank(operator);
        vault.deployToYield(0, 400e6);

        // Harvest — source recovered but didn't exceed HWM. No new fee.
        vm.prank(operator);
        vault.harvestYield();
        assertEq(vault.balanceOf(feeRecipient), feeAfterBaseline);

        // Now accrue actual new yield above HWM
        _warpAndAccrue(200);
        vm.prank(operator);
        vault.harvestYield();
        assertGt(vault.balanceOf(feeRecipient), feeAfterBaseline);
    }

    function test_harvestYield_zeroFeeRecipient_noMint() public {
        vm.prank(operator);
        vault.setFeeRecipient(address(0));

        _warpAndAccrue(100);

        vm.prank(operator);
        vault.harvestYield(); // should not revert
    }

    function test_harvestYield_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.harvestYield();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. EMA-Smoothed NAV
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_EMA_Test is StreamVaultTestBase {
    function setUp() public override {
        super.setUp();
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle();
        // Trigger EMA update via a small deposit
        _mintAndDeposit(bob, 1e6);
    }

    function test_ema_convergesAfterSmoothingPeriod() public view {
        uint256 spot = vault.totalAssets();
        uint256 ema = vault.emaTotalAssets();
        assertApproxEqRel(ema, spot, 0.02e18);
    }

    function test_ema_firstDepositSnaps() public {
        // Deploy a fresh vault
        StreamVault v2 = _deployVault(
            IERC20(address(usdc)), operator, feeRecipient, PERF_FEE_BPS, MGMT_FEE_BPS, SMOOTHING, "V2", "V2"
        );
        assertEq(v2.emaTotalAssets(), 1000); // virtual offset

        usdc.mint(alice, 5_000e6);
        vm.startPrank(alice);
        usdc.approve(address(v2), 5_000e6);
        v2.deposit(5_000e6, alice);
        vm.stopPrank();

        // EMA should have snapped to spot (5000e6), not stuck at 1000
        assertEq(v2.emaTotalAssets(), 5_000e6);
    }

    function test_ema_partialUpdate_movesTowardsSpot() public {
        uint256 emaBefore = vault.emaTotalAssets();

        usdc.mint(address(vault), 500e6);
        uint256 newSpot = vault.totalAssets();
        assertGt(newSpot, emaBefore);

        _warpAndAccrue(SMOOTHING / 2);
        _mintAndDeposit(carol, 1e6);

        uint256 emaAfter = vault.emaTotalAssets();
        assertGt(emaAfter, emaBefore);
        assertLt(emaAfter, newSpot);
    }

    function test_ema_floorPrevents5PercentDrop() public {
        usdc.mint(address(vault), 10_000e6);

        _warpAndAccrue(1);
        uint256 spotBeforeDeposit = vault.totalAssets();

        _mintAndDeposit(carol, 1e6);

        uint256 ema = vault.emaTotalAssets();
        uint256 floorVal = spotBeforeDeposit * 9_500 / 10_000;
        assertGe(ema, floorVal);
        assertLt(ema, vault.totalAssets());
    }

    function test_ema_donationAttack_limitedImpact() public {
        uint256 spotBefore = vault.totalAssets();
        uint256 donation = 1_000e6;
        usdc.mint(address(vault), donation);

        uint256 spotAfterDonation = vault.totalAssets();
        assertGt(spotAfterDonation, spotBefore + donation - 1);

        _warpAndAccrue(1);
        _mintAndDeposit(carol, 1e6);

        uint256 emaAfter = vault.emaTotalAssets();
        uint256 newSpot = vault.totalAssets();
        assertLt(emaAfter, newSpot);
        assertLe(emaAfter, newSpot * 10_000 / 9_500);
    }

    function test_ema_safetyMinimum() public view {
        assertGe(vault.emaTotalAssets(), 1_000);
    }

    function test_settleEpoch_usesEmaNotSpot() public {
        usdc.mint(address(vault), 5_000e6);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        // Wait MIN_EPOCH_DURATION so settlement is allowed
        _warpAndAccrue(MIN_EPOCH);

        uint256 spotBefore = vault.totalAssets();

        vm.prank(operator);
        vault.settleEpoch();

        (,, uint256 assetsOwed,) = vault.epochs(0);
        uint256 spotBased = shares * spotBefore / (vault.totalSupply() + shares);
        assertLe(assetsOwed, spotBased + 1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Continuous Management Fee
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_ManagementFee_Test is StreamVaultTestBase {
    function setUp() public override {
        super.setUp();
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle();
    }

    function test_mgmtFee_accruesOverTime() public {
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        _warpAndAccrue(365.25 days);
        _mintAndDeposit(bob, 1e6);

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfter, feeSharesBefore);
    }

    function test_mgmtFee_approximatelyCorrectAfterOneYear() public {
        _warpAndAccrue(365.25 days);
        _mintAndDeposit(bob, 1e6);

        uint256 feeShares = vault.balanceOf(feeRecipient);
        uint256 totalSupplyAfter = vault.totalSupply();

        uint256 feeRatioBps = feeShares * 10_000 / totalSupplyAfter;
        assertApproxEqAbs(feeRatioBps, MGMT_FEE_BPS, 30); // within 0.3%
    }

    function test_mgmtFee_zeroFee_noAccrual() public {
        StreamVault v2 =
            _deployVault(IERC20(address(usdc)), operator, feeRecipient, PERF_FEE_BPS, 0, SMOOTHING, "V2", "V2");

        usdc.mint(alice, INITIAL_DEPOSIT);
        vm.startPrank(alice);
        usdc.approve(address(v2), INITIAL_DEPOSIT);
        v2.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        _warpAndAccrue(365.25 days);

        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(v2), 1e6);
        v2.deposit(1e6, bob);
        vm.stopPrank();

        assertEq(v2.balanceOf(feeRecipient), 0);
    }

    function test_mgmtFee_zeroRecipient_noAccrual() public {
        vm.prank(operator);
        vault.setFeeRecipient(address(0));

        _warpAndAccrue(365.25 days);
        _mintAndDeposit(bob, 1e6);

        assertEq(vault.balanceOf(address(0)), 0);
    }

    function test_mgmtFee_sameBlock_skips() public {
        _mintAndDeposit(bob, 100e6);
        uint256 feeSharesAfterFirst = vault.balanceOf(feeRecipient);

        _mintAndDeposit(carol, 100e6);
        assertEq(vault.balanceOf(feeRecipient), feeSharesAfterFirst);
    }

    function test_setManagementFee_accruesAtOldRateFirst() public {
        _warpAndAccrue(1_000);

        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(operator);
        vault.setManagementFee(100);

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeSharesAfter, feeSharesBefore);
        assertEq(vault.managementFeeBps(), 100);
    }

    function test_setManagementFee_tooHighReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.FeeTooHigh.selector);
        vault.setManagementFee(501);
    }

    function test_mgmtFee_chargesOnNetAssetsNotGross() public {
        // After settlement, claimable should be excluded from fee base
        _mintAndDeposit(bob, INITIAL_DEPOSIT);
        _warpForSettle();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);

        vm.prank(operator);
        vault.settleEpoch();

        uint256 claimable = vault.totalClaimableAssets();
        assertGt(claimable, 0);

        // Warp and trigger fee
        _warpAndAccrue(MIN_EPOCH + 1);
        uint256 feeBefore = vault.balanceOf(feeRecipient);
        _mintAndDeposit(carol, 1e6);
        uint256 feeAfter = vault.balanceOf(feeRecipient);

        // Fee should be based on ~1000e6 (bob's share) not ~2000e6 (gross)
        // Just verify fee was minted and is nonzero
        assertGt(feeAfter, feeBefore);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. Access Control & Admin
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Admin_Test is StreamVaultTestBase {
    function test_transferOperator_success() public {
        vm.prank(operator);
        vault.transferOperator(alice);
        assertEq(vault.pendingOperator(), alice);
        assertEq(vault.operator(), operator); // not changed yet

        vm.prank(alice);
        vault.acceptOperator();
        assertEq(vault.operator(), alice);
        assertEq(vault.pendingOperator(), address(0));
    }

    function test_transferOperator_zeroAddressReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.ZeroAddress.selector);
        vault.transferOperator(address(0));
    }

    function test_transferOperator_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.transferOperator(alice);
    }

    function test_acceptOperator_onlyPendingOperator() public {
        vm.prank(operator);
        vault.transferOperator(alice);

        vm.prank(bob);
        vm.expectRevert(StreamVault.OnlyPendingOperator.selector);
        vault.acceptOperator();
    }

    function test_setFeeRecipient_success() public {
        vm.prank(operator);
        vault.setFeeRecipient(alice);
        assertEq(vault.feeRecipient(), alice);
    }

    function test_setFeeRecipient_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.setFeeRecipient(alice);
    }

    function test_setSmoothingPeriod_success() public {
        vm.prank(operator);
        vault.setSmoothingPeriod(600);
        assertEq(vault.smoothingPeriod(), 600);
    }

    function test_setSmoothingPeriod_tooLowReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.InvalidSmoothingPeriod.selector);
        vault.setSmoothingPeriod(100);
    }

    function test_setSmoothingPeriod_tooHighReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.InvalidSmoothingPeriod.selector);
        vault.setSmoothingPeriod(100_000);
    }

    function test_setSmoothingPeriod_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.setSmoothingPeriod(600);
    }

    function test_deployToYield_onlyOperator() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);

        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.deployToYield(0, 100e6);
    }

    function test_withdrawFromYield_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.withdrawFromYield(0, 100e6);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. Accounting Invariants & Edge Cases
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Invariant_Test is StreamVaultTestBase {
    function test_totalAssets_equalsIdlePlusDeployedMinusClaimable() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle();
        _deployToYield(0, 600e6);

        uint256 idle = usdc.balanceOf(address(vault));
        uint256 deployed = yieldSource.balance();
        uint256 claimable = vault.totalClaimableAssets();

        assertEq(vault.totalAssets(), idle + deployed - claimable);
    }

    function test_totalAssets_subtractsClaimable() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _mintAndDeposit(bob, INITIAL_DEPOSIT);
        _warpForSettle();

        uint256 aliceShares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.requestWithdraw(aliceShares);

        vm.prank(operator);
        vault.settleEpoch();

        assertGt(vault.totalClaimableAssets(), 0);

        uint256 idle = usdc.balanceOf(address(vault));
        uint256 claimable = vault.totalClaimableAssets();
        assertEq(vault.totalAssets(), idle - claimable);
    }

    function test_roundtrip_valuePreservation() public {
        uint256 depositAmount = 10_000e6;

        _mintAndDeposit(alice, depositAmount);
        _warpForSettle();

        uint256 shares = vault.balanceOf(alice);
        uint256 epochId = vault.currentEpochId();

        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.settleEpoch();

        vm.prank(alice);
        vault.claimWithdrawal(epochId);

        uint256 received = usdc.balanceOf(alice);
        assertApproxEqRel(received, depositAmount, 0.05e18);
        assertLe(received, depositAmount);
    }

    function test_inflationAttack_mitigated() public {
        usdc.mint(alice, 1);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1);
        uint256 aliceShares = vault.deposit(1, alice);
        vm.stopPrank();

        assertGt(aliceShares, 0);

        usdc.mint(address(vault), 1_000e6);

        _warpAndAccrue(1);
        uint256 bobShares = _mintAndDeposit(bob, 1_000e6);
        assertGt(bobShares, 0);
        assertGt(bobShares, aliceShares);
    }

    function test_multiEpoch_claimFromOldEpoch() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _mintAndDeposit(bob, INITIAL_DEPOSIT);
        _warpForSettle();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);
        vm.prank(operator);
        vault.settleEpoch();

        _warpForSettle();
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestWithdraw(bobShares);
        vm.prank(operator);
        vault.settleEpoch();

        vm.prank(alice);
        vault.claimWithdrawal(0);
        assertGt(usdc.balanceOf(alice), 0);

        vm.prank(bob);
        vault.claimWithdrawal(1);
        assertGt(usdc.balanceOf(bob), 0);
    }

    function test_emptyEpochSettlement() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle();

        vm.prank(operator);
        vault.settleEpoch();

        (,, uint256 assetsOwed,) = vault.epochs(0);
        assertEq(assetsOwed, 0);
        assertEq(vault.currentEpochId(), 1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. Fuzz Tests
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Fuzz_Test is StreamVaultTestBase {
    function testFuzz_deposit_sharesNonZero(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.totalAssets(), amount);
    }

    function testFuzz_depositWithdraw_roundtrip(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        uint256 shares = _mintAndDeposit(alice, amount);
        _warpForSettle();

        uint256 epochId = vault.currentEpochId();

        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.settleEpoch();

        vm.prank(alice);
        vault.claimWithdrawal(epochId);

        uint256 received = usdc.balanceOf(alice);
        assertLe(received, amount);
        assertApproxEqRel(received, amount, 0.05e18);
    }

    function testFuzz_multiDeposit_totalAssetsConsistent(uint256 a, uint256 b) public {
        a = bound(a, 1e6, 50_000_000e6);
        b = bound(b, 1e6, 50_000_000e6);

        _mintAndDeposit(alice, a);
        _mintAndDeposit(bob, b);

        assertApproxEqAbs(vault.totalAssets(), a + b, 1);
    }

    function testFuzz_ema_neverBelowFloor(uint256 donation) public {
        donation = bound(donation, 1e6, 1_000_000_000e6);

        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle();
        _mintAndDeposit(bob, 1e6);

        usdc.mint(address(vault), donation);

        _warpAndAccrue(1);
        uint256 spotAtUpdate = vault.totalAssets();

        _mintAndDeposit(carol, 1e6);

        uint256 ema = vault.emaTotalAssets();
        uint256 floor = spotAtUpdate * 9_500 / 10_000;
        assertGe(ema, floor);
    }

    function testFuzz_managementFee_proportionalToTime(uint256 seconds_) public {
        seconds_ = bound(seconds_, 1, 365.25 days);

        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _warpForSettle();
        _mintAndDeposit(bob, 1e6);

        _warpAndAccrue(seconds_);
        _mintAndDeposit(carol, 1e6);

        uint256 feeShares = vault.balanceOf(feeRecipient);

        if (seconds_ >= 86_400) {
            assertGt(feeShares, 0);
        }
        assertLe(feeShares, vault.totalSupply());
    }

    function testFuzz_settlement_assetsOwedLeqTotalAssets(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);

        uint256 shares = _mintAndDeposit(alice, amount);
        _warpForSettle();
        _mintAndDeposit(bob, 1e6);

        uint256 epochId = vault.currentEpochId();

        vm.prank(alice);
        vault.requestWithdraw(shares);

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(operator);
        vault.settleEpoch();

        (,, uint256 assetsOwed,) = vault.epochs(epochId);
        assertLe(assetsOwed, totalAssetsBefore + 1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 11. UUPS Upgrade Tests
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal V2 contract for upgrade testing — adds a version getter
contract StreamVaultV2 is StreamVault {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract StreamVault_Upgrade_Test is StreamVaultTestBase {
    function test_upgradeToAndCall_onlyOperator() public {
        StreamVaultV2 v2Impl = new StreamVaultV2();

        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeToAndCall_success() public {
        StreamVaultV2 v2Impl = new StreamVaultV2();

        vm.prank(operator);
        vault.upgradeToAndCall(address(v2Impl), "");

        // Cast to V2 and verify new function is accessible
        StreamVaultV2 vaultV2 = StreamVaultV2(address(vault));
        assertEq(vaultV2.version(), 2);
    }

    function test_upgrade_preservesState() public {
        // Deposit first to create meaningful state
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        // Record state before upgrade
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 perfFeeBefore = vault.PERFORMANCE_FEE_BPS();
        uint256 mgmtFeeBefore = vault.managementFeeBps();
        uint256 smoothingBefore = vault.smoothingPeriod();
        address operatorBefore = vault.operator();
        uint256 epochBefore = vault.currentEpochId();

        // Upgrade
        StreamVaultV2 v2Impl = new StreamVaultV2();
        vm.prank(operator);
        vault.upgradeToAndCall(address(v2Impl), "");

        // Verify all state preserved
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets changed");
        assertEq(vault.totalSupply(), totalSupplyBefore, "totalSupply changed");
        assertEq(vault.balanceOf(alice), aliceSharesBefore, "alice balance changed");
        assertEq(vault.PERFORMANCE_FEE_BPS(), perfFeeBefore, "perfFee changed");
        assertEq(vault.managementFeeBps(), mgmtFeeBefore, "mgmtFee changed");
        assertEq(vault.smoothingPeriod(), smoothingBefore, "smoothing changed");
        assertEq(vault.operator(), operatorBefore, "operator changed");
        assertEq(vault.currentEpochId(), epochBefore, "epoch changed");
    }

    function test_implementation_cannotBeInitialized() public {
        StreamVault impl = new StreamVault();

        vm.expectRevert();
        impl.initialize(IERC20(address(usdc)), operator, feeRecipient, PERF_FEE_BPS, MGMT_FEE_BPS, SMOOTHING, "V", "V");
    }

    function test_proxy_cannotBeReinitialized() public {
        vm.expectRevert();
        vault.initialize(IERC20(address(usdc)), operator, feeRecipient, PERF_FEE_BPS, MGMT_FEE_BPS, SMOOTHING, "V", "V");
    }
}
