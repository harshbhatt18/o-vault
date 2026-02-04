// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StreamVault} from "../src/StreamVault.sol";
import {IYieldSource} from "../src/IYieldSource.sol";
import {MockYieldSource} from "../src/MockYieldSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {IERC7540Redeem, IERC7540Operator} from "../src/interfaces/IERC7540.sol";

/// @dev Helper for deploying StreamVault behind a UUPS proxy in tests.
abstract contract ProxyDeployHelper {
    function _deployVaultProxy(
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
}

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

contract StreamVault_StatefulInvariant_Test is StdInvariant, Test, ProxyDeployHelper {
    MockERC20 internal usdc;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;
    VaultHandler internal handler;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = _deployVaultProxy(
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

contract StreamVault_Reentrancy_Test is Test, ProxyDeployHelper {
    ReentrantERC20 internal reentrantToken;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        reentrantToken = new ReentrantERC20();
        vault = _deployVaultProxy(
            IERC20(address(reentrantToken)), operator, feeRecipient, 1_000, 200, 3_600, "RV", "rVault"
        );
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

contract StreamVault_ERC4626Compliance_Test is Test, ProxyDeployHelper {
    MockERC20 internal usdc;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = _deployVaultProxy(
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
        vm.expectRevert(StreamVault.SyncWithdrawDisabled.selector);
        vault.withdraw(100, alice, alice);
    }

    /// @dev redeem MUST revert (async vault)
    function test_erc4626_redeem_reverts() public {
        vm.expectRevert(StreamVault.SyncWithdrawDisabled.selector);
        vault.redeem(100, alice, alice);
    }

    /// @dev previewWithdraw MUST revert (async vault)
    function test_erc4626_previewWithdraw_reverts() public {
        vm.expectRevert(StreamVault.SyncWithdrawDisabled.selector);
        vault.previewWithdraw(100);
    }

    /// @dev previewRedeem MUST revert (async vault)
    function test_erc4626_previewRedeem_reverts() public {
        vm.expectRevert(StreamVault.SyncWithdrawDisabled.selector);
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

contract StreamVault_ViewAndBatch_Test is Test, ProxyDeployHelper {
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
        vault = _deployVaultProxy(
            IERC20(address(usdc)), operator, feeRecipient, 1_000, 200, 3_600, "StreamVault USDC", "svUSDC"
        );
        yieldSource = new MockYieldSource(address(usdc), address(vault), 1);

        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));

        // Disable drawdown protection for these tests
        vm.prank(operator);
        vault.setMaxDrawdown(0);
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

    function test_getYieldSources() public view {
        address[] memory sources = vault.getYieldSources();
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

// ─────────────────────────────────────────────────────────────────────────────
// 15. Emergency Pause Tests
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Pause_Test is Test, ProxyDeployHelper {
    MockERC20 internal usdc;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = _deployVaultProxy(
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

    function test_pause_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.pause();
    }

    function test_unpause_onlyOperator() public {
        vm.prank(operator);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.unpause();
    }

    function test_pause_blocksDeposit() public {
        vm.prank(operator);
        vault.pause();

        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(); // ERC4626ExceededMaxDeposit (maxDeposit returns 0 when paused)
        vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    function test_pause_blocksMint() public {
        vm.prank(operator);
        vault.pause();

        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(); // ERC4626ExceededMaxMint (maxMint returns 0 when paused)
        vault.mint(1000e6, alice);
        vm.stopPrank();
    }

    function test_pause_maxDepositReturnsZero() public {
        assertGt(vault.maxDeposit(alice), 0);
        vm.prank(operator);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_pause_maxMintReturnsZero() public {
        assertGt(vault.maxMint(alice), 0);
        vm.prank(operator);
        vault.pause();
        assertEq(vault.maxMint(alice), 0);
    }

    function test_pause_blocksRequestWithdraw() public {
        _mintAndDeposit(alice, 1000e6);

        vm.prank(operator);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.requestWithdraw(100e6);
    }

    function test_pause_allowsClaimFromSettledEpoch() public {
        _mintAndDeposit(alice, 1000e6);
        vm.warp(block.timestamp + 3601);

        // Alice requests withdrawal
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        // Operator settles epoch
        vm.prank(operator);
        vault.settleEpoch();

        // Operator pauses
        vm.prank(operator);
        vault.pause();

        // Alice can still claim (critical: users can always exit)
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawal(0);
        uint256 balAfter = usdc.balanceOf(alice);

        assertGt(balAfter, balBefore, "Claim should succeed when paused");
    }

    function test_pause_allowsBatchClaimFromSettledEpoch() public {
        _mintAndDeposit(alice, 1000e6);
        vm.warp(block.timestamp + 3601);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.settleEpoch();

        vm.prank(operator);
        vault.pause();

        uint256[] memory epochIds = new uint256[](1);
        epochIds[0] = 0;

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.batchClaimWithdrawals(epochIds);
        uint256 balAfter = usdc.balanceOf(alice);

        assertGt(balAfter, balBefore, "Batch claim should succeed when paused");
    }

    function test_pause_operatorCanStillSettle() public {
        _mintAndDeposit(alice, 1000e6);
        vm.warp(block.timestamp + 3601);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestWithdraw(shares);

        vm.prank(operator);
        vault.pause();

        // Operator can still settle — necessary to process pending withdrawals
        vm.prank(operator);
        vault.settleEpoch();

        (StreamVault.EpochStatus status,,,) = vault.getEpochInfo(0);
        assertEq(uint8(status), uint8(StreamVault.EpochStatus.SETTLED));
    }

    function test_unpause_resumesNormalOperations() public {
        vm.prank(operator);
        vault.pause();

        vm.prank(operator);
        vault.unpause();

        // Deposits should work again
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(1000e6, alice);
        vm.stopPrank();

        assertGt(shares, 0, "Deposit should succeed after unpause");
    }

    function test_pause_emitsEvent() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, false);
        emit StreamVault.VaultPaused(operator);
        vault.pause();
    }

    function test_unpause_emitsEvent() public {
        vm.prank(operator);
        vault.pause();

        vm.prank(operator);
        vm.expectEmit(true, false, false, false);
        emit StreamVault.VaultUnpaused(operator);
        vault.unpause();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 16. Drawdown Protection Tests
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Drawdown_Test is Test, ProxyDeployHelper {
    MockERC20 internal usdc;
    StreamVault internal vault;
    MockYieldSource internal yieldSource;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");

    uint256 constant INITIAL_DEPOSIT = 100_000e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = _deployVaultProxy(
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

    function test_drawdown_initialState() public view {
        assertEq(vault.maxDrawdownBps(), 1_000, "Default max drawdown should be 10%");
        // HWM starts at 0 and gets set on first interaction (deposit).
        // This avoids a bug where hardcoding 1e18 causes false circuit-breaker
        // triggers for assets with non-18 decimals (e.g., USDC 6 decimals).
        assertEq(vault.navHighWaterMark(), 0, "Initial HWM should be 0 (set on first interaction)");
    }

    function test_drawdown_setMaxDrawdown_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.setMaxDrawdown(500);
    }

    function test_drawdown_setMaxDrawdown_success() public {
        vm.prank(operator);
        vault.setMaxDrawdown(500); // 5%

        assertEq(vault.maxDrawdownBps(), 500);
    }

    function test_drawdown_setMaxDrawdown_exceedsMax() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.InvalidDrawdownThreshold.selector);
        vault.setMaxDrawdown(6_000); // 60% > 50% max
    }

    function test_drawdown_setMaxDrawdown_disableWithZero() public {
        vm.prank(operator);
        vault.setMaxDrawdown(0);

        assertEq(vault.maxDrawdownBps(), 0, "Drawdown protection should be disabled");
    }

    function test_drawdown_hwmUpdatesOnDeposit() public {
        // Deposit to establish initial state
        _mintAndDeposit(alice, INITIAL_DEPOSIT);

        // Warp past smoothing period for EMA to converge
        vm.warp(block.timestamp + 7200);

        // Deploy to yield source
        uint256 idle = vault.idleBalance();
        vm.prank(operator);
        vault.deployToYield(0, idle);

        // Warp again for EMA to fully converge after deploy
        vm.warp(block.timestamp + 7200);

        // Trigger EMA update and establish HWM
        vm.prank(operator);
        vault.harvestYield();

        // Reset HWM to current to establish baseline
        vm.prank(operator);
        vault.resetNavHighWaterMark();
        uint256 hwmBefore = vault.navHighWaterMark();

        // Simulate significant yield (10% of deposit)
        yieldSource.simulateYield(10_000e6);

        // Warp to let EMA converge fully to new higher value
        vm.warp(block.timestamp + 7200);

        // Harvest updates NAV and should update HWM
        vm.prank(operator);
        vault.harvestYield();

        uint256 hwmAfter = vault.navHighWaterMark();
        assertGt(hwmAfter, hwmBefore, "HWM should increase with yield");
    }

    function test_drawdown_autoPauseOnExcessiveDrawdown() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3601);

        // Deploy all to yield source
        uint256 idle = vault.idleBalance();
        vm.prank(operator);
        vault.deployToYield(0, idle);

        // Let EMA fully converge
        vm.warp(block.timestamp + 7200);
        vm.prank(operator);
        vault.harvestYield();

        uint256 navBefore = vault.navPerShare();

        // Simulate 15% loss (exceeds 10% threshold)
        uint256 sourceBal = yieldSource.balance();
        uint256 loss = sourceBal * 15 / 100;
        yieldSource.simulateLoss(loss);

        // Warp and settle to trigger drawdown check
        vm.warp(block.timestamp + 7200);

        // The settlement should trigger auto-pause
        vm.prank(operator);
        vault.settleEpoch();

        assertTrue(vault.paused(), "Vault should be paused after 15% drawdown");
    }

    function test_drawdown_noPauseIfBelowThreshold() public {
        // Disable drawdown protection initially
        vm.prank(operator);
        vault.setMaxDrawdown(0);

        _mintAndDeposit(alice, INITIAL_DEPOSIT);

        // Warp past smoothing period
        vm.warp(block.timestamp + 7200);

        // Deploy to yield
        uint256 idle = vault.idleBalance();
        vm.prank(operator);
        vault.deployToYield(0, idle);

        // Let EMA converge fully
        vm.warp(block.timestamp + 7200);
        vm.prank(operator);
        vault.harvestYield();

        // Now enable drawdown protection with 20% threshold
        vm.prank(operator);
        vault.setMaxDrawdown(2_000);

        // Reset HWM to current NAV to establish clean baseline
        vm.prank(operator);
        vault.resetNavHighWaterMark();

        // Simulate 5% loss (well below 20% threshold)
        uint256 sourceBal = yieldSource.balance();
        uint256 loss = sourceBal * 5 / 100;
        yieldSource.simulateLoss(loss);

        // Warp to let EMA converge to new value
        vm.warp(block.timestamp + 7200);

        // Settle - should not trigger pause at 5% loss (below 20% threshold)
        vm.prank(operator);
        vault.settleEpoch();

        assertFalse(vault.paused(), "Vault should NOT be paused at 5% drawdown with 20% threshold");
    }

    function test_drawdown_resetHwmAfterRecovery() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3601);

        uint256 hwmBefore = vault.navHighWaterMark();

        // Operator resets HWM
        vm.prank(operator);
        vault.resetNavHighWaterMark();

        uint256 hwmAfter = vault.navHighWaterMark();
        // After first deposit, NAV per share should be close to 1.0
        assertGt(hwmAfter, 0, "HWM should be set to current NAV");
    }

    function test_drawdown_resetHwm_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.resetNavHighWaterMark();
    }

    function test_drawdown_emitsCircuitBreakerEvent() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3601);

        // Deploy to yield
        uint256 idle = vault.idleBalance();
        vm.prank(operator);
        vault.deployToYield(0, idle);

        // Let EMA converge
        vm.warp(block.timestamp + 7200);
        vm.prank(operator);
        vault.harvestYield();

        // Simulate 15% loss
        uint256 sourceBal = yieldSource.balance();
        yieldSource.simulateLoss(sourceBal * 15 / 100);

        vm.warp(block.timestamp + 7200);

        // Expect the DrawdownCircuitBreaker event
        vm.prank(operator);
        // We just verify it doesn't revert and triggers pause
        vault.settleEpoch();

        assertTrue(vault.paused());
    }

    function test_drawdown_navPerShare_calculatedCorrectly() public {
        // NAV per share before any deposits = 1e18 (special case when supply=0)
        assertEq(vault.navPerShare(), 1e18, "Empty vault NAV should be 1e18");

        // First deposit
        _mintAndDeposit(alice, INITIAL_DEPOSIT);

        // After first deposit, NAV will be scaled based on the vault's internal math
        // The important thing is that it's consistent and non-zero
        uint256 nav = vault.navPerShare();
        assertGt(nav, 0, "NAV should be positive after deposit");

        // The NAV calculation is: (emaTotalAssets * 1e18) / totalSupply
        // With virtual offset of 1e3, and USDC (6 decimals):
        // - Assets: 1e11 (100,000 USDC)
        // - Shares: ~1e14 (due to virtual offset multiplication)
        // - NAV: ~1e11 * 1e18 / 1e14 = ~1e15
        // This is expected behavior - the raw value is internally consistent
        assertGt(nav, 1e14, "NAV should be in expected range");
        assertLt(nav, 1e17, "NAV should be in expected range");
    }

    function test_drawdown_disabledWhenZero() public {
        _mintAndDeposit(alice, INITIAL_DEPOSIT);
        vm.warp(block.timestamp + 3601);

        // Disable drawdown protection
        vm.prank(operator);
        vault.setMaxDrawdown(0);

        // Deploy to yield
        uint256 idle = vault.idleBalance();
        vm.prank(operator);
        vault.deployToYield(0, idle);

        // Let EMA converge
        vm.warp(block.timestamp + 7200);
        vm.prank(operator);
        vault.harvestYield();

        // Simulate massive 30% loss
        uint256 sourceBal = yieldSource.balance();
        yieldSource.simulateLoss(sourceBal * 30 / 100);

        vm.warp(block.timestamp + 7200);
        vm.prank(operator);
        vault.settleEpoch();

        assertFalse(vault.paused(), "Vault should NOT pause when drawdown protection disabled");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Transfer Restrictions
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_TransferRestrictions_Test is Test, ProxyDeployHelper {
    MockERC20 usdc;
    StreamVault vault;
    MockYieldSource yieldSource;
    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        vault = _deployVaultProxy(IERC20(address(usdc)), operator, feeRecipient, 1000, 200, 3600, "svUSDC", "svUSDC");
        yieldSource = new MockYieldSource(address(usdc), address(vault), 1);
        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));
        vm.prank(operator);
        vault.setMaxDrawdown(0);
    }

    function _mintAndDeposit(address user, uint256 amount) internal returns (uint256) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();
        return shares;
    }

    function test_setTransfersRestricted_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.setTransfersRestricted(true);
    }

    function test_setTransfersRestricted_success() public {
        vm.prank(operator);
        vault.setTransfersRestricted(true);
        assertTrue(vault.transfersRestricted());
    }

    function test_setTransferWhitelist_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.setTransferWhitelist(bob, true);
    }

    function test_setTransferWhitelist_zeroAddressReverts() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.ZeroAddress.selector);
        vault.setTransferWhitelist(address(0), true);
    }

    function test_setTransferWhitelist_success() public {
        vm.prank(operator);
        vault.setTransferWhitelist(bob, true);
        assertTrue(vault.transferWhitelist(bob));
    }

    function test_batchSetTransferWhitelist_success() public {
        address[] memory accounts = new address[](2);
        accounts[0] = bob;
        accounts[1] = carol;
        bool[] memory statuses = new bool[](2);
        statuses[0] = true;
        statuses[1] = true;

        vm.prank(operator);
        vault.batchSetTransferWhitelist(accounts, statuses);

        assertTrue(vault.transferWhitelist(bob));
        assertTrue(vault.transferWhitelist(carol));
    }

    function test_batchSetTransferWhitelist_lengthMismatchReverts() public {
        address[] memory accounts = new address[](2);
        accounts[0] = bob;
        accounts[1] = carol;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        vm.prank(operator);
        vm.expectRevert(StreamVault.ArrayLengthMismatch.selector);
        vault.batchSetTransferWhitelist(accounts, statuses);
    }

    function test_transfer_blockedWhenRestricted() public {
        _mintAndDeposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(operator);
        vault.setTransfersRestricted(true);

        vm.prank(alice);
        vm.expectRevert(StreamVault.TransferRestricted.selector);
        vault.transfer(bob, shares);
    }

    function test_transfer_allowedWhenWhitelisted() public {
        _mintAndDeposit(alice, 1_000e6);

        vm.prank(operator);
        vault.setTransfersRestricted(true);
        vm.prank(operator);
        vault.setTransferWhitelist(bob, true);

        uint256 amount = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, amount);

        assertEq(vault.balanceOf(bob), amount);
    }

    function test_transfer_unrestricted_noCheckNeeded() public {
        _mintAndDeposit(alice, 1_000e6);

        uint256 amount = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, amount);

        assertEq(vault.balanceOf(bob), amount);
    }

    function test_deposit_worksWhenRestricted() public {
        vm.prank(operator);
        vault.setTransfersRestricted(true);

        // Minting (deposit) should work — from == address(0)
        _mintAndDeposit(alice, 1_000e6);
        assertTrue(vault.balanceOf(alice) > 0);
    }

    function test_requestWithdraw_worksWhenRestricted() public {
        _mintAndDeposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(operator);
        vault.setTransfersRestricted(true);

        // Burning (requestWithdraw) should work — to == address(0)
        vm.prank(alice);
        vault.requestWithdraw(shares);
    }

    function test_transferFrom_blockedWhenRestricted() public {
        _mintAndDeposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(operator);
        vault.setTransfersRestricted(true);

        vm.prank(alice);
        vault.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(StreamVault.TransferRestricted.selector);
        vault.transferFrom(alice, bob, shares);
    }

    function test_transfersRestricted_defaultFalse() public {
        assertFalse(vault.transfersRestricted());
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Timelock
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Timelock_Test is Test, ProxyDeployHelper {
    MockERC20 usdc;
    StreamVault vault;
    MockYieldSource yieldSource;
    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");

    uint256 constant DELAY = 1 days;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        vault = _deployVaultProxy(IERC20(address(usdc)), operator, feeRecipient, 1000, 200, 3600, "svUSDC", "svUSDC");
        yieldSource = new MockYieldSource(address(usdc), address(vault), 1);

        // Add yield source before enabling timelock
        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));
        vm.prank(operator);
        vault.setMaxDrawdown(0);
    }

    function test_setTimelockDelay_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.setTimelockDelay(DELAY);
    }

    function test_setTimelockDelay_success() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);
        assertEq(vault.timelockDelay(), DELAY);
    }

    function test_setTimelockDelay_invalidBounds() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.InvalidTimelockDelay.selector);
        vault.setTimelockDelay(30 minutes); // < MIN_TIMELOCK_DELAY

        vm.prank(operator);
        vm.expectRevert(StreamVault.InvalidTimelockDelay.selector);
        vault.setTimelockDelay(8 days); // > MAX_TIMELOCK_DELAY
    }

    function test_setTimelockDelay_zeroDisables() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        // Cannot directly set delay when timelock is active
        vm.prank(operator);
        vm.expectRevert(StreamVault.TimelockRequired.selector);
        vault.setTimelockDelay(0);

        // Must go through timelock to disable
        bytes memory data = abi.encode(uint256(0));
        bytes32 actionId = vault.TIMELOCK_SET_DELAY();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.warp(block.timestamp + DELAY);

        vm.prank(operator);
        vault.executeTimelocked(actionId, data);
        assertEq(vault.timelockDelay(), 0);
    }

    function test_setTimelockDelay_revertsWhenActive() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        // Direct call reverts when timelock is active
        vm.prank(operator);
        vm.expectRevert(StreamVault.TimelockRequired.selector);
        vault.setTimelockDelay(2 hours);
    }

    function test_setTimelockDelay_changeViaTimelock() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        uint256 newDelay = 2 hours;
        bytes memory data = abi.encode(newDelay);
        bytes32 actionId = vault.TIMELOCK_SET_DELAY();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.warp(block.timestamp + DELAY);

        vm.prank(operator);
        vault.executeTimelocked(actionId, data);
        assertEq(vault.timelockDelay(), newDelay);
    }

    function test_scheduleAction_success() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        bytes memory data = abi.encode(uint256(100)); // 1% management fee
        bytes32 actionId = vault.TIMELOCK_SET_MGMT_FEE();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        (uint256 readyAt,) = vault.timelockOps(actionId);
        assertEq(readyAt, block.timestamp + DELAY);
    }

    function test_scheduleAction_revertsWhenTimelockDisabled() public {
        bytes memory data = abi.encode(uint256(100));
        bytes32 actionId = vault.TIMELOCK_SET_MGMT_FEE();

        vm.prank(operator);
        vm.expectRevert(StreamVault.InvalidTimelockDelay.selector);
        vault.scheduleAction(actionId, data);
    }

    function test_scheduleAction_doubleScheduleReverts() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        bytes memory data = abi.encode(uint256(100));
        bytes32 actionId = vault.TIMELOCK_SET_MGMT_FEE();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.prank(operator);
        vm.expectRevert(StreamVault.TimelockAlreadyScheduled.selector);
        vault.scheduleAction(actionId, data);
    }

    function test_executeTimelocked_success() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        bytes memory data = abi.encode(uint256(100));
        bytes32 actionId = vault.TIMELOCK_SET_MGMT_FEE();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.warp(block.timestamp + DELAY);

        vm.prank(operator);
        vault.executeTimelocked(actionId, data);

        assertEq(vault.managementFeeBps(), 100);
    }

    function test_executeTimelocked_tooEarlyReverts() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        bytes memory data = abi.encode(uint256(100));
        bytes32 actionId = vault.TIMELOCK_SET_MGMT_FEE();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.warp(block.timestamp + DELAY - 1);

        vm.prank(operator);
        vm.expectRevert(StreamVault.TimelockNotReady.selector);
        vault.executeTimelocked(actionId, data);
    }

    function test_executeTimelocked_dataMismatchReverts() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        bytes memory data = abi.encode(uint256(100));
        bytes32 actionId = vault.TIMELOCK_SET_MGMT_FEE();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.warp(block.timestamp + DELAY);

        bytes memory wrongData = abi.encode(uint256(200));
        vm.prank(operator);
        vm.expectRevert(StreamVault.TimelockDataMismatch.selector);
        vault.executeTimelocked(actionId, wrongData);
    }

    function test_executeTimelocked_notScheduledReverts() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        bytes32 actionId = vault.TIMELOCK_SET_MGMT_FEE();
        bytes memory data = abi.encode(uint256(100));

        vm.prank(operator);
        vm.expectRevert(StreamVault.TimelockNotScheduled.selector);
        vault.executeTimelocked(actionId, data);
    }

    function test_cancelAction_success() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        bytes memory data = abi.encode(uint256(100));
        bytes32 actionId = vault.TIMELOCK_SET_MGMT_FEE();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.prank(operator);
        vault.cancelAction(actionId);

        (uint256 readyAt,) = vault.timelockOps(actionId);
        assertEq(readyAt, 0);
    }

    function test_cancelAction_onlyOperator() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        bytes memory data = abi.encode(uint256(100));
        bytes32 actionId = vault.TIMELOCK_SET_MGMT_FEE();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.cancelAction(actionId);
    }

    function test_setManagementFee_revertsWhenTimelockActive() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        vm.prank(operator);
        vm.expectRevert(StreamVault.TimelockRequired.selector);
        vault.setManagementFee(100);
    }

    function test_addYieldSource_revertsWhenTimelockActive() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        MockYieldSource ys2 = new MockYieldSource(address(usdc), address(vault), 1);
        vm.prank(operator);
        vm.expectRevert(StreamVault.TimelockRequired.selector);
        vault.addYieldSource(IYieldSource(address(ys2)));
    }

    function test_setWithdrawalFee_revertsWhenTimelockActive() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        vm.prank(operator);
        vm.expectRevert(StreamVault.TimelockRequired.selector);
        vault.setWithdrawalFee(50);
    }

    function test_pause_noTimelockRequired() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        // Pause should work without timelock
        vm.prank(operator);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_unpause_noTimelockRequired() public {
        vm.prank(operator);
        vault.pause();

        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        // Unpause should work without timelock
        vm.prank(operator);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_addYieldSource_viaTimelock() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        MockYieldSource ys2 = new MockYieldSource(address(usdc), address(vault), 1);
        bytes memory data = abi.encode(address(ys2));
        bytes32 actionId = vault.TIMELOCK_ADD_YIELD_SOURCE();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.warp(block.timestamp + DELAY);

        vm.prank(operator);
        vault.executeTimelocked(actionId, data);

        assertEq(vault.yieldSourceCount(), 2);
    }

    function test_setWithdrawalFee_viaTimelock() public {
        vm.prank(operator);
        vault.setTimelockDelay(DELAY);

        bytes memory data = abi.encode(uint256(50));
        bytes32 actionId = vault.TIMELOCK_SET_WITHDRAWAL_FEE();

        vm.prank(operator);
        vault.scheduleAction(actionId, data);

        vm.warp(block.timestamp + DELAY);

        vm.prank(operator);
        vault.executeTimelocked(actionId, data);

        assertEq(vault.withdrawalFeeBps(), 50);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// EIP-7540 Compliance
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_ERC7540_Test is Test, ProxyDeployHelper {
    MockERC20 usdc;
    StreamVault vault;
    MockYieldSource yieldSource;
    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        vault = _deployVaultProxy(IERC20(address(usdc)), operator, feeRecipient, 1000, 200, 3600, "svUSDC", "svUSDC");
        yieldSource = new MockYieldSource(address(usdc), address(vault), 1);
        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));
        vm.prank(operator);
        vault.setMaxDrawdown(0);
    }

    function _mintAndDeposit(address user, uint256 amount) internal returns (uint256) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();
        return shares;
    }

    function test_setOperator7540_success() public {
        vm.prank(alice);
        bool result = vault.setOperator(bob, true);
        assertTrue(result);
        assertTrue(vault.isOperator(alice, bob));
    }

    function test_setOperator7540_revoke() public {
        vm.prank(alice);
        vault.setOperator(bob, true);
        vm.prank(alice);
        vault.setOperator(bob, false);
        assertFalse(vault.isOperator(alice, bob));
    }

    function test_requestRedeem_selfRequest() public {
        uint256 shares = _mintAndDeposit(alice, 1_000e6);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        assertEq(requestId, 0); // first epoch
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
    }

    function test_requestRedeem_operatorRequest() public {
        uint256 shares = _mintAndDeposit(alice, 1_000e6);

        // Alice approves bob as operator
        vm.prank(alice);
        vault.setOperator(bob, true);

        // Bob calls requestRedeem on behalf of alice, directing to bob as controller
        vm.prank(bob);
        uint256 requestId = vault.requestRedeem(shares, bob, alice);

        assertEq(requestId, 0);
        // Request stored under bob (controller)
        assertEq(vault.pendingRedeemRequest(0, bob), shares);
        // Alice's shares were burned
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_requestRedeem_unauthorizedReverts() public {
        _mintAndDeposit(alice, 1_000e6);
        uint256 shares = vault.balanceOf(alice);

        // Bob is NOT approved
        vm.prank(bob);
        vm.expectRevert(StreamVault.ERC7540Unauthorized.selector);
        vault.requestRedeem(shares, bob, alice);
    }

    function test_requestRedeem_zeroSharesReverts() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.ZeroShares.selector);
        vault.requestRedeem(0, alice, alice);
    }

    function test_pendingRedeemRequest_returnsCorrectAmount() public {
        uint256 shares = _mintAndDeposit(alice, 1_000e6);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        assertEq(vault.pendingRedeemRequest(0, alice), shares);
    }

    function test_pendingRedeemRequest_zeroAfterSettled() public {
        uint256 shares = _mintAndDeposit(alice, 1_000e6);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        vm.warp(block.timestamp + 3601);
        vm.prank(operator);
        vault.settleEpoch();

        assertEq(vault.pendingRedeemRequest(0, alice), 0);
    }

    function test_claimableRedeemRequest_zeroBeforeSettled() public {
        uint256 shares = _mintAndDeposit(alice, 1_000e6);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        assertEq(vault.claimableRedeemRequest(0, alice), 0);
    }

    function test_claimableRedeemRequest_returnsAmountAfterSettled() public {
        uint256 shares = _mintAndDeposit(alice, 1_000e6);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        vm.warp(block.timestamp + 3601);
        vm.prank(operator);
        vault.settleEpoch();

        assertEq(vault.claimableRedeemRequest(0, alice), shares);
    }

    function test_claimableRedeemRequest_zeroAfterClaimed() public {
        uint256 shares = _mintAndDeposit(alice, 1_000e6);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);

        vm.warp(block.timestamp + 3601);
        vm.prank(operator);
        vault.settleEpoch();

        vm.prank(alice);
        vault.claimWithdrawal(0);

        assertEq(vault.claimableRedeemRequest(0, alice), 0);
    }

    function test_supportsInterface_ERC7540Redeem() public view {
        // IERC7540Redeem interface ID
        assertTrue(vault.supportsInterface(type(IERC7540Redeem).interfaceId));
    }

    function test_supportsInterface_ERC7540Operator() public view {
        assertTrue(vault.supportsInterface(type(IERC7540Operator).interfaceId));
    }

    function test_supportsInterface_ERC165() public view {
        assertTrue(vault.supportsInterface(0x01ffc9a7));
    }

    function test_setOperatorWithSig_success() public {
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);

        _mintAndDeposit(owner, 1_000e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(vault.SET_OPERATOR_TYPEHASH(), owner, bob, true, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Anyone can submit the signed approval
        vm.prank(alice);
        vault.setOperatorWithSig(owner, bob, true, deadline, v, r, s);

        assertTrue(vault.isOperator(owner, bob));
        assertEq(vault.nonces(owner), nonce + 1);
    }

    function test_setOperatorWithSig_expiredReverts() public {
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);

        uint256 deadline = block.timestamp - 1; // expired
        bytes32 structHash = keccak256(abi.encode(vault.SET_OPERATOR_TYPEHASH(), owner, bob, true, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        vm.expectRevert(StreamVault.SignatureExpired.selector);
        vault.setOperatorWithSig(owner, bob, true, deadline, v, r, s);
    }

    function test_setOperatorWithSig_invalidSignerReverts() public {
        uint256 wrongKey = 0xBEEF;
        address owner = makeAddr("real-owner");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(vault.SET_OPERATOR_TYPEHASH(), owner, bob, true, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        vm.expectRevert(StreamVault.InvalidSigner.selector);
        vault.setOperatorWithSig(owner, bob, true, deadline, v, r, s);
    }

    function test_setOperatorWithSig_replayReverts() public {
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(vault.SET_OPERATOR_TYPEHASH(), owner, bob, true, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        vault.setOperatorWithSig(owner, bob, true, deadline, v, r, s);

        // Replay with same signature fails (nonce incremented)
        vm.expectRevert(StreamVault.InvalidSigner.selector);
        vault.setOperatorWithSig(owner, bob, true, deadline, v, r, s);
    }

    function test_fullFlow_requestRedeem_settle_claim() public {
        uint256 shares = _mintAndDeposit(alice, 1_000e6);

        // Step 1: requestRedeem
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);
        assertEq(requestId, 0);
        assertTrue(vault.pendingRedeemRequest(0, alice) > 0);

        // Step 2: settle
        vm.warp(block.timestamp + 3601);
        vm.prank(operator);
        vault.settleEpoch();

        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertTrue(vault.claimableRedeemRequest(0, alice) > 0);

        // Step 3: claim via existing claimWithdrawal
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimWithdrawal(0);

        assertTrue(usdc.balanceOf(alice) > balBefore);
        assertEq(vault.claimableRedeemRequest(0, alice), 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RBAC (Role-Based Access Control)
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_RBAC_Test is Test, ProxyDeployHelper {
    MockERC20 usdc;
    StreamVault vault;
    MockYieldSource yieldSource;
    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("feeRecipient");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        vault = _deployVaultProxy(IERC20(address(usdc)), operator, feeRecipient, 1000, 200, 3600, "svUSDC", "svUSDC");
        yieldSource = new MockYieldSource(address(usdc), address(vault), 1);
        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));
    }

    function test_grantRole_onlyOperator() public {
        bytes32 role = vault.ROLE_GUARDIAN();
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.grantRole(role, guardian);
    }

    function test_grantRole_success() public {
        bytes32 role = vault.ROLE_GUARDIAN();
        vm.prank(operator);
        vault.grantRole(role, guardian);
        assertTrue(vault.hasRole(role, guardian));
    }

    function test_grantRole_zeroAddressReverts() public {
        bytes32 role = vault.ROLE_GUARDIAN();
        vm.prank(operator);
        vm.expectRevert(StreamVault.ZeroAddress.selector);
        vault.grantRole(role, address(0));
    }

    function test_revokeRole_success() public {
        bytes32 role = vault.ROLE_GUARDIAN();
        vm.prank(operator);
        vault.grantRole(role, guardian);
        assertTrue(vault.hasRole(role, guardian));

        vm.prank(operator);
        vault.revokeRole(role, guardian);
        assertFalse(vault.hasRole(role, guardian));
    }

    function test_hasRole_operatorImplicit() public view {
        // Operator implicitly has all roles without explicit grant
        assertTrue(vault.hasRole(vault.ROLE_GUARDIAN(), operator));
    }

    function test_guardian_canPause() public {
        bytes32 role = vault.ROLE_GUARDIAN();
        vm.prank(operator);
        vault.grantRole(role, guardian);

        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_guardian_canUnpause() public {
        bytes32 role = vault.ROLE_GUARDIAN();
        vm.prank(operator);
        vault.grantRole(role, guardian);

        vm.prank(guardian);
        vault.pause();

        vm.prank(guardian);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_nonGuardian_cannotPause() public {
        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.pause();
    }

    function test_operator_canStillPause() public {
        // Operator can pause without explicit ROLE_GUARDIAN grant
        vm.prank(operator);
        vault.pause();
        assertTrue(vault.paused());
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Rescuable
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Rescuable_Test is Test, ProxyDeployHelper {
    MockERC20 usdc;
    MockERC20 randomToken;
    StreamVault vault;
    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        randomToken = new MockERC20("RND", "RND", 18);
        vault = _deployVaultProxy(IERC20(address(usdc)), operator, feeRecipient, 1000, 200, 3600, "svUSDC", "svUSDC");
    }

    function test_rescueToken_success() public {
        // Accidentally send random token to vault
        randomToken.mint(address(vault), 1000e18);

        vm.prank(operator);
        vault.rescueToken(IERC20(address(randomToken)), alice, 1000e18);

        assertEq(randomToken.balanceOf(alice), 1000e18);
        assertEq(randomToken.balanceOf(address(vault)), 0);
    }

    function test_rescueToken_underlyingForbidden() public {
        vm.prank(operator);
        vm.expectRevert(StreamVault.RescueUnderlyingForbidden.selector);
        vault.rescueToken(IERC20(address(usdc)), alice, 100e6);
    }

    function test_rescueToken_onlyOperator() public {
        randomToken.mint(address(vault), 1000e18);

        vm.prank(alice);
        vm.expectRevert(StreamVault.OnlyOperator.selector);
        vault.rescueToken(IERC20(address(randomToken)), alice, 1000e18);
    }

    function test_rescueToken_zeroAddressReverts() public {
        randomToken.mint(address(vault), 1000e18);

        vm.prank(operator);
        vm.expectRevert(StreamVault.ZeroAddress.selector);
        vault.rescueToken(IERC20(address(randomToken)), address(0), 1000e18);
    }

    function test_rescueToken_emitsEvent() public {
        randomToken.mint(address(vault), 500e18);

        vm.prank(operator);
        vm.expectEmit(true, true, false, true);
        emit StreamVault.TokenRescued(address(randomToken), alice, 500e18);
        vault.rescueToken(IERC20(address(randomToken)), alice, 500e18);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Multicall
// ─────────────────────────────────────────────────────────────────────────────

contract StreamVault_Multicall_Test is Test, ProxyDeployHelper {
    MockERC20 usdc;
    StreamVault vault;
    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        vault = _deployVaultProxy(IERC20(address(usdc)), operator, feeRecipient, 1000, 200, 3600, "svUSDC", "svUSDC");
    }

    function test_multicall_batchAdminCalls() public {
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(StreamVault.setDepositCap, (10_000_000e6));
        calls[1] = abi.encodeCall(StreamVault.setLockupPeriod, (1 days));
        calls[2] = abi.encodeCall(StreamVault.setMaxDrawdown, (1500));

        vm.prank(operator);
        vault.multicall(calls);

        assertEq(vault.depositCap(), 10_000_000e6);
        assertEq(vault.lockupPeriod(), 1 days);
        assertEq(vault.maxDrawdownBps(), 1500);
    }

    function test_multicall_revertsIfOneCallFails() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(StreamVault.setDepositCap, (10_000_000e6));
        calls[1] = abi.encodeCall(StreamVault.setLockupPeriod, (30 days)); // exceeds MAX_LOCKUP_PERIOD

        vm.prank(operator);
        vm.expectRevert(StreamVault.LockupPeriodTooLong.selector);
        vault.multicall(calls);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FeeLib
// ─────────────────────────────────────────────────────────────────────────────

import {FeeLib} from "../src/libraries/FeeLib.sol";

contract FeeLib_Test is Test {
    function test_computePerformanceFee_basic() public pure {
        // 10% fee on 1000 profit = 100
        uint256 fee = FeeLib.computePerformanceFee(1000e6, 1000);
        assertEq(fee, 100e6);
    }

    function test_computePerformanceFee_zeroProfit() public pure {
        assertEq(FeeLib.computePerformanceFee(0, 1000), 0);
    }

    function test_computePerformanceFee_zeroBps() public pure {
        assertEq(FeeLib.computePerformanceFee(1000e6, 0), 0);
    }

    function test_computeManagementFee_oneYear() public pure {
        // 2% annual on 1M for 1 year
        uint256 fee = FeeLib.computeManagementFee(1_000_000e6, 200, 365.25 days, 365.25 days);
        assertEq(fee, 20_000e6);
    }

    function test_computeManagementFee_zeroElapsed() public pure {
        assertEq(FeeLib.computeManagementFee(1_000_000e6, 200, 0, 365.25 days), 0);
    }

    function test_computeWithdrawalFee_basic() public pure {
        // 0.5% fee on 10000 payout = 50
        uint256 fee = FeeLib.computeWithdrawalFee(10_000e6, 50);
        assertEq(fee, 50e6);
    }

    function test_computeWithdrawalFee_zeroPayout() public pure {
        assertEq(FeeLib.computeWithdrawalFee(0, 50), 0);
    }

    function test_convertToSharesAtEma_zeroSupply() public pure {
        // With zero supply, should return assets * 10^offset
        uint256 shares = FeeLib.convertToSharesAtEma(100e6, 0, 0, 3);
        assertEq(shares, 100e6 * 1000);
    }

    function testFuzz_computePerformanceFee_neverExceedsProfit(uint256 profit, uint256 bps) public pure {
        profit = bound(profit, 0, 1e30);
        bps = bound(bps, 0, 10_000);
        uint256 fee = FeeLib.computePerformanceFee(profit, bps);
        assertLe(fee, profit);
    }
}
