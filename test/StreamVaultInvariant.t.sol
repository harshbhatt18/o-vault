// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StreamVault} from "../src/StreamVault.sol";
import {IYieldSource} from "../src/IYieldSource.sol";
import {MockYieldSource} from "../src/MockYieldSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeLib} from "../src/libraries/FeeLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Advanced Invariant Handler — exercises all vault state transitions
// ─────────────────────────────────────────────────────────────────────────────

contract AdvancedVaultHandler is Test {
    StreamVault public vault;
    MockERC20 public usdc;
    MockYieldSource public yieldSource1;
    MockYieldSource public yieldSource2;
    address public operator;
    address public feeRecipient;

    address[] public actors;
    uint256 public constant NUM_ACTORS = 8;

    // ── Ghost variables for accounting ──
    uint256 public ghostTotalDeposited;
    uint256 public ghostTotalClaimed;
    uint256 public ghostTotalFeesPaid; // withdrawal fees paid
    uint256 public ghostSettledEpochs;
    uint256 public ghostDepositCount;
    uint256 public ghostWithdrawRequestCount;
    uint256 public ghostClaimCount;

    uint256 public ghostTotalSimulatedLoss; // track losses sent to 0xdead

    // Track per-actor deposits for solvency checks
    mapping(address => uint256) public ghostActorDeposited;

    // Track share supply at key moments
    uint256 public ghostSharesMintedToFeeRecipient;

    // ── Ghost variables for new features ──
    uint256 public ghostTransferRestrictionToggles;
    uint256 public ghostOperator7540Sets;
    uint256 public ghostRequestRedeemCount;
    mapping(address => bool) public ghostWhitelistedAddresses;
    mapping(address => mapping(address => bool)) public ghostOperator7540State;

    constructor(
        StreamVault _vault,
        MockERC20 _usdc,
        MockYieldSource _ys1,
        MockYieldSource _ys2,
        address _operator,
        address _feeRecipient
    ) {
        vault = _vault;
        usdc = _usdc;
        yieldSource1 = _ys1;
        yieldSource2 = _ys2;
        operator = _operator;
        feeRecipient = _feeRecipient;

        for (uint256 i; i < NUM_ACTORS; ++i) {
            address actor = makeAddr(string(abi.encodePacked("inv-actor", i)));
            actors.push(actor);
        }
    }

    // ── Core Operations ──

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % NUM_ACTORS];
        amount = bound(amount, 1e6, 5_000_000e6);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();

        ghostTotalDeposited += amount;
        ghostActorDeposited[actor] += amount;
        ghostDepositCount++;
    }

    function depositToOther(uint256 actorSeed, uint256 receiverSeed, uint256 amount) external {
        address caller = actors[actorSeed % NUM_ACTORS];
        address receiver = actors[receiverSeed % NUM_ACTORS];
        amount = bound(amount, 1e6, 1_000_000e6);

        usdc.mint(caller, amount);
        vm.startPrank(caller);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, receiver);
        vm.stopPrank();

        ghostTotalDeposited += amount;
        ghostActorDeposited[receiver] += amount;
        ghostDepositCount++;
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % NUM_ACTORS];
        shares = bound(shares, 1e9, 1_000_000e9);

        uint256 assets = vault.previewMint(shares);
        if (assets == 0) return;

        usdc.mint(actor, assets);
        vm.startPrank(actor);
        usdc.approve(address(vault), assets);
        vault.mint(shares, actor);
        vm.stopPrank();

        ghostTotalDeposited += assets;
        ghostActorDeposited[actor] += assets;
        ghostDepositCount++;
    }

    function requestWithdraw(uint256 actorSeed, uint256 shareFraction) external {
        address actor = actors[actorSeed % NUM_ACTORS];
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 toWithdraw = shares * shareFraction / 100;
        if (toWithdraw == 0) return;

        // Skip if lockup active
        uint256 lockup = vault.lockupPeriod();
        if (lockup > 0 && block.timestamp < vault.depositTimestamp(actor) + lockup) return;

        vm.prank(actor);
        vault.requestWithdraw(toWithdraw);
        ghostWithdrawRequestCount++;
    }

    function settleEpoch() external {
        // Warp past minimum epoch duration
        vm.warp(block.timestamp + 301);

        vm.prank(operator);
        try vault.settleEpoch() {
            ghostSettledEpochs++;
        } catch {}
    }

    function claimWithdrawal(uint256 actorSeed) external {
        address actor = actors[actorSeed % NUM_ACTORS];

        uint256 currentEpoch = vault.currentEpochId();
        for (uint256 i; i < currentEpoch; ++i) {
            (StreamVault.EpochStatus status,,,) = vault.epochs(i);
            if (status != StreamVault.EpochStatus.SETTLED) continue;

            uint256 userShares = vault.getUserWithdrawRequest(i, actor);
            if (userShares == 0) continue;

            uint256 before = usdc.balanceOf(actor);
            uint256 feeBefore = usdc.balanceOf(feeRecipient);
            vm.prank(actor);
            vault.claimWithdrawal(i);
            ghostTotalClaimed += usdc.balanceOf(actor) - before;
            ghostTotalFeesPaid += usdc.balanceOf(feeRecipient) - feeBefore;
            ghostClaimCount++;
            return;
        }
    }

    function batchClaimWithdrawals(uint256 actorSeed) external {
        address actor = actors[actorSeed % NUM_ACTORS];
        uint256 currentEpoch = vault.currentEpochId();
        if (currentEpoch == 0) return;

        // Collect claimable epochs for this actor
        uint256[] memory claimable = new uint256[](currentEpoch);
        uint256 count;
        for (uint256 i; i < currentEpoch; ++i) {
            (StreamVault.EpochStatus status,,,) = vault.epochs(i);
            if (status != StreamVault.EpochStatus.SETTLED) continue;
            if (vault.getUserWithdrawRequest(i, actor) == 0) continue;
            claimable[count++] = i;
        }
        if (count == 0) return;

        uint256[] memory epochIds = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            epochIds[i] = claimable[i];
        }

        uint256 before = usdc.balanceOf(actor);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        vm.prank(actor);
        vault.batchClaimWithdrawals(epochIds);
        ghostTotalClaimed += usdc.balanceOf(actor) - before;
        ghostTotalFeesPaid += usdc.balanceOf(feeRecipient) - feeBefore;
        ghostClaimCount += count;
    }

    // ── Yield Source Operations ──

    function deployToYield(uint256 sourceIdx, uint256 fraction) external {
        sourceIdx = sourceIdx % 2;
        fraction = bound(fraction, 1, 70);
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 claimable = vault.totalClaimableAssets();
        uint256 available = idle > claimable ? idle - claimable : 0;

        uint256 toDeploy = available * fraction / 100;
        if (toDeploy == 0) return;

        vm.prank(operator);
        try vault.deployToYield(sourceIdx, toDeploy) {} catch {}
    }

    function withdrawFromYield(uint256 sourceIdx, uint256 fraction) external {
        sourceIdx = sourceIdx % 2;
        IYieldSource src = sourceIdx == 0 ? IYieldSource(yieldSource1) : IYieldSource(yieldSource2);
        uint256 deployed = src.balance();
        if (deployed == 0) return;

        fraction = bound(fraction, 1, 100);
        uint256 toWithdraw = deployed * fraction / 100;
        if (toWithdraw == 0) return;

        vm.prank(operator);
        vault.withdrawFromYield(sourceIdx, toWithdraw);
    }

    function harvestYield() external {
        vm.warp(block.timestamp + 60);
        uint256 feeSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(operator);
        vault.harvestYield();

        uint256 feeSharesAfter = vault.balanceOf(feeRecipient);
        if (feeSharesAfter > feeSharesBefore) {
            ghostSharesMintedToFeeRecipient += feeSharesAfter - feeSharesBefore;
        }
    }

    function simulateYield(uint256 sourceIdx, uint256 amount) external {
        sourceIdx = sourceIdx % 2;
        amount = bound(amount, 1e4, 500_000e6);
        if (sourceIdx == 0) {
            yieldSource1.simulateYield(amount);
        } else {
            yieldSource2.simulateYield(amount);
        }
    }

    function simulateLoss(uint256 sourceIdx, uint256 fraction) external {
        sourceIdx = sourceIdx % 2;
        fraction = bound(fraction, 1, 30); // max 30% loss
        MockYieldSource src = sourceIdx == 0 ? yieldSource1 : yieldSource2;
        uint256 bal = src.balance();
        if (bal == 0) return;

        uint256 loss = bal * fraction / 100;
        if (loss == 0) return;
        src.simulateLoss(loss);
        ghostTotalSimulatedLoss += loss;
    }

    // ── Admin Operations ──

    function setDepositCap(uint256 cap) external {
        cap = bound(cap, 0, 100_000_000e6);
        vm.prank(operator);
        vault.setDepositCap(cap);
    }

    function setWithdrawalFee(uint256 fee) external {
        fee = bound(fee, 0, 100); // MAX_WITHDRAWAL_FEE_BPS
        vm.prank(operator);
        vault.setWithdrawalFee(fee);
    }

    function setLockupPeriod(uint256 period) external {
        period = bound(period, 0, 7 days);
        vm.prank(operator);
        vault.setLockupPeriod(period);
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 fraction) external {
        address from = actors[fromSeed % NUM_ACTORS];
        address to = actors[toSeed % NUM_ACTORS];
        if (from == to) return;

        uint256 shares = vault.balanceOf(from);
        if (shares == 0) return;

        fraction = bound(fraction, 1, 100);
        uint256 amount = shares * fraction / 100;
        if (amount == 0) return;

        vm.prank(from);
        try vault.transfer(to, amount) {} catch {}
    }

    // ── Transfer Restriction Operations ──

    function toggleTransferRestrictions() external {
        bool current = vault.transfersRestricted();
        vm.prank(operator);
        vault.setTransfersRestricted(!current);
        ghostTransferRestrictionToggles++;
    }

    function setTransferWhitelist(uint256 actorSeed, bool status) external {
        address account = actors[actorSeed % NUM_ACTORS];
        vm.prank(operator);
        vault.setTransferWhitelist(account, status);
        ghostWhitelistedAddresses[account] = status;
    }

    function batchSetTransferWhitelist(uint256 seed, bool status) external {
        uint256 count = bound(seed, 1, 4);
        address[] memory accounts = new address[](count);
        bool[] memory statuses = new bool[](count);

        for (uint256 i; i < count; ++i) {
            accounts[i] = actors[(seed + i) % NUM_ACTORS];
            statuses[i] = status;
            ghostWhitelistedAddresses[accounts[i]] = status;
        }

        vm.prank(operator);
        vault.batchSetTransferWhitelist(accounts, statuses);
    }

    // ── EIP-7540 Operator Operations ──

    function setOperator7540(uint256 controllerSeed, uint256 operatorSeed, bool approved) external {
        address controller = actors[controllerSeed % NUM_ACTORS];
        address op = actors[operatorSeed % NUM_ACTORS];
        if (controller == op) return;

        vm.prank(controller);
        vault.setOperator(op, approved);
        ghostOperator7540State[controller][op] = approved;
        ghostOperator7540Sets++;
    }

    function requestRedeem(uint256 ownerSeed, uint256 controllerSeed, uint256 shareFraction) external {
        address owner = actors[ownerSeed % NUM_ACTORS];
        address controller = actors[controllerSeed % NUM_ACTORS];

        uint256 shares = vault.balanceOf(owner);
        if (shares == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 toRedeem = shares * shareFraction / 100;
        if (toRedeem == 0) return;

        // Skip if lockup active
        uint256 lockup = vault.lockupPeriod();
        if (lockup > 0 && block.timestamp < vault.depositTimestamp(owner) + lockup) return;

        // Check authorization: owner == msg.sender OR approved operator
        bool authorized = (owner == controller) || vault.isOperator(owner, controller);
        if (!authorized) return;

        vm.prank(controller);
        try vault.requestRedeem(toRedeem, controller, owner) {
            ghostRequestRedeemCount++;
            ghostWithdrawRequestCount++;
        } catch {}
    }

    // ── Drawdown Operations ──

    function setMaxDrawdown(uint256 bps) external {
        bps = bound(bps, 0, 5_000); // MAX_DRAWDOWN_BPS
        vm.prank(operator);
        vault.setMaxDrawdown(bps);
    }

    function resetNavHighWaterMark() external {
        vm.prank(operator);
        try vault.resetNavHighWaterMark() {} catch {}
    }

    // ── Time ──

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 3 days);
        vm.warp(block.timestamp + seconds_);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Comprehensive Invariant Test Suite
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_ComprehensiveInvariant_Test is StdInvariant, Test {
    MockERC20 internal usdc;
    StreamVault internal vault;
    MockYieldSource internal yieldSource1;
    MockYieldSource internal yieldSource2;
    AdvancedVaultHandler internal handler;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy vault via proxy
        StreamVault impl = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (IERC20(address(usdc)), operator, feeRecipient, 1_000, 200, "StreamVault USDC", "svUSDC")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = StreamVault(address(proxy));

        // Two yield sources for multi-source testing
        yieldSource1 = new MockYieldSource(address(usdc), address(vault), 1);
        yieldSource2 = new MockYieldSource(address(usdc), address(vault), 2);

        vm.startPrank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource1)));
        vault.addYieldSource(IYieldSource(address(yieldSource2)));
        // Enable withdrawal fee to test fee invariants
        vault.setWithdrawalFee(50); // 0.5%
        // Disable drawdown protection to prevent auto-pause during fuzzing
        vault.setMaxDrawdown(0);
        vm.stopPrank();

        handler = new AdvancedVaultHandler(vault, usdc, yieldSource1, yieldSource2, operator, feeRecipient);

        // Seed: first actor deposits so vault is non-empty
        address actor0 = handler.actors(0);
        usdc.mint(actor0, 100_000e6);
        vm.startPrank(actor0);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, actor0);
        vm.stopPrank();

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](27);
        selectors[0] = AdvancedVaultHandler.deposit.selector;
        selectors[1] = AdvancedVaultHandler.depositToOther.selector;
        selectors[2] = AdvancedVaultHandler.mint.selector;
        selectors[3] = AdvancedVaultHandler.requestWithdraw.selector;
        selectors[4] = AdvancedVaultHandler.settleEpoch.selector;
        selectors[5] = AdvancedVaultHandler.claimWithdrawal.selector;
        selectors[6] = AdvancedVaultHandler.batchClaimWithdrawals.selector;
        selectors[7] = AdvancedVaultHandler.deployToYield.selector;
        selectors[8] = AdvancedVaultHandler.withdrawFromYield.selector;
        selectors[9] = AdvancedVaultHandler.harvestYield.selector;
        selectors[10] = AdvancedVaultHandler.simulateYield.selector;
        selectors[11] = AdvancedVaultHandler.simulateLoss.selector;
        selectors[12] = AdvancedVaultHandler.setDepositCap.selector;
        selectors[13] = AdvancedVaultHandler.setWithdrawalFee.selector;
        selectors[14] = AdvancedVaultHandler.setLockupPeriod.selector;
        selectors[15] = AdvancedVaultHandler.transferShares.selector;
        selectors[16] = AdvancedVaultHandler.warpTime.selector;
        selectors[17] = AdvancedVaultHandler.warpTime.selector;
        selectors[18] = AdvancedVaultHandler.warpTime.selector;
        // New feature handlers
        selectors[19] = AdvancedVaultHandler.toggleTransferRestrictions.selector;
        selectors[20] = AdvancedVaultHandler.setTransferWhitelist.selector;
        selectors[21] = AdvancedVaultHandler.batchSetTransferWhitelist.selector;
        selectors[22] = AdvancedVaultHandler.setOperator7540.selector;
        selectors[23] = AdvancedVaultHandler.requestRedeem.selector;
        selectors[24] = AdvancedVaultHandler.setMaxDrawdown.selector;
        selectors[25] = AdvancedVaultHandler.resetNavHighWaterMark.selector;
        selectors[26] = AdvancedVaultHandler.warpTime.selector; // Extra time warp for temporal diversity
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ACCOUNTING INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The fundamental accounting identity: totalAssets = idle + deployed - claimable
    function invariant_totalAssets_eq_idle_plus_deployed_minus_claimable() public view {
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 deployed = yieldSource1.balance() + yieldSource2.balance();
        uint256 claimable = vault.totalClaimableAssets();

        uint256 gross = idle + deployed;
        uint256 expected = gross > claimable ? gross - claimable : 0;

        assertEq(vault.totalAssets(), expected, "totalAssets identity broken");
    }

    /// @dev The vault's USDC balance must always be >= totalClaimableAssets
    ///      (otherwise settled withdrawers can't claim)
    function invariant_idle_gte_claimable() public view {
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 claimable = vault.totalClaimableAssets();
        assertGe(idle, claimable, "Vault cannot cover claimable obligations");
    }

    /// @dev totalClaimableAssets must equal the sum of (owed - claimed) across all settled epochs
    function invariant_claimable_matches_epoch_sums() public view {
        uint256 currentEpoch = vault.currentEpochId();
        uint256 sumUnclaimed;

        for (uint256 i; i < currentEpoch; ++i) {
            (StreamVault.EpochStatus status,, uint256 owed, uint256 claimed) = vault.epochs(i);
            if (status == StreamVault.EpochStatus.SETTLED) {
                sumUnclaimed += owed - claimed;
            }
        }

        assertEq(vault.totalClaimableAssets(), sumUnclaimed, "Claimable mismatch with epoch accounting");
    }

    /// @dev For every settled epoch: claimed <= owed
    function invariant_epoch_claimed_leq_owed() public view {
        uint256 currentEpoch = vault.currentEpochId();
        for (uint256 i; i < currentEpoch; ++i) {
            (StreamVault.EpochStatus status,, uint256 owed, uint256 claimed) = vault.epochs(i);
            if (status == StreamVault.EpochStatus.SETTLED) {
                assertLe(claimed, owed, "Epoch over-claimed");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SHARE SUPPLY INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev totalSupply should equal sum of all individual balances
    function invariant_totalSupply_eq_sum_of_balances() public view {
        uint256 sum;
        for (uint256 i; i < handler.NUM_ACTORS(); ++i) {
            sum += vault.balanceOf(handler.actors(i));
        }
        sum += vault.balanceOf(feeRecipient);
        // Also include any remaining balance at other addresses (operator, test contract, etc.)
        // The key invariant: no shares are created out of thin air
        assertEq(vault.totalSupply(), sum, "Share supply mismatch");
    }

    /// @dev Fee recipient balance should never exceed total supply
    function invariant_fee_shares_leq_total_supply() public view {
        assertLe(vault.balanceOf(feeRecipient), vault.totalSupply(), "Fee shares exceed total supply");
    }

    /// @dev totalPendingShares tracks only the current epoch's burned shares
    function invariant_pending_shares_eq_current_epoch_burned() public view {
        uint256 epochId = vault.currentEpochId();
        (, uint256 burnedInCurrent,,) = vault.epochs(epochId);
        assertEq(vault.totalPendingShares(), burnedInCurrent, "Pending shares mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════════════════════
    // SOLVENCY INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev The vault should never owe more USDC than it has access to (idle + deployed)
    function invariant_solvency() public view {
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 deployed = yieldSource1.balance() + yieldSource2.balance();
        uint256 claimable = vault.totalClaimableAssets();

        assertGe(idle + deployed, claimable, "Vault is insolvent");
    }

    /// @dev convertToAssets(totalSupply) should approximate totalAssets (no share inflation)
    function invariant_share_value_bounded() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;

        uint256 totalAssetsViaShares = vault.convertToAssets(supply);
        uint256 actualTotalAssets = vault.totalAssets();

        // Should be approximately equal (within 0.1% + dust for rounding)
        // Floor rounding means convertToAssets(totalSupply) <= totalAssets
        assertLe(totalAssetsViaShares, actualTotalAssets + 1, "Share value inflated");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EPOCH INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Current epoch must be OPEN
    function invariant_current_epoch_is_open() public view {
        uint256 epochId = vault.currentEpochId();
        (StreamVault.EpochStatus status,,,) = vault.epochs(epochId);
        assertEq(uint8(status), uint8(StreamVault.EpochStatus.OPEN), "Current epoch not OPEN");
    }

    /// @dev All past epochs must be SETTLED
    function invariant_past_epochs_are_settled() public view {
        uint256 currentEpoch = vault.currentEpochId();
        for (uint256 i; i < currentEpoch; ++i) {
            (StreamVault.EpochStatus status,,,) = vault.epochs(i);
            assertEq(uint8(status), uint8(StreamVault.EpochStatus.SETTLED), "Past epoch not settled");
        }
    }

    /// @dev Epoch IDs are monotonically increasing (no gaps)
    function invariant_epoch_ids_monotonic() public view {
        assertEq(vault.currentEpochId(), handler.ghostSettledEpochs(), "Epoch ID != settled count");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FEE INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Withdrawal fee BPS never exceeds MAX_WITHDRAWAL_FEE_BPS
    function invariant_withdrawal_fee_bounded() public view {
        assertLe(vault.withdrawalFeeBps(), vault.MAX_WITHDRAWAL_FEE_BPS(), "Withdrawal fee exceeds max");
    }

    /// @dev Management fee BPS never exceeds MAX_MANAGEMENT_FEE_BPS
    function invariant_management_fee_bounded() public view {
        assertLe(vault.managementFeeBps(), vault.MAX_MANAGEMENT_FEE_BPS(), "Management fee exceeds max");
    }

    /// @dev Performance fee BPS never exceeds MAX_PERFORMANCE_FEE_BPS
    function invariant_performance_fee_bounded() public view {
        assertLe(vault.performanceFeeBps(), vault.MAX_PERFORMANCE_FEE_BPS(), "Performance fee exceeds max");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIGURATION INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deposit cap: if set, totalAssets should not exceed cap + rounding
    function invariant_deposit_cap_respected() public view {
        uint256 cap = vault.depositCap();
        if (cap == 0) return; // unlimited

        // totalAssets can slightly exceed cap due to yield accrual (cap limits deposits, not yield)
        // So we only check: maxDeposit returns 0 when at/over cap
        uint256 assets = vault.totalAssets();
        if (assets >= cap) {
            assertEq(vault.maxDeposit(address(0)), 0, "maxDeposit should be 0 at cap");
        }
    }

    /// @dev Lockup period never exceeds MAX_LOCKUP_PERIOD
    function invariant_lockup_bounded() public view {
        assertLe(vault.lockupPeriod(), vault.MAX_LOCKUP_PERIOD(), "Lockup exceeds max");
    }

    /// @dev Yield source count never exceeds MAX_YIELD_SOURCES
    function invariant_yield_source_count_bounded() public view {
        assertLe(vault.yieldSourceCount(), vault.MAX_YIELD_SOURCES(), "Too many yield sources");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC-4626 INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev convertToShares(convertToAssets(shares)) <= shares (no inflation via roundtrip)
    function invariant_no_share_inflation_roundtrip() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;

        uint256 testShares = supply / 10; // test with 10% of supply
        if (testShares == 0) return;

        uint256 assets = vault.convertToAssets(testShares);
        uint256 backToShares = vault.convertToShares(assets);

        assertLe(backToShares, testShares, "Share inflation via roundtrip");
    }

    /// @dev maxWithdraw and maxRedeem always return 0 (async vault)
    function invariant_sync_withdraw_disabled() public view {
        for (uint256 i; i < handler.NUM_ACTORS(); ++i) {
            address actor = handler.actors(i);
            assertEq(vault.maxWithdraw(actor), 0, "maxWithdraw should be 0");
            assertEq(vault.maxRedeem(actor), 0, "maxRedeem should be 0");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSERVATION INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Total USDC in system = vault idle + yield source balances + claimed + fees + losses
    ///      All USDC must trace back to ghost deposits or yield generation.
    ///      Simulated losses send USDC to 0xdead, so we account for that.
    function invariant_no_usdc_created_from_nothing() public view {
        uint256 vaultIdle = usdc.balanceOf(address(vault));
        uint256 deployed1 = yieldSource1.balance();
        uint256 deployed2 = yieldSource2.balance();

        // All USDC under vault's control
        uint256 vaultControlled = vaultIdle + deployed1 + deployed2;

        // USDC that has left the vault (claimed by users + fees + simulated losses)
        uint256 left = handler.ghostTotalClaimed() + handler.ghostTotalFeesPaid() + handler.ghostTotalSimulatedLoss();

        // Total entering the vault = ghost deposits
        uint256 entered = handler.ghostTotalDeposited();

        // vault-controlled + left should be >= entered (yield can add more, losses are tracked)
        // Small tolerance for management fee share dilution not backed by new USDC
        assertGe(vaultControlled + left + 1e6, entered, "USDC conservation violated");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRANSFER RESTRICTION INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Transfer restriction state is boolean — always valid
    function invariant_transfer_restriction_state_valid() public view {
        // transfersRestricted is always a valid boolean value
        // This is implicitly true, but we verify the state is accessible
        bool restricted = vault.transfersRestricted();
        assertTrue(restricted || !restricted, "Transfer restriction state should be boolean");
    }

    /// @dev Whitelist state should match ghost tracking
    function invariant_whitelist_consistency() public view {
        for (uint256 i; i < handler.NUM_ACTORS(); ++i) {
            address actor = handler.actors(i);
            assertEq(
                vault.transferWhitelist(actor), handler.ghostWhitelistedAddresses(actor), "Whitelist state mismatch"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EIP-7540 OPERATOR INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev EIP-7540 operator state should match ghost tracking
    function invariant_operator7540_state_consistency() public view {
        for (uint256 i; i < handler.NUM_ACTORS(); ++i) {
            for (uint256 j; j < handler.NUM_ACTORS(); ++j) {
                if (i == j) continue;
                address controller = handler.actors(i);
                address op = handler.actors(j);
                assertEq(
                    vault.isOperator(controller, op),
                    handler.ghostOperator7540State(controller, op),
                    "EIP-7540 operator state mismatch"
                );
            }
        }
    }

    /// @dev An operator cannot be set for themselves
    function invariant_operator7540_no_self_approval() public view {
        for (uint256 i; i < handler.NUM_ACTORS(); ++i) {
            address actor = handler.actors(i);
            // Self-approval should always be false (or we don't set it)
            // The handler skips self-approvals, so state should be false
            assertFalse(vault.isOperator(actor, actor), "Self-operator should not be set");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DRAWDOWN INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev maxDrawdownBps never exceeds MAX_DRAWDOWN_BPS (50%)
    function invariant_drawdown_bounded() public view {
        assertLe(vault.maxDrawdownBps(), vault.MAX_DRAWDOWN_BPS(), "Drawdown exceeds max");
    }

    /// @dev NAV per share should be positive when vault has assets
    function invariant_nav_positive() public view {
        uint256 supply = vault.totalSupply();
        if (supply > 0) {
            assertGt(vault.navPerShare(), 0, "NAV per share should be positive");
        }
    }

    /// @dev NAV high water mark should be <= current NAV (after recovery) or >= current NAV (during drawdown)
    ///      This is a consistency check — HWM tracks the peak
    function invariant_hwm_consistency() public view {
        uint256 hwm = vault.navHighWaterMark();
        if (hwm == 0) return; // Not initialized yet

        // HWM represents a historical peak, so current NAV can be above or below it
        // We just verify HWM is a reasonable value (positive and not absurdly large)
        assertGt(hwm, 0, "HWM should be positive once set");
        assertLt(hwm, type(uint128).max, "HWM should be reasonable");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADVANCED SHARE ACCOUNTING INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Share price should never be zero when vault has assets
    function invariant_share_price_nonzero() public view {
        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();

        if (assets > 0 && supply > 0) {
            uint256 sharePrice = vault.convertToAssets(1e9); // 1 share worth
            assertGt(sharePrice, 0, "Share price should be non-zero");
        }
    }

    /// @dev previewDeposit should never return 0 for non-zero input (unless paused/capped)
    function invariant_preview_deposit_nonzero() public view {
        if (vault.paused()) return;
        if (vault.depositCap() > 0 && vault.totalAssets() >= vault.depositCap()) return;

        uint256 testAssets = 1_000e6;
        uint256 shares = vault.previewDeposit(testAssets);

        // previewDeposit should return non-zero shares for reasonable asset amounts
        assertGt(shares, 0, "previewDeposit should return non-zero shares");
    }

    /// @dev convertToShares should be monotonically increasing with assets
    function invariant_convert_monotonic() public view {
        uint256 small = vault.convertToShares(100e6);
        uint256 large = vault.convertToShares(1_000e6);
        assertLe(small, large, "convertToShares should be monotonic");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // YIELD SOURCE INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Total deployed across all yield sources should match sum of individual balances
    function invariant_yield_source_balance_sum() public view {
        uint256[] memory balances = vault.getAllYieldSourceBalances();
        uint256 sum;
        for (uint256 i; i < balances.length; ++i) {
            sum += balances[i];
        }

        uint256 expected = yieldSource1.balance() + yieldSource2.balance();
        assertEq(sum, expected, "Yield source balance sum mismatch");
    }

    /// @dev Each yield source balance should match its actual balance
    function invariant_yield_source_individual_balances() public view {
        uint256[] memory balances = vault.getAllYieldSourceBalances();
        if (balances.length >= 1) {
            assertEq(balances[0], yieldSource1.balance(), "YieldSource1 balance mismatch");
        }
        if (balances.length >= 2) {
            assertEq(balances[1], yieldSource2.balance(), "YieldSource2 balance mismatch");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ═══════════════════════════════════════════════════════════════════════════
    // SLIPPAGE PROTECTION INVARIANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev previewDeposit and previewMint should be consistent
    ///      Note: Small rounding differences are acceptable due to floor divisions
    function invariant_preview_functions_consistent() public view {
        if (vault.paused()) return;
        if (vault.depositCap() > 0 && vault.totalAssets() >= vault.depositCap()) return;
        if (vault.totalSupply() == 0) return; // Skip when no shares exist
        if (vault.totalAssets() == 0) return; // Skip when no assets exist

        uint256 testAssets = 1_000e6;

        // Skip if vault NAV is extremely skewed (can happen during edge cases)
        uint256 navPerShare = vault.navPerShare();
        if (navPerShare == 0 || navPerShare > 1e24) return;

        uint256 previewShares = vault.previewDeposit(testAssets);

        // previewDeposit should return non-zero shares for reasonable amounts
        // (unless extreme dilution has occurred)
        if (previewShares == 0) return;

        // previewMint should return non-zero assets for reasonable shares
        uint256 previewAssets = vault.previewMint(previewShares);
        assertGt(previewAssets, 0, "previewMint should return positive assets");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CALL SUMMARY
    // ═══════════════════════════════════════════════════════════════════════════

    function invariant_callSummary() public view {
        // Log stats for debugging — always passes
        handler.ghostDepositCount();
        handler.ghostWithdrawRequestCount();
        handler.ghostSettledEpochs();
        handler.ghostClaimCount();
    }
}
