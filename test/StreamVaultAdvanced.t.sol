// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StreamVault} from "../src/StreamVault.sol";
import {IYieldSource} from "../src/IYieldSource.sol";
import {MockYieldSource} from "../src/MockYieldSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Invariant Handler — randomly sequences vault operations
// ─────────────────────────────────────────────────────────────────────────────

contract VaultHandler is Test {
    StreamVault public vault;
    MockERC20 public usdc;
    MockYieldSource public yieldSource;
    address public operator;

    address[] public actors;
    uint256 public constant NUM_ACTORS = 5;

    // Ghost variables for tracking
    uint256 public ghostTotalDeposited;
    uint256 public ghostTotalClaimed;
    uint256 public ghostSettledEpochs;

    constructor(StreamVault _vault, MockERC20 _usdc, MockYieldSource _yieldSource, address _operator) {
        vault = _vault;
        usdc = _usdc;
        yieldSource = _yieldSource;
        operator = _operator;

        for (uint256 i; i < NUM_ACTORS; ++i) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
        }
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % NUM_ACTORS];
        amount = bound(amount, 1e6, 10_000_000e6);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();

        ghostTotalDeposited += amount;
    }

    function requestWithdraw(uint256 actorSeed, uint256 shareFraction) external {
        address actor = actors[actorSeed % NUM_ACTORS];
        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 toWithdraw = shares * shareFraction / 100;
        if (toWithdraw == 0) return;

        vm.prank(actor);
        vault.requestWithdraw(toWithdraw);
    }

    function settleEpoch() external {
        // Warp past minimum epoch duration
        vm.warp(block.timestamp + 301);

        vm.prank(operator);
        vault.settleEpoch();

        ghostSettledEpochs++;
    }

    function claimWithdrawal(uint256 actorSeed) external {
        address actor = actors[actorSeed % NUM_ACTORS];

        // Try to claim from any settled epoch
        uint256 currentEpoch = vault.currentEpochId();
        for (uint256 i; i < currentEpoch; ++i) {
            (StreamVault.EpochStatus status,,,) = vault.epochs(i);
            if (status != StreamVault.EpochStatus.SETTLED) continue;

            uint256 userShares = vault.getUserWithdrawRequest(i, actor);
            if (userShares == 0) continue;

            uint256 before = usdc.balanceOf(actor);
            vm.prank(actor);
            vault.claimWithdrawal(i);
            ghostTotalClaimed += usdc.balanceOf(actor) - before;
            return;
        }
    }

    function deployToYield(uint256 fraction) external {
        fraction = bound(fraction, 1, 80);
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 claimable = vault.totalClaimableAssets();
        uint256 available = idle > claimable ? idle - claimable : 0;

        uint256 toDeploy = available * fraction / 100;
        if (toDeploy == 0) return;

        vm.prank(operator);
        vault.deployToYield(0, toDeploy);
    }

    function withdrawFromYield(uint256 fraction) external {
        fraction = bound(fraction, 1, 100);
        uint256 deployed = yieldSource.balance();
        if (deployed == 0) return;

        uint256 toWithdraw = deployed * fraction / 100;
        if (toWithdraw == 0) return;

        vm.prank(operator);
        vault.withdrawFromYield(0, toWithdraw);
    }

    function harvestYield() external {
        vm.warp(block.timestamp + 100);

        vm.prank(operator);
        vault.harvestYield();
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 7 days);
        vm.warp(block.timestamp + seconds_);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 11. True Stateful Invariant Tests
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_StatefulInvariant_Test is StdInvariant, Test {
    MockERC20 internal usdc;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;
    VaultHandler internal handler;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new StreamVault(
            IERC20(address(usdc)), operator, feeRecipient, 1_000, 200, 3_600, "StreamVault USDC", "svUSDC"
        );
        yieldSource = new MockYieldSource(address(usdc), address(vault), 1);

        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));

        handler = new VaultHandler(vault, usdc, yieldSource, operator);

        // Seed: first actor deposits so vault is non-empty
        address actor0 = handler.actors(0);
        usdc.mint(actor0, 10_000e6);
        vm.startPrank(actor0);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, actor0);
        vm.stopPrank();

        targetContract(address(handler));

        // Only target handler functions
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.requestWithdraw.selector;
        selectors[2] = VaultHandler.settleEpoch.selector;
        selectors[3] = VaultHandler.claimWithdrawal.selector;
        selectors[4] = VaultHandler.deployToYield.selector;
        selectors[5] = VaultHandler.withdrawFromYield.selector;
        selectors[6] = VaultHandler.harvestYield.selector;
        selectors[7] = VaultHandler.warpTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev totalAssets == idle + deployed - claimable (the fundamental accounting identity)
    function invariant_totalAssetsIdentity() public view {
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 deployed = yieldSource.balance();
        uint256 claimable = vault.totalClaimableAssets();

        uint256 expected = idle + deployed;
        expected = expected > claimable ? expected - claimable : 0;

        assertEq(vault.totalAssets(), expected);
    }

    /// @dev EMA is never below the virtual offset floor
    function invariant_emaNeverBelowVirtualOffset() public view {
        assertGe(vault.emaTotalAssets(), 1_000); // 10^3 = decimalsOffset
    }

    /// @dev Total supply should always be >= fee recipient balance (fees can't exceed total)
    function invariant_feeSharesLeqTotalSupply() public view {
        assertLe(vault.balanceOf(feeRecipient), vault.totalSupply());
    }

    /// @dev totalClaimableAssets should never exceed gross assets (idle + deployed)
    function invariant_claimableNeverExceedsGross() public view {
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 deployed = yieldSource.balance();
        // Allow 1 wei tolerance for rounding
        assertLe(vault.totalClaimableAssets(), idle + deployed + 1);
    }

    /// @dev Settled epoch assetsOwed should never be negative (implicit — uint256)
    ///      and totalAssetsClaimed <= totalAssetsOwed for every settled epoch
    function invariant_epochClaimedLeqOwed() public view {
        uint256 currentEpoch = vault.currentEpochId();
        for (uint256 i; i < currentEpoch; ++i) {
            (StreamVault.EpochStatus status,, uint256 owed, uint256 claimed) = vault.epochs(i);
            if (status == StreamVault.EpochStatus.SETTLED) {
                assertLe(claimed, owed);
            }
        }
    }

    /// @dev totalPendingShares tracks shares burned but not yet settled
    function invariant_pendingSharesConsistency() public view {
        uint256 epochId = vault.currentEpochId();
        (, uint256 burnedInCurrent,,) = vault.epochs(epochId);
        assertEq(vault.totalPendingShares(), burnedInCurrent);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 12. Reentrancy with Malicious ERC-20
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Reentrancy_Test is Test {
    ReentrantERC20 internal reentrantToken;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        reentrantToken = new ReentrantERC20();
        vault =
            new StreamVault(IERC20(address(reentrantToken)), operator, feeRecipient, 1_000, 200, 3_600, "RV", "rVault");
        yieldSource = new MockYieldSource(address(reentrantToken), address(vault), 0);

        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));

        // Attacker deposits
        reentrantToken.mint(attacker, 10_000e6);
        vm.startPrank(attacker);
        reentrantToken.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, attacker);
        vm.stopPrank();

        // Warp past minimum epoch duration and EMA convergence
        vm.warp(block.timestamp + 3_601);
    }

    function test_reentrancy_claimWithdrawal_blocked() public {
        uint256 shares = vault.balanceOf(attacker);

        vm.prank(attacker);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.settleEpoch();

        // Set up reentrant attack: when transfer happens during claim,
        // try to call claimWithdrawal again
        reentrantToken.setAttack(
            address(vault), abi.encodeWithSelector(StreamVault.claimWithdrawal.selector, uint256(0))
        );

        // The claim should succeed but the reentrant call should fail silently
        // (ReentrancyGuard reverts the inner call, outer succeeds)
        vm.prank(attacker);
        vault.claimWithdrawal(0);

        // Attacker should only get paid once
        assertGt(reentrantToken.balanceOf(attacker), 0);

        // Verify the request is zeroed out (can't claim again)
        uint256 remainingShares = vault.getUserWithdrawRequest(0, attacker);
        assertEq(remainingShares, 0);
    }

    function test_reentrancy_deposit_blocked() public {
        // Set up reentrant attack on transferFrom during deposit
        reentrantToken.setAttack(address(vault), abi.encodeWithSelector(vault.deposit.selector, uint256(1e6), attacker));

        reentrantToken.mint(attacker, 1e6);
        vm.startPrank(attacker);
        reentrantToken.approve(address(vault), 1e6);
        // The deposit will trigger transferFrom which tries to reenter deposit
        // The inner call reverts with ReentrancyGuardReentrantCall, outer succeeds
        vault.deposit(1e6, attacker);
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 13. ERC-4626 Compliance Suite
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_ERC4626Compliance_Test is Test {
    MockERC20 internal usdc;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new StreamVault(
            IERC20(address(usdc)), operator, feeRecipient, 1_000, 200, 3_600, "StreamVault USDC", "svUSDC"
        );
        yieldSource = new MockYieldSource(address(usdc), address(vault), 1);

        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));
    }

    // ── ERC-4626 MUST properties ──

    /// @dev asset() MUST return the underlying token address
    function test_erc4626_asset() public view {
        assertEq(vault.asset(), address(usdc));
    }

    /// @dev totalAssets() MUST NOT revert
    function test_erc4626_totalAssets_doesNotRevert() public view {
        vault.totalAssets();
    }

    /// @dev convertToShares MUST NOT revert for any reasonable input
    function test_erc4626_convertToShares() public view {
        uint256 shares = vault.convertToShares(1_000e6);
        assertGt(shares, 0);
    }

    /// @dev convertToAssets MUST NOT revert for any reasonable input
    function test_erc4626_convertToAssets() public view {
        uint256 assets = vault.convertToAssets(1_000e9); // shares have 9 decimals (6+3)
        assertGt(assets, 0);
    }

    /// @dev maxDeposit MUST return a valid amount
    function test_erc4626_maxDeposit() public view {
        uint256 max = vault.maxDeposit(alice);
        assertGt(max, 0);
    }

    /// @dev maxMint MUST return a valid amount
    function test_erc4626_maxMint() public view {
        uint256 max = vault.maxMint(alice);
        assertGt(max, 0);
    }

    /// @dev maxWithdraw MUST return 0 (async vault — sync withdrawals disabled)
    function test_erc4626_maxWithdraw_zero() public view {
        assertEq(vault.maxWithdraw(alice), 0);
    }

    /// @dev maxRedeem MUST return 0 (async vault — sync redeems disabled)
    function test_erc4626_maxRedeem_zero() public view {
        assertEq(vault.maxRedeem(alice), 0);
    }

    /// @dev previewDeposit MUST return close to actual deposit shares
    function test_erc4626_previewDeposit_accuracy() public {
        uint256 preview = vault.previewDeposit(1_000e6);

        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 actual = vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertEq(actual, preview);
    }

    /// @dev previewMint MUST return close to actual mint assets
    function test_erc4626_previewMint_accuracy() public {
        uint256 sharesToMint = 1_000e9;
        uint256 preview = vault.previewMint(sharesToMint);

        usdc.mint(alice, preview);
        vm.startPrank(alice);
        usdc.approve(address(vault), preview);
        uint256 actualAssets = vault.mint(sharesToMint, alice);
        vm.stopPrank();

        assertEq(actualAssets, preview);
    }

    /// @dev deposit MUST mint exact shares returned by previewDeposit
    function test_erc4626_deposit_mintsExactPreview() public {
        uint256 depositAmt = 5_000e6;
        uint256 expectedShares = vault.previewDeposit(depositAmt);

        usdc.mint(alice, depositAmt);
        vm.startPrank(alice);
        usdc.approve(address(vault), depositAmt);
        uint256 shares = vault.deposit(depositAmt, alice);
        vm.stopPrank();

        assertEq(shares, expectedShares);
        assertEq(vault.balanceOf(alice), shares);
    }

    /// @dev deposit to a different receiver
    function test_erc4626_deposit_differentReceiver() public {
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = vault.deposit(1_000e6, bob);
        vm.stopPrank();

        assertEq(vault.balanceOf(bob), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// @dev mint MUST take exact assets returned by previewMint
    function test_erc4626_mint_takesExactPreview() public {
        uint256 sharesToMint = 1_000e9;
        uint256 expectedAssets = vault.previewMint(sharesToMint);

        usdc.mint(alice, expectedAssets);
        vm.startPrank(alice);
        usdc.approve(address(vault), expectedAssets);
        uint256 assets = vault.mint(sharesToMint, alice);
        vm.stopPrank();

        assertEq(assets, expectedAssets);
        assertEq(vault.balanceOf(alice), sharesToMint);
    }

    /// @dev withdraw MUST revert (async vault)
    function test_erc4626_withdraw_reverts() public {
        vm.expectRevert("Use requestWithdraw");
        vault.withdraw(100, alice, alice);
    }

    /// @dev redeem MUST revert (async vault)
    function test_erc4626_redeem_reverts() public {
        vm.expectRevert("Use requestWithdraw");
        vault.redeem(100, alice, alice);
    }

    /// @dev previewWithdraw MUST revert (async vault)
    function test_erc4626_previewWithdraw_reverts() public {
        vm.expectRevert("Use requestWithdraw");
        vault.previewWithdraw(100);
    }

    /// @dev previewRedeem MUST revert (async vault)
    function test_erc4626_previewRedeem_reverts() public {
        vm.expectRevert("Use requestWithdraw");
        vault.previewRedeem(100);
    }

    /// @dev decimals MUST return underlying decimals + decimalsOffset
    function test_erc4626_decimals() public view {
        // USDC = 6 decimals, offset = 3
        assertEq(vault.decimals(), 6 + 3);
    }

    /// @dev convertToShares → convertToAssets roundtrip should preserve value (floor rounding)
    function test_erc4626_roundtrip_sharesToAssets() public {
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, alice);
        vm.stopPrank();

        uint256 assets = 1_000e6;
        uint256 shares = vault.convertToShares(assets);
        uint256 backToAssets = vault.convertToAssets(shares);

        // Floor rounding means backToAssets <= assets
        assertLe(backToAssets, assets);
        // But should be very close
        assertApproxEqAbs(backToAssets, assets, 2);
    }

    /// @dev Fuzz: previewDeposit == actual deposit shares
    function testFuzz_erc4626_previewDeposit_eq_actual(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6);
        uint256 preview = vault.previewDeposit(amount);

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 actual = vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(actual, preview);
    }

    /// @dev Fuzz: convertToShares is monotonically increasing
    function testFuzz_erc4626_convertToShares_monotonic(uint256 a, uint256 b) public {
        a = bound(a, 1, 100_000_000e6);
        b = bound(b, a, 100_000_000e6);

        // Seed a deposit first so conversion isn't purely virtual
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, alice);
        vm.stopPrank();

        assertLe(vault.convertToShares(a), vault.convertToShares(b));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 14. View Functions & Batch Claim Tests
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_ViewAndBatch_Test is Test {
    MockERC20 internal usdc;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant INITIAL_DEPOSIT = 1_000e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new StreamVault(
            IERC20(address(usdc)), operator, feeRecipient, 1_000, 200, 3_600, "StreamVault USDC", "svUSDC"
        );
        yieldSource = new MockYieldSource(address(usdc), address(vault), 1);

        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));
    }

    function _mintAndDeposit(address user, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    // ── View function tests ──

    function test_getUserWithdrawRequest() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3_601);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        uint256 requested = vault.getUserWithdrawRequest(0, alice);
        assertEq(requested, shares);

        // Non-requestor has 0
        assertEq(vault.getUserWithdrawRequest(0, bob), 0);
    }

    function test_getEpochInfo() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3_601);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.settleEpoch();

        (StreamVault.EpochStatus status, uint256 burned, uint256 owed, uint256 claimed) = vault.getEpochInfo(0);
        assertEq(uint8(status), 1); // SETTLED
        assertEq(burned, shares);
        assertGt(owed, 0);
        assertEq(claimed, 0);
    }

    function test_getAllYieldSourceBalances() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3_601);

        vm.prank(operator);
        vault.deployToYield(0, 500e6);

        uint256[] memory balances = vault.getAllYieldSourceBalances();
        assertEq(balances.length, 1);
        assertEq(balances[0], 500e6);
    }

    function test_getAllYieldSources() public view {
        address[] memory sources = vault.getAllYieldSources();
        assertEq(sources.length, 1);
        assertEq(sources[0], address(yieldSource));
    }

    function test_idleBalance() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3_601);

        assertEq(vault.idleBalance(), INITIAL_DEPOSIT);

        // Deploy half
        vm.prank(operator);
        vault.deployToYield(0, 500e6);

        assertEq(vault.idleBalance(), 500e6);
    }

    function test_idleBalance_excludesClaimable() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        _mintAndDeposit(bob, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3_601);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(aliceShares);

        vm.prank(operator);
        vault.settleEpoch();

        uint256 idle = vault.idleBalance();
        uint256 rawIdle = usdc.balanceOf(address(vault));
        uint256 claimable = vault.totalClaimableAssets();

        assertEq(idle, rawIdle - claimable);
    }

    // ── Batch claim tests ──

    function test_batchClaimWithdrawals_multiEpoch() public {
        // Alice and Bob both deposit
        _mintAndDeposit(alice, 5_000e6);
        _mintAndDeposit(bob, 5_000e6);
        vm.warp(block.timestamp + 3_601); // full EMA convergence

        // Epoch 0: Alice withdraws a quarter of her shares
        uint256 quarter = vault.balanceOf(alice) / 4;
        vm.prank(alice);
        vault.requestWithdraw(quarter);
        vm.prank(operator);
        vault.settleEpoch();

        // Epoch 1: Alice withdraws another quarter
        vm.warp(block.timestamp + 3_601); // full convergence again
        uint256 anotherQuarter = vault.balanceOf(alice) / 3; // ~quarter of original
        vm.prank(alice);
        vault.requestWithdraw(anotherQuarter);
        vm.prank(operator);
        vault.settleEpoch();

        // Batch claim both epochs at once
        uint256 balBefore = usdc.balanceOf(alice);
        uint256[] memory epochIds = new uint256[](2);
        epochIds[0] = 0;
        epochIds[1] = 1;

        vm.prank(alice);
        vault.batchClaimWithdrawals(epochIds);

        uint256 received = usdc.balanceOf(alice) - balBefore;
        assertGt(received, 0);

        // Verify both claims are zeroed
        assertEq(vault.getUserWithdrawRequest(0, alice), 0);
        assertEq(vault.getUserWithdrawRequest(1, alice), 0);
    }

    function test_batchClaimWithdrawals_revertsIfUnsettled() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3_601);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        // Don't settle — try batch claim on unsettled epoch
        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 0;

        vm.prank(alice);
        vm.expectRevert(StreamVault.EpochNotSettled.selector);
        vault.batchClaimWithdrawals(epochIds);
    }

    function test_batchClaimWithdrawals_revertsIfNoRequest() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3_601);

        vm.prank(operator);
        vault.settleEpoch();

        // Bob has no request in epoch 0
        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 0;

        vm.prank(bob);
        vm.expectRevert(StreamVault.NoRequestInEpoch.selector);
        vault.batchClaimWithdrawals(epochIds);
    }
}
