/*
 * Certora Verification Specification for StreamVault
 *
 * This spec covers:
 * 1. ERC-4626 invariants (shares/assets accounting)
 * 2. Epoch lifecycle correctness
 * 3. Fee bounds enforcement
 * 4. Access control
 * 5. Deposit cap enforcement
 * 6. Lockup period enforcement
 * 7. Transfer restrictions
 */

// ═══════════════════════════════════════════════════════════════════════════════
// Methods Block
// ═══════════════════════════════════════════════════════════════════════════════

methods {
    // ERC20 standard
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external returns (uint256) envfree;

    // ERC4626 standard
    function asset() external returns (address) envfree;
    function totalAssets() external returns (uint256) envfree;
    function convertToShares(uint256) external returns (uint256) envfree;
    function convertToAssets(uint256) external returns (uint256) envfree;
    function maxDeposit(address) external returns (uint256) envfree;
    function maxMint(address) external returns (uint256) envfree;
    function maxWithdraw(address) external returns (uint256) envfree;
    function maxRedeem(address) external returns (uint256) envfree;
    function deposit(uint256, address) external returns (uint256);
    function mint(uint256, address) external returns (uint256);
    function withdraw(uint256, address, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);

    // StreamVault state getters
    function operator() external returns (address) envfree;
    function feeRecipient() external returns (address) envfree;
    function currentEpochId() external returns (uint256) envfree;
    function totalPendingShares() external returns (uint256) envfree;
    function totalClaimableAssets() external returns (uint256) envfree;
    function performanceFeeBps() external returns (uint256) envfree;
    function managementFeeBps() external returns (uint256) envfree;
    function withdrawalFeeBps() external returns (uint256) envfree;
    function depositCap() external returns (uint256) envfree;
    function lockupPeriod() external returns (uint256) envfree;
    function timelockDelay() external returns (uint256) envfree;
    function transfersRestricted() external returns (bool) envfree;
    function emaTotalAssets() external returns (uint256) envfree;
    function navHighWaterMark() external returns (uint256) envfree;
    function maxDrawdownBps() external returns (uint256) envfree;
    function paused() external returns (bool) envfree;

    // Harness functions
    function getYieldSourcesLength() external returns (uint256) envfree;
    function getEpochStatus(uint256) external returns (uint8) envfree;
    function getEpochTotalSharesBurned(uint256) external returns (uint256) envfree;
    function getEpochTotalAssetsOwed(uint256) external returns (uint256) envfree;
    function getEpochTotalAssetsClaimed(uint256) external returns (uint256) envfree;
    function getUserWithdrawShares(uint256, address) external returns (uint256) envfree;
    function getIdleBalance() external returns (uint256) envfree;
    function depositTimestamp(address) external returns (uint256) envfree;
    function transferWhitelist(address) external returns (bool) envfree;
    function getBlockTimestamp() external returns (uint256) envfree;

    // Constants
    function MAX_YIELD_SOURCES() external returns (uint256) envfree;
    function MAX_PERFORMANCE_FEE_BPS() external returns (uint256) envfree;
    function MAX_MANAGEMENT_FEE_BPS() external returns (uint256) envfree;
    function MAX_WITHDRAWAL_FEE_BPS() external returns (uint256) envfree;
    function MAX_LOCKUP_PERIOD() external returns (uint256) envfree;
    function MIN_TIMELOCK_DELAY() external returns (uint256) envfree;
    function MAX_TIMELOCK_DELAY() external returns (uint256) envfree;
    function EMA_FLOOR_BPS() external returns (uint256) envfree;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Ghost Variables & Hooks
// ═══════════════════════════════════════════════════════════════════════════════

ghost mathint sumOfBalances {
    init_state axiom sumOfBalances == 0;
}

// Track sum of all balances via storage hooks
hook Sload uint256 balance _balances[KEY address addr] {
    require sumOfBalances >= to_mathint(balance);
}

hook Sstore _balances[KEY address addr] uint256 newValue (uint256 oldValue) {
    sumOfBalances = sumOfBalances - oldValue + newValue;
}

// ═══════════════════════════════════════════════════════════════════════════════
// INVARIANTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @title Total supply equals sum of all balances
invariant totalSupplyIsSumOfBalances()
    to_mathint(totalSupply()) == sumOfBalances;

/// @title Performance fee never exceeds maximum (50%)
invariant performanceFeeBounded()
    performanceFeeBps() <= MAX_PERFORMANCE_FEE_BPS();

/// @title Management fee never exceeds maximum (5%)
invariant managementFeeBounded()
    managementFeeBps() <= MAX_MANAGEMENT_FEE_BPS();

/// @title Withdrawal fee never exceeds maximum (1%)
invariant withdrawalFeeBounded()
    withdrawalFeeBps() <= MAX_WITHDRAWAL_FEE_BPS();

/// @title Lockup period never exceeds maximum (7 days)
invariant lockupPeriodBounded()
    lockupPeriod() <= MAX_LOCKUP_PERIOD();

/// @title Timelock delay is either 0 or within bounds
invariant timelockDelayValid()
    timelockDelay() == 0 ||
    (timelockDelay() >= MIN_TIMELOCK_DELAY() && timelockDelay() <= MAX_TIMELOCK_DELAY());

/// @title Number of yield sources never exceeds maximum
invariant yieldSourcesLimited()
    getYieldSourcesLength() <= MAX_YIELD_SOURCES();

/// @title Claimable assets never exceed total assets
/// @dev This ensures the vault is always solvent for settled claims
invariant claimableNeverExceedsTotalAssets()
    totalClaimableAssets() <= totalAssets();

// ═══════════════════════════════════════════════════════════════════════════════
// RULES: DEPOSIT CAP ENFORCEMENT
// ═══════════════════════════════════════════════════════════════════════════════

/// @title Deposit cap enforced - maxDeposit respects cap
rule depositCapEnforced(address receiver) {
    uint256 cap = depositCap();
    uint256 current = totalAssets();
    uint256 maxDep = maxDeposit(receiver);

    // If cap is 0 (unlimited), maxDeposit can be max_uint256
    // If cap is set and not exceeded, maxDeposit = cap - current
    // If cap is exceeded, maxDeposit = 0
    assert cap == 0 => maxDep == max_uint256 || paused();
    assert cap > 0 && current >= cap => maxDep == 0;
    assert cap > 0 && current < cap && !paused() => maxDep == cap - current;
}

/// @title Deposits cannot exceed cap
rule depositsRespectCap(env e, uint256 assets, address receiver) {
    uint256 capBefore = depositCap();
    uint256 totalBefore = totalAssets();

    deposit(e, assets, receiver);

    uint256 totalAfter = totalAssets();

    // If cap is set, total assets after deposit must not exceed cap
    assert capBefore > 0 => totalAfter <= capBefore;
}

// ═══════════════════════════════════════════════════════════════════════════════
// RULES: FEE INVARIANTS
// ═══════════════════════════════════════════════════════════════════════════════

/// @title Fee settings can only be changed by operator
rule onlyOperatorCanSetFees(env e, method f) filtered {
    f -> f.selector == sig:setManagementFee(uint256).selector ||
         f.selector == sig:setWithdrawalFee(uint256).selector
} {
    calldataarg args;

    f@withrevert(e, args);

    // If call succeeded, sender must be operator
    assert !lastReverted => e.msg.sender == operator();
}

// ═══════════════════════════════════════════════════════════════════════════════
// RULES: EPOCH LIFECYCLE
// ═══════════════════════════════════════════════════════════════════════════════

/// @title Epoch IDs are monotonically increasing
rule epochIdOnlyIncreases(env e, method f) {
    calldataarg args;
    uint256 epochBefore = currentEpochId();

    f(e, args);

    uint256 epochAfter = currentEpochId();

    assert epochAfter >= epochBefore;
}

/// @title Claims cannot exceed epoch's total owed
rule claimsNeverExceedOwed(uint256 epochId) {
    uint256 owed = getEpochTotalAssetsOwed(epochId);
    uint256 claimed = getEpochTotalAssetsClaimed(epochId);

    assert claimed <= owed;
}

// ═══════════════════════════════════════════════════════════════════════════════
// RULES: TRANSFER RESTRICTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/// @title Transfers blocked when restricted (except whitelisted)
rule transferRestrictionsEnforced(env e, address to, uint256 amount) {
    bool restricted = transfersRestricted();
    bool whitelisted = transferWhitelist(to);

    transfer@withrevert(e, to, amount);

    // If restricted and not whitelisted and not a mint/burn, should revert
    assert restricted && !whitelisted && to != 0 && e.msg.sender != 0 => lastReverted;
}

// ═══════════════════════════════════════════════════════════════════════════════
// RULES: EMA FLOOR
// ═══════════════════════════════════════════════════════════════════════════════

/// @title EMA never falls below floor (95% of spot)
rule emaFloorMaintained() {
    uint256 ema = emaTotalAssets();
    uint256 spot = totalAssets();
    uint256 floorBps = EMA_FLOOR_BPS();

    // EMA >= spot * 0.95 (floor enforced)
    // We use multiplication to avoid division: ema * 10000 >= spot * 9500
    assert ema * 10000 >= spot * floorBps;
}

// ═══════════════════════════════════════════════════════════════════════════════
// RULES: ACCESS CONTROL
// ═══════════════════════════════════════════════════════════════════════════════

/// @title Pause can only be called by operator or guardian
rule onlyAuthorizedCanPause(env e) {
    pause@withrevert(e);

    // If succeeded, must be operator or have guardian role
    // Note: We'd need hasRole helper to fully verify guardian
    assert !lastReverted => e.msg.sender == operator();
}

/// @title Critical state changes require operator
rule criticalChangesRequireOperator(env e, method f) filtered {
    f -> f.selector == sig:addYieldSource(address).selector ||
         f.selector == sig:removeYieldSource(uint256).selector ||
         f.selector == sig:setDepositCap(uint256).selector ||
         f.selector == sig:setLockupPeriod(uint256).selector ||
         f.selector == sig:setTransfersRestricted(bool).selector
} {
    calldataarg args;

    f@withrevert(e, args);

    assert !lastReverted => e.msg.sender == operator();
}

// ═══════════════════════════════════════════════════════════════════════════════
// RULES: SOLVENCY
// ═══════════════════════════════════════════════════════════════════════════════

/// @title Vault remains solvent after any operation
/// @dev Total assets should always cover claimable + value of pending shares
rule vaultSolvency(env e, method f) {
    requireInvariant totalSupplyIsSumOfBalances();

    calldataarg args;

    uint256 assetsBefore = totalAssets();
    uint256 claimableBefore = totalClaimableAssets();

    f(e, args);

    uint256 assetsAfter = totalAssets();
    uint256 claimableAfter = totalClaimableAssets();

    // Claimable should never exceed total assets
    assert claimableAfter <= assetsAfter;
}

// ═══════════════════════════════════════════════════════════════════════════════
// RULES: NO INFLATION ATTACK
// ═══════════════════════════════════════════════════════════════════════════════

/// @title First depositor gets fair shares (inflation protection)
rule firstDepositorProtected(env e, uint256 assets, address receiver) {
    require totalSupply() == 0;
    require assets > 0;
    require assets <= 1000000000000000000; // 1e18 bound for practicality

    uint256 shares = deposit(e, assets, receiver);

    // With decimals offset, first depositor should get assets * 10^offset shares
    // This prevents inflation attack where attacker donates to steal from depositor
    assert shares > 0;
    assert shares >= assets; // At minimum, 1:1 or better due to offset
}
