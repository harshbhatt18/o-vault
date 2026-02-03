// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IYieldSource} from "./IYieldSource.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";
import {RiskModel} from "./libraries/RiskModel.sol";

/// @title StreamVault
/// @notice ERC-4626 vault with async (epoch-based) withdrawals, multi-connector yield sources,
///         EMA-smoothed NAV for manipulation-resistant settlement, and continuous management fee accrual.
///         Deposits are instant. Withdrawals go through a three-step process:
///         requestWithdraw → settleEpoch → claimWithdrawal.
///         Implements IReceiver for Chainlink CRE risk oracle integration.
contract StreamVault is ERC4626, ReentrancyGuard, Pausable, IReceiver {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── Constants ────────────────────────────────────────────────────────

    uint256 public constant MAX_YIELD_SOURCES = 20;
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 5_000; // 50%
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 500; // 5% annual
    uint256 public constant MIN_SMOOTHING_PERIOD = 300; // 5 minutes
    uint256 public constant MAX_SMOOTHING_PERIOD = 86_400; // 24 hours
    uint256 public constant EMA_FLOOR_BPS = 9_500; // EMA >= 95% of spot
    uint256 public constant SECONDS_PER_YEAR = 365.25 days; // 31_557_600
    uint256 public constant MIN_EPOCH_DURATION = 300; // 5 minutes — prevents settlement timing attacks
    uint256 public constant MAX_DRAWDOWN_BPS = 5_000; // Max configurable drawdown: 50%
    uint256 public constant DEFAULT_MAX_DRAWDOWN_BPS = 1_000; // Default: 10% drawdown triggers pause

    // ─── Types ──────────────────────────────────────────────────────────

    enum EpochStatus {
        OPEN,
        SETTLED
    }

    struct Epoch {
        EpochStatus status;
        uint256 totalSharesBurned; // shares burned by all requestors in this epoch
        uint256 totalAssetsOwed; // USDC owed to all requestors (set at settlement)
        uint256 totalAssetsClaimed; // USDC already claimed
    }

    struct WithdrawRequest {
        uint256 shares; // shares burned by this user in this epoch
    }

    // ─── State ──────────────────────────────────────────────────────────

    IYieldSource[] public yieldSources;
    address public operator;
    address public feeRecipient;
    uint256 public immutable performanceFeeBps; // e.g. 1000 = 10%

    uint256 public currentEpochId;
    uint256 public totalPendingShares; // shares burned but not yet settled
    uint256 public totalClaimableAssets; // USDC owed in settled epochs, not yet claimed

    mapping(uint256 => uint256) public lastHarvestedBalance; // per-source high water mark

    // ─── Management Fee State ───────────────────────────────────────────

    uint256 public managementFeeBps; // annual fee in bps (e.g. 200 = 2%)
    uint256 public lastFeeAccrualTimestamp;

    // ─── EMA State ──────────────────────────────────────────────────────

    uint256 public emaTotalAssets; // smoothed NAV — used by settleEpoch
    uint256 public lastEmaUpdateTimestamp;
    uint256 public smoothingPeriod; // seconds for full convergence
    uint256 public epochOpenedAt; // timestamp when current epoch started

    // ─── Drawdown Protection State ───────────────────────────────────────

    uint256 public navHighWaterMark; // highest NAV per share (18 decimals)
    uint256 public maxDrawdownBps; // max allowed drawdown before auto-pause (e.g., 1000 = 10%)

    // ─── CRE Risk Oracle State ──────────────────────────────────────────

    address public chainlinkForwarder; // Chainlink CRE KeystoneForwarder address
    RiskModel.RiskSnapshot public latestRiskSnapshot; // Latest risk snapshot from CRE
    uint256 public lcrFloorBps; // Minimum LCR (e.g., 10000 = 100%), enforced in deployToYield()

    /// @notice Action type constants for onReport dispatch
    uint8 public constant ACTION_UPDATE_RISK_PARAMS = 0;
    uint8 public constant ACTION_DEFENSIVE_REBALANCE = 1;
    uint8 public constant ACTION_EMERGENCY_PAUSE = 2;
    uint8 public constant ACTION_SETTLE_EPOCH = 3;
    uint8 public constant ACTION_HARVEST_YIELD = 4;

    // ─── Mappings ───────────────────────────────────────────────────────

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => WithdrawRequest)) public withdrawRequests;
    mapping(address => RiskModel.SourceRiskParams) public sourceRiskParams; // source address → CRE risk params
    mapping(address => bool) public isRegisteredSource; // source address → is registered

    // ─── Events ─────────────────────────────────────────────────────────

    event WithdrawRequested(address indexed user, uint256 indexed epochId, uint256 shares);
    event EpochSettled(uint256 indexed epochId, uint256 totalAssetsOwed);
    event WithdrawalClaimed(address indexed user, uint256 indexed epochId, uint256 assets);
    event DeployedToYield(uint256 indexed sourceIndex, uint256 amount);
    event WithdrawnFromYield(uint256 indexed sourceIndex, uint256 amount);
    event YieldHarvested(uint256 profit, uint256 feeShares);
    event YieldSourceAdded(uint256 indexed sourceIndex, address indexed source);
    event YieldSourceRemoved(uint256 indexed sourceIndex, address indexed source);
    event ManagementFeeAccrued(uint256 feeAssets, uint256 feeShares, uint256 elapsed);
    event EmaUpdated(uint256 newEma, uint256 spot);
    event OperatorUpdated(address indexed newOperator);
    event FeeRecipientUpdated(address indexed newFeeRecipient);
    event ManagementFeeUpdated(uint256 newFeeBps);
    event SmoothingPeriodUpdated(uint256 newPeriod);
    event VaultPaused(address indexed by);
    event VaultUnpaused(address indexed by);
    event DrawdownCircuitBreaker(uint256 currentNav, uint256 highWaterMark, uint256 drawdownBps);
    event NavHighWaterMarkUpdated(uint256 newHighWaterMark);
    event MaxDrawdownUpdated(uint256 newMaxDrawdownBps);
    event ChainlinkForwarderUpdated(address indexed forwarder);
    event RiskParamsUpdated(address indexed source, RiskModel.SourceRiskParams params);
    event RiskSnapshotUpdated(RiskModel.RiskSnapshot snapshot);
    event DefensiveRebalanceTriggered(address indexed source, uint256 amountWithdrawn);
    event EmergencyPauseTriggered(uint8 severity);
    event LCRFloorUpdated(uint256 newFloorBps);

    // ─── Errors ─────────────────────────────────────────────────────────

    error OnlyOperator();
    error EpochNotSettled();
    error EpochAlreadySettled();
    error NoRequestInEpoch();
    error ZeroShares();
    error ZeroAmount();
    error ZeroAddress();
    error AssetMismatch();
    error InvalidSourceIndex();
    error SourceNotEmpty();
    error InsufficientLiquidity();
    error TooManyYieldSources();
    error FeeTooHigh();
    error InvalidSmoothingPeriod();
    error EpochTooYoung();
    error InvalidDrawdownThreshold();
    error OnlyForwarder();
    error InvalidAction(uint8 action);
    error ArrayLengthMismatch();
    error UnknownSource(address source);
    error HaircutTooHigh();
    error InvalidConcentration();
    error LCRBreached(uint256 actual, uint256 floor);
    error ConcentrationBreached(address source);

    // ─── Modifiers ──────────────────────────────────────────────────────

    modifier onlyOperator() {
        _onlyOperator();
        _;
    }

    /// @notice Allows either the trusted operator or the CRE Forwarder
    modifier onlyOperatorOrCRE() {
        if (msg.sender != operator && msg.sender != chainlinkForwarder) revert OnlyOperator();
        _;
    }

    // ─── Constructor ────────────────────────────────────────────────────

    constructor(
        IERC20 _asset,
        address _operator,
        address _feeRecipient,
        uint256 _performanceFeeBps,
        uint256 _managementFeeBps,
        uint256 _smoothingPeriod,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) {
        if (_operator == address(0)) revert ZeroAddress();
        if (_performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        if (_managementFeeBps > MAX_MANAGEMENT_FEE_BPS) revert FeeTooHigh();
        if (_smoothingPeriod < MIN_SMOOTHING_PERIOD || _smoothingPeriod > MAX_SMOOTHING_PERIOD) {
            revert InvalidSmoothingPeriod();
        }

        operator = _operator;
        feeRecipient = _feeRecipient;
        performanceFeeBps = _performanceFeeBps;
        managementFeeBps = _managementFeeBps;
        lastFeeAccrualTimestamp = block.timestamp;

        smoothingPeriod = _smoothingPeriod;
        emaTotalAssets = 10 ** _decimalsOffset(); // match virtual offset
        lastEmaUpdateTimestamp = block.timestamp;
        epochOpenedAt = block.timestamp;

        // Initialize drawdown protection with default 10% threshold
        maxDrawdownBps = DEFAULT_MAX_DRAWDOWN_BPS;
        // Initialize HWM to match actual NAV at construction.
        // At construction: totalSupply() = 0, so navPerShare() returns 1e18.
        // But after first deposit, NAV depends on asset decimals + decimalsOffset.
        // For USDC (6 dec) + offset 3: NAV ≈ 1e15, not 1e18.
        // Set to 0 so the first _checkDrawdown() call sets it to the real NAV.
        navHighWaterMark = 0;
    }

    // ─── ERC-4626 Overrides ─────────────────────────────────────────────

    /// @notice Total assets under management, excluding assets already owed to settled withdrawers.
    /// @dev totalAssets = idle balance + sum(yieldSource[i].balance()) − totalClaimableAssets
    ///      This is the raw "spot" NAV. Settlement uses emaTotalAssets instead.
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));

        uint256 deployed;
        uint256 len = yieldSources.length;
        for (uint256 i; i < len; ++i) {
            deployed += yieldSources[i].balance();
        }

        uint256 gross = idle + deployed;
        // Claimable should never exceed gross — if it does, yield source rounding
        // caused a tiny shortfall. Clamp to 0 to prevent revert but this should
        // only happen for dust amounts.
        if (gross < totalClaimableAssets) return 0;
        return gross - totalClaimableAssets;
    }

    /// @dev Virtual share offset for inflation attack protection (adds 1e3 virtual shares/assets).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @notice Override to accrue management fee, update EMA, and snap EMA on first deposit.
    /// @dev Pausing blocks deposits to protect users if a yield source is compromised.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        whenNotPaused
    {
        _accrueManagementFee();
        _updateEma();

        // Snap EMA to spot after the first real deposit so settlement isn't
        // priced at the tiny virtual-offset seed value during convergence.
        bool isFirstDeposit = totalSupply() == 0;

        super._deposit(caller, receiver, assets, shares);

        if (isFirstDeposit) {
            emaTotalAssets = totalAssets();
            lastEmaUpdateTimestamp = block.timestamp;
        }
    }

    /// @notice Disable standard ERC-4626 withdraw — all exits go through the epoch queue.
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("Use requestWithdraw");
    }

    /// @notice Disable standard ERC-4626 redeem — all exits go through the epoch queue.
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("Use requestWithdraw");
    }

    /// @notice Always returns 0 — sync withdrawals are disabled.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always returns 0 — sync redeems are disabled.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always reverts — sync withdrawals are disabled.
    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert("Use requestWithdraw");
    }

    /// @notice Always reverts — sync redeems are disabled.
    function previewRedeem(uint256) public pure override returns (uint256) {
        revert("Use requestWithdraw");
    }

    // ─── Yield Source Management ────────────────────────────────────────

    /// @notice Add a new yield source connector.
    function addYieldSource(IYieldSource source) external onlyOperator {
        if (address(source) == address(0)) revert ZeroAddress();
        if (source.asset() != asset()) revert AssetMismatch();
        if (yieldSources.length >= MAX_YIELD_SOURCES) revert TooManyYieldSources();

        yieldSources.push(source);
        isRegisteredSource[address(source)] = true;
        sourceRiskParams[address(source)] = RiskModel.defaultParams();
        emit YieldSourceAdded(yieldSources.length - 1, address(source));
    }

    /// @notice Remove a yield source. Must have zero balance.
    function removeYieldSource(uint256 sourceIndex) external onlyOperator {
        uint256 len = yieldSources.length;
        if (sourceIndex >= len) revert InvalidSourceIndex();

        IYieldSource source = yieldSources[sourceIndex];
        if (source.balance() != 0) revert SourceNotEmpty();

        // Clear CRE risk tracking
        isRegisteredSource[address(source)] = false;
        delete sourceRiskParams[address(source)];

        yieldSources[sourceIndex] = yieldSources[len - 1];
        yieldSources.pop();

        if (sourceIndex < yieldSources.length) {
            lastHarvestedBalance[sourceIndex] = lastHarvestedBalance[len - 1];
        }
        delete lastHarvestedBalance[len - 1];

        emit YieldSourceRemoved(sourceIndex, address(source));
    }

    /// @notice Returns the number of registered yield sources.
    function yieldSourceCount() external view returns (uint256) {
        return yieldSources.length;
    }

    // ─── Async Withdrawal: Step 1 — Request ────────────────────────────

    /// @notice Burn shares and queue a withdrawal request in the current epoch.
    /// @dev Pausing blocks new withdrawal requests but allows claiming from settled epochs.
    function requestWithdraw(uint256 shares) external nonReentrant whenNotPaused {
        if (shares == 0) revert ZeroShares();

        _accrueManagementFee();
        _updateEma();

        _burn(msg.sender, shares);

        uint256 epochId = currentEpochId;
        epochs[epochId].totalSharesBurned += shares;
        withdrawRequests[epochId][msg.sender].shares += shares;
        totalPendingShares += shares;

        emit WithdrawRequested(msg.sender, epochId, shares);
    }

    // ─── Async Withdrawal: Step 2 — Settle ─────────────────────────────

    /// @notice Settle the current epoch using EMA-smoothed NAV for manipulation resistance.
    ///         Pulls from yield sources (waterfall) if idle funds are insufficient.
    function settleEpoch() external onlyOperator nonReentrant {
        _settleCurrentEpoch();
    }

    // ─── Async Withdrawal: Step 3 — Claim ──────────────────────────────

    /// @notice Claim your pro-rata share of a settled epoch's assets.
    function claimWithdrawal(uint256 epochId) external nonReentrant {
        Epoch storage epoch = epochs[epochId];
        if (epoch.status != EpochStatus.SETTLED) revert EpochNotSettled();

        WithdrawRequest storage req = withdrawRequests[epochId][msg.sender];
        if (req.shares == 0) revert NoRequestInEpoch();

        uint256 userShares = req.shares;
        req.shares = 0;

        uint256 payout = userShares.mulDiv(epoch.totalAssetsOwed, epoch.totalSharesBurned, Math.Rounding.Floor);

        epoch.totalAssetsClaimed += payout;
        totalClaimableAssets -= payout;

        IERC20(asset()).safeTransfer(msg.sender, payout);

        emit WithdrawalClaimed(msg.sender, epochId, payout);
    }

    // ─── Operator Functions ─────────────────────────────────────────────

    /// @notice Deploy idle USDC to a specific yield source.
    /// @dev Enforces LCR floor and concentration limits using CRE-updated risk params.
    function deployToYield(uint256 sourceIndex, uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (sourceIndex >= yieldSources.length) revert InvalidSourceIndex();

        _accrueManagementFee();
        _updateEma();

        IYieldSource source = yieldSources[sourceIndex];
        IERC20(asset()).forceApprove(address(source), amount);
        source.deposit(amount);

        // POST-CONDITION: LCR must remain above floor after deployment
        if (lcrFloorBps > 0) {
            uint256 lcrAfter = this.computeLCR();
            if (lcrAfter < lcrFloorBps) revert LCRBreached(lcrAfter, lcrFloorBps);
        }

        // POST-CONDITION: Concentration limit must not be exceeded
        RiskModel.SourceRiskParams memory params = sourceRiskParams[address(source)];
        if (params.maxConcentrationBps > 0) {
            uint256 sourceBalanceAfter = source.balance();
            uint256 total = totalAssets();
            if (RiskModel.isConcentrationBreached(sourceBalanceAfter, total, params.maxConcentrationBps)) {
                revert ConcentrationBreached(address(source));
            }
        }

        emit DeployedToYield(sourceIndex, amount);
    }

    /// @notice Pull USDC from a specific yield source back to idle.
    function withdrawFromYield(uint256 sourceIndex, uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (sourceIndex >= yieldSources.length) revert InvalidSourceIndex();

        _accrueManagementFee();
        _updateEma();

        yieldSources[sourceIndex].withdraw(amount);

        emit WithdrawnFromYield(sourceIndex, amount);
    }

    /// @notice Harvest yield from all sources. Uses per-source high water marks —
    ///         fees are only charged when a source exceeds its own previous peak.
    ///         This prevents double-charging on loss recovery: if source B drops
    ///         and later recovers, the recovery is not counted as new profit.
    function harvestYield() external onlyOperator nonReentrant {
        _accrueManagementFee();
        _updateEma();
        _checkDrawdown();

        uint256 totalProfit;
        uint256 len = yieldSources.length;

        for (uint256 i; i < len; ++i) {
            uint256 currentBalance = yieldSources[i].balance();
            uint256 hwm = lastHarvestedBalance[i];

            // Only count profit above each source's own high water mark.
            // If currentBalance < hwm (loss), don't update HWM — source must
            // recover past its previous peak before new profit is recognized.
            if (currentBalance > hwm) {
                totalProfit += currentBalance - hwm;
                lastHarvestedBalance[i] = currentBalance;
            }
        }

        if (totalProfit == 0 || performanceFeeBps == 0 || feeRecipient == address(0)) return;

        uint256 feeAssets = totalProfit.mulDiv(performanceFeeBps, 10_000, Math.Rounding.Floor);
        // Price fee shares using EMA (consistent with settlement pricing).
        // Using spot would let an inflated spot mint cheaper fee shares.
        uint256 feeShares = _convertToSharesAtEma(feeAssets);

        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
            emit YieldHarvested(totalProfit, feeShares);
        }
    }

    // ─── Internal: Management Fee & EMA ─────────────────────────────────

    /// @notice Accrue time-proportional management fee via share dilution.
    /// @dev fee = netAssets × managementFeeBps × elapsed / (SECONDS_PER_YEAR × 10_000)
    ///      Charged on net AUM (totalAssets, excluding claimable) — fees only apply to
    ///      assets actually under management, not funds already owed to settled withdrawers.
    function _accrueManagementFee() internal {
        if (managementFeeBps == 0 || feeRecipient == address(0)) return;

        uint256 elapsed = block.timestamp - lastFeeAccrualTimestamp;
        if (elapsed == 0) return;

        uint256 netAssets = totalAssets();

        if (netAssets == 0) {
            lastFeeAccrualTimestamp = block.timestamp;
            return;
        }

        uint256 feeAssets = netAssets.mulDiv(managementFeeBps * elapsed, SECONDS_PER_YEAR * 10_000, Math.Rounding.Floor);

        lastFeeAccrualTimestamp = block.timestamp;

        if (feeAssets == 0) return;

        // Price fee shares using EMA for consistency with settlement pricing.
        uint256 feeShares = _convertToSharesAtEma(feeAssets);

        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
            emit ManagementFeeAccrued(feeAssets, feeShares, elapsed);
        }
    }

    /// @notice Convert assets to shares using EMA-based NAV instead of spot.
    /// @dev Mirrors OZ _convertToShares but substitutes emaTotalAssets for totalAssets().
    ///      Used for fee share minting so that fee pricing is consistent with settlement.
    function _convertToSharesAtEma(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        return (assets == 0 || supply == 0)
            ? assets.mulDiv(10 ** _decimalsOffset(), 1, Math.Rounding.Floor)
            : assets.mulDiv(supply + 10 ** _decimalsOffset(), emaTotalAssets + 1, Math.Rounding.Floor);
    }

    /// @notice Update the EMA of totalAssets using linear interpolation.
    /// @dev ema = prev + (spot − prev) × elapsed / smoothingPeriod
    ///      Fully converges after smoothingPeriod seconds.
    ///      Floor: EMA cannot be >5% below spot (prevents sandbagging).
    ///      Safety: EMA never goes below virtual offset (10^3).
    function _updateEma() internal {
        uint256 spot = totalAssets();
        uint256 elapsed = block.timestamp - lastEmaUpdateTimestamp;

        if (elapsed == 0) return;

        if (elapsed >= smoothingPeriod) {
            emaTotalAssets = spot;
        } else {
            if (spot > emaTotalAssets) {
                uint256 delta = spot - emaTotalAssets;
                emaTotalAssets += delta.mulDiv(elapsed, smoothingPeriod, Math.Rounding.Floor);
            } else if (spot < emaTotalAssets) {
                uint256 delta = emaTotalAssets - spot;
                emaTotalAssets -= delta.mulDiv(elapsed, smoothingPeriod, Math.Rounding.Floor);
            }
        }

        // Floor: EMA cannot be more than 5% below spot
        uint256 floor = spot.mulDiv(EMA_FLOOR_BPS, 10_000, Math.Rounding.Floor);
        if (emaTotalAssets < floor) {
            emaTotalAssets = floor;
        }

        // Safety: never below virtual offset
        uint256 minEma = 10 ** _decimalsOffset();
        if (emaTotalAssets < minEma) {
            emaTotalAssets = minEma;
        }

        lastEmaUpdateTimestamp = block.timestamp;

        emit EmaUpdated(emaTotalAssets, spot);
    }

    /// @notice Calculate the current NAV per share in 18-decimal precision.
    /// @dev Uses EMA-based NAV for manipulation resistance.
    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        // Use EMA for consistent pricing with settlement
        return (emaTotalAssets * 1e18) / supply;
    }

    /// @notice Check for excessive drawdown and auto-pause if threshold exceeded.
    /// @dev Updates high water mark if NAV is at new high.
    ///      Triggers circuit breaker if drawdown exceeds maxDrawdownBps.
    function _checkDrawdown() internal {
        if (maxDrawdownBps == 0) return; // Drawdown protection disabled

        uint256 currentNav = navPerShare();

        // Update high water mark if at new high
        if (currentNav > navHighWaterMark) {
            navHighWaterMark = currentNav;
            emit NavHighWaterMarkUpdated(currentNav);
            return;
        }

        // Calculate drawdown from high water mark
        uint256 drawdownBps = ((navHighWaterMark - currentNav) * 10_000) / navHighWaterMark;

        // Trigger circuit breaker if drawdown exceeds threshold
        if (drawdownBps >= maxDrawdownBps && !paused()) {
            _pause();
            emit DrawdownCircuitBreaker(currentNav, navHighWaterMark, drawdownBps);
            emit VaultPaused(address(this));
        }
    }

    // ─── Batch Operations ─────────────────────────────────────────────

    /// @notice Claim withdrawals from multiple settled epochs in a single transaction.
    /// @param epochIds Array of epoch IDs to claim from.
    function batchClaimWithdrawals(uint256[] calldata epochIds) external nonReentrant {
        uint256 len = epochIds.length;
        uint256 totalPayout;

        for (uint256 i; i < len; ++i) {
            uint256 epochId = epochIds[i];
            Epoch storage epoch = epochs[epochId];
            if (epoch.status != EpochStatus.SETTLED) revert EpochNotSettled();

            WithdrawRequest storage req = withdrawRequests[epochId][msg.sender];
            if (req.shares == 0) revert NoRequestInEpoch();

            uint256 userShares = req.shares;
            req.shares = 0;

            uint256 payout = userShares.mulDiv(epoch.totalAssetsOwed, epoch.totalSharesBurned, Math.Rounding.Floor);

            epoch.totalAssetsClaimed += payout;
            totalPayout += payout;

            emit WithdrawalClaimed(msg.sender, epochId, payout);
        }

        totalClaimableAssets -= totalPayout;
        IERC20(asset()).safeTransfer(msg.sender, totalPayout);
    }

    // ─── View Functions ──────────────────────────────────────────────────

    /// @notice Get a user's withdraw request for a specific epoch.
    /// @return shares The number of shares the user burned in this epoch.
    function getUserWithdrawRequest(uint256 epochId, address user) external view returns (uint256 shares) {
        shares = withdrawRequests[epochId][user].shares;
    }

    /// @notice Get full epoch info.
    /// @return status The epoch status (0=OPEN, 1=SETTLED).
    /// @return totalSharesBurned Total shares burned by all requestors.
    /// @return totalAssetsOwed Total USDC owed (set at settlement).
    /// @return totalAssetsClaimed Total USDC already claimed.
    function getEpochInfo(uint256 epochId)
        external
        view
        returns (EpochStatus status, uint256 totalSharesBurned, uint256 totalAssetsOwed, uint256 totalAssetsClaimed)
    {
        Epoch storage epoch = epochs[epochId];
        return (epoch.status, epoch.totalSharesBurned, epoch.totalAssetsOwed, epoch.totalAssetsClaimed);
    }

    /// @notice Get the balance of every registered yield source.
    /// @return balances Array of balances, one per yield source (same order as yieldSources).
    function getAllYieldSourceBalances() external view returns (uint256[] memory balances) {
        uint256 len = yieldSources.length;
        balances = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            balances[i] = yieldSources[i].balance();
        }
    }

    /// @notice Get the address of every registered yield source.
    /// @return sources Array of addresses, one per yield source.
    function getAllYieldSources() external view returns (address[] memory sources) {
        uint256 len = yieldSources.length;
        sources = new address[](len);
        for (uint256 i; i < len; ++i) {
            sources[i] = address(yieldSources[i]);
        }
    }

    /// @notice Current idle balance available for deployment (excluding claimable).
    function idleBalance() external view returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return idle > totalClaimableAssets ? idle - totalClaimableAssets : 0;
    }

    // ─── CRE View Functions ─────────────────────────────────────────────

    /// @notice Returns deployed balance for a specific yield source by address.
    /// @param source The yield source address.
    /// @return balance The current balance deployed to this source.
    function getSourceBalance(address source) external view returns (uint256 balance) {
        uint256 len = yieldSources.length;
        for (uint256 i; i < len; ++i) {
            if (address(yieldSources[i]) == source) {
                return yieldSources[i].balance();
            }
        }
        return 0;
    }

    /// @notice Returns all registered yield source addresses.
    /// @return sources Array of yield source addresses.
    function getYieldSources() external view returns (address[] memory sources) {
        uint256 len = yieldSources.length;
        sources = new address[](len);
        for (uint256 i; i < len; ++i) {
            sources[i] = address(yieldSources[i]);
        }
    }

    /// @notice Returns current risk parameters for a source.
    /// @param source The yield source address.
    /// @return params The source's CRE-updated risk parameters.
    function getSourceRiskParams(address source) external view returns (RiskModel.SourceRiskParams memory params) {
        params = sourceRiskParams[source];
    }

    /// @notice Returns the latest risk snapshot from CRE.
    /// @return snapshot The most recent risk snapshot.
    function getLatestRiskSnapshot() external view returns (RiskModel.RiskSnapshot memory snapshot) {
        snapshot = latestRiskSnapshot;
    }

    /// @notice Returns pending withdrawal amount for current epoch.
    /// @return pending Total shares pending settlement in current epoch.
    function getPendingEpochWithdrawals() external view returns (uint256 pending) {
        pending = epochs[currentEpochId].totalSharesBurned;
    }

    /// @notice Returns epoch timing info.
    /// @return epochId Current epoch ID.
    /// @return startTime When current epoch started.
    /// @return minDuration Minimum epoch duration before settlement.
    function getCurrentEpochInfo() external view returns (uint256 epochId, uint256 startTime, uint256 minDuration) {
        epochId = currentEpochId;
        startTime = epochOpenedAt;
        minDuration = MIN_EPOCH_DURATION;
    }

    /// @notice Computes current on-chain LCR using stored risk params.
    /// @dev HQLA = Σ(sourceBalance * (10000 - haircutBps)) / 10000 + idleBalance
    ///      Outflows = Σ(sourceBalance * stressOutflowBps) / 10000 + pendingWithdrawals
    ///      LCR = HQLA * 10000 / Outflows
    /// @return lcrBps The LCR in basis points (10000 = 100%).
    function computeLCR() external view returns (uint256 lcrBps) {
        uint256 len = yieldSources.length;
        uint256 totalHQLA;
        uint256 totalStressedOutflows;

        for (uint256 i; i < len; ++i) {
            address sourceAddr = address(yieldSources[i]);
            uint256 bal = yieldSources[i].balance();
            RiskModel.SourceRiskParams memory params = sourceRiskParams[sourceAddr];

            // HQLA contribution = balance * (1 - haircut)
            totalHQLA += RiskModel.computeSourceHQLA(bal, params.liquidityHaircutBps);
            // Stressed outflow contribution
            totalStressedOutflows += RiskModel.computeSourceStressedOutflow(bal, params.stressOutflowBps);
        }

        // Add idle balance (no haircut on idle)
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 availableIdle = idle > totalClaimableAssets ? idle - totalClaimableAssets : 0;
        totalHQLA += availableIdle;

        // Add pending withdrawals to outflows
        totalStressedOutflows += epochs[currentEpochId].totalSharesBurned;

        // Compute LCR (avoid division by zero)
        if (totalStressedOutflows == 0) {
            return type(uint256).max; // Infinite LCR if no outflows
        }

        lcrBps = (totalHQLA * RiskModel.BPS) / totalStressedOutflows;
    }

    // ─── Admin Functions ────────────────────────────────────────────────

    /// @notice Update the operator address.
    function setOperator(address _operator) external onlyOperator {
        if (_operator == address(0)) revert ZeroAddress();
        operator = _operator;
        emit OperatorUpdated(_operator);
    }

    /// @notice Update the fee recipient address.
    function setFeeRecipient(address _feeRecipient) external onlyOperator {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    /// @notice Update the management fee rate. Accrues at old rate first.
    function setManagementFee(uint256 _managementFeeBps) external onlyOperator {
        _accrueManagementFee();
        if (_managementFeeBps > MAX_MANAGEMENT_FEE_BPS) revert FeeTooHigh();
        managementFeeBps = _managementFeeBps;
        emit ManagementFeeUpdated(_managementFeeBps);
    }

    /// @notice Update the EMA smoothing period.
    function setSmoothingPeriod(uint256 _smoothingPeriod) external onlyOperator {
        if (_smoothingPeriod < MIN_SMOOTHING_PERIOD || _smoothingPeriod > MAX_SMOOTHING_PERIOD) {
            revert InvalidSmoothingPeriod();
        }
        smoothingPeriod = _smoothingPeriod;
        emit SmoothingPeriodUpdated(_smoothingPeriod);
    }

    /// @notice Pause deposits and new withdrawal requests.
    /// @dev Use in emergencies (e.g., yield source exploit, oracle failure).
    ///      Claims from settled epochs remain available — users can always exit.
    function pause() external onlyOperator {
        _pause();
        emit VaultPaused(msg.sender);
    }

    /// @notice Resume normal operations after pause.
    function unpause() external onlyOperator {
        _unpause();
        emit VaultUnpaused(msg.sender);
    }

    /// @notice Update the max drawdown threshold.
    /// @param _maxDrawdownBps New threshold in basis points (e.g., 1000 = 10%). Set to 0 to disable.
    function setMaxDrawdown(uint256 _maxDrawdownBps) external onlyOperator {
        if (_maxDrawdownBps > MAX_DRAWDOWN_BPS) revert InvalidDrawdownThreshold();
        maxDrawdownBps = _maxDrawdownBps;
        emit MaxDrawdownUpdated(_maxDrawdownBps);
    }

    /// @notice Reset the NAV high water mark to current NAV.
    /// @dev Use after recovering from a drawdown event and resuming operations.
    ///      This prevents the vault from immediately re-triggering the circuit breaker.
    function resetNavHighWaterMark() external onlyOperator {
        uint256 currentNav = navPerShare();
        navHighWaterMark = currentNav;
        emit NavHighWaterMarkUpdated(currentNav);
    }

    /// @notice Set the Chainlink CRE Forwarder address.
    /// @dev Only callable by operator. The Forwarder is the only address that can call onReport().
    /// @param forwarder The KeystoneForwarder contract address for this network.
    function setChainlinkForwarder(address forwarder) external onlyOperator {
        if (forwarder == address(0)) revert ZeroAddress();
        chainlinkForwarder = forwarder;
        emit ChainlinkForwarderUpdated(forwarder);
    }

    /// @notice Set the minimum LCR floor for deployment operations.
    /// @param _lcrFloorBps Minimum LCR in basis points (10000 = 100%).
    function setLCRFloor(uint256 _lcrFloorBps) external onlyOperator {
        lcrFloorBps = _lcrFloorBps;
        emit LCRFloorUpdated(_lcrFloorBps);
    }

    // ─── CRE Integration: onReport ──────────────────────────────────────

    /// @notice Called by Chainlink KeystoneForwarder after DON consensus verification.
    /// @dev The Forwarder has already verified that the DON reached consensus on this report.
    ///      We only need to verify msg.sender == chainlinkForwarder.
    /// @param metadata Workflow identification (workflow name, owner, report name).
    /// @param report ABI-encoded payload: (uint8 action, bytes actionData).
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        // metadata is unused but required by IReceiver interface
        (metadata);

        if (msg.sender != chainlinkForwarder) revert OnlyForwarder();

        (uint8 action, bytes memory actionData) = abi.decode(report, (uint8, bytes));

        if (action == ACTION_UPDATE_RISK_PARAMS) {
            _handleUpdateRiskParams(actionData);
        } else if (action == ACTION_DEFENSIVE_REBALANCE) {
            _handleDefensiveRebalance(actionData);
        } else if (action == ACTION_EMERGENCY_PAUSE) {
            _handleEmergencyPause(actionData);
        } else if (action == ACTION_SETTLE_EPOCH) {
            _handleSettleEpoch(actionData);
        } else if (action == ACTION_HARVEST_YIELD) {
            _handleHarvestYield(actionData);
        } else {
            revert InvalidAction(action);
        }
    }

    // ─── CRE Internal Action Handlers ───────────────────────────────────

    /// @dev Decodes and applies new risk parameters from CRE risk model.
    /// @param actionData Encoding: (address[] sources, SourceRiskParams[] params, RiskSnapshot snapshot).
    function _handleUpdateRiskParams(bytes memory actionData) internal {
        (address[] memory sources, RiskModel.SourceRiskParams[] memory params, RiskModel.RiskSnapshot memory snapshot) =
            abi.decode(actionData, (address[], RiskModel.SourceRiskParams[], RiskModel.RiskSnapshot));

        if (sources.length != params.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < sources.length; i++) {
            // Validate source is registered
            if (!isRegisteredSource[sources[i]]) revert UnknownSource(sources[i]);

            // Apply bounds checking on params (prevent CRE from setting absurd values)
            if (params[i].liquidityHaircutBps > RiskModel.MAX_HAIRCUT_BPS) revert HaircutTooHigh();
            if (params[i].maxConcentrationBps > uint16(RiskModel.BPS)) revert InvalidConcentration();

            params[i].lastUpdated = uint64(block.timestamp);
            sourceRiskParams[sources[i]] = params[i];
            emit RiskParamsUpdated(sources[i], params[i]);
        }

        latestRiskSnapshot = snapshot;
        emit RiskSnapshotUpdated(snapshot);
    }

    /// @dev Pulls capital from a source back to idle (vault holds underlying asset).
    /// @param actionData Encoding: (address source, uint256 amount).
    function _handleDefensiveRebalance(bytes memory actionData) internal {
        (address source, uint256 amount) = abi.decode(actionData, (address, uint256));
        if (!isRegisteredSource[source]) revert UnknownSource(source);

        // Find source index and withdraw
        uint256 len = yieldSources.length;
        for (uint256 i; i < len; ++i) {
            if (address(yieldSources[i]) == source) {
                yieldSources[i].withdraw(amount);
                emit DefensiveRebalanceTriggered(source, amount);
                return;
            }
        }
    }

    /// @dev Emergency pause — stops deposits and optionally begins unwinding.
    /// @param actionData Encoding: (uint8 severity).
    ///        severity 0 = pause deposits only, 1 = pause + begin unwind.
    function _handleEmergencyPause(bytes memory actionData) internal {
        (uint8 severity) = abi.decode(actionData, (uint8));
        _pause();
        emit EmergencyPauseTriggered(severity);
        emit VaultPaused(address(this));
        // NOTE: Unwind logic would go here for severity > 0
    }

    /// @dev Settles current epoch (same logic as existing settleEpoch).
    /// @param actionData Unused, reserved for future parameters.
    function _handleSettleEpoch(bytes memory actionData) internal {
        // actionData is unused for now but reserved for future parameters
        (actionData);
        _settleCurrentEpoch();
    }

    /// @dev Harvests yield from specified sources.
    /// @param actionData Encoding: (address[] sources).
    function _handleHarvestYield(bytes memory actionData) internal {
        (address[] memory sources) = abi.decode(actionData, (address[]));
        for (uint256 i = 0; i < sources.length; i++) {
            _harvestFromSource(sources[i]);
        }
    }

    /// @dev Internal settlement logic, callable by both settleEpoch() and _handleSettleEpoch().
    function _settleCurrentEpoch() internal {
        uint256 epochId = currentEpochId;
        Epoch storage epoch = epochs[epochId];

        if (epoch.status == EpochStatus.SETTLED) revert EpochAlreadySettled();
        if (block.timestamp - epochOpenedAt < MIN_EPOCH_DURATION) revert EpochTooYoung();

        _accrueManagementFee();
        _updateEma();
        _checkDrawdown();

        uint256 burnedShares = epoch.totalSharesBurned;

        // Use EMA instead of spot totalAssets for manipulation resistance.
        uint256 currentTotalAssets = emaTotalAssets;
        uint256 effectiveSupply = totalSupply() + totalPendingShares;
        uint256 assetsOwed =
            (effectiveSupply > 0) ? burnedShares.mulDiv(currentTotalAssets, effectiveSupply, Math.Rounding.Floor) : 0;

        // Pull from yield sources if idle funds are insufficient (waterfall)
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 available = idle > totalClaimableAssets ? idle - totalClaimableAssets : 0;

        if (assetsOwed > available) {
            uint256 remaining = assetsOwed - available;
            uint256 len = yieldSources.length;

            for (uint256 i; i < len && remaining > 0; ++i) {
                uint256 srcBal = yieldSources[i].balance();
                if (srcBal == 0) continue;

                uint256 pull = remaining > srcBal ? srcBal : remaining;
                yieldSources[i].withdraw(pull);
                remaining -= pull;

                emit WithdrawnFromYield(i, pull);
            }

            if (remaining > 0) revert InsufficientLiquidity();
        }

        epoch.totalAssetsOwed = assetsOwed;
        epoch.status = EpochStatus.SETTLED;
        totalPendingShares -= burnedShares;
        totalClaimableAssets += assetsOwed;

        currentEpochId = epochId + 1;
        epochOpenedAt = block.timestamp;

        emit EpochSettled(epochId, assetsOwed);
    }

    /// @dev Internal harvest logic for a single source by address.
    function _harvestFromSource(address source) internal {
        uint256 len = yieldSources.length;
        for (uint256 i; i < len; ++i) {
            if (address(yieldSources[i]) != source) continue;

            uint256 currentBalance = yieldSources[i].balance();
            uint256 hwm = lastHarvestedBalance[i];

            if (currentBalance > hwm) {
                uint256 profit = currentBalance - hwm;
                lastHarvestedBalance[i] = currentBalance;

                if (profit > 0 && performanceFeeBps > 0 && feeRecipient != address(0)) {
                    uint256 feeAssets = profit.mulDiv(performanceFeeBps, 10_000, Math.Rounding.Floor);
                    uint256 feeShares = _convertToSharesAtEma(feeAssets);

                    if (feeShares > 0) {
                        _mint(feeRecipient, feeShares);
                        emit YieldHarvested(profit, feeShares);
                    }
                }
            }
            return;
        }
    }

    function _onlyOperator() internal view {
        if (msg.sender != operator) revert OnlyOperator();
    }
}
