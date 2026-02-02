// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IYieldSource} from "./IYieldSource.sol";

/// @title StreamVault
/// @notice ERC-4626 vault with async (epoch-based) withdrawals, multi-connector yield sources,
///         EMA-smoothed NAV for manipulation-resistant settlement, and continuous management fee accrual.
///         Deposits are instant. Withdrawals go through a three-step process:
///         requestWithdraw → settleEpoch → claimWithdrawal.
contract StreamVault is ERC4626, ReentrancyGuard {
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

    // ─── Mappings ───────────────────────────────────────────────────────

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => WithdrawRequest)) public withdrawRequests;

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

    // ─── Modifiers ──────────────────────────────────────────────────────

    modifier onlyOperator() {
        _onlyOperator();
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
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
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
        emit YieldSourceAdded(yieldSources.length - 1, address(source));
    }

    /// @notice Remove a yield source. Must have zero balance.
    function removeYieldSource(uint256 sourceIndex) external onlyOperator {
        uint256 len = yieldSources.length;
        if (sourceIndex >= len) revert InvalidSourceIndex();

        IYieldSource source = yieldSources[sourceIndex];
        if (source.balance() != 0) revert SourceNotEmpty();

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
    function requestWithdraw(uint256 shares) external nonReentrant {
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
        uint256 epochId = currentEpochId;
        Epoch storage epoch = epochs[epochId];

        if (epoch.status == EpochStatus.SETTLED) revert EpochAlreadySettled();
        if (block.timestamp - epochOpenedAt < MIN_EPOCH_DURATION) revert EpochTooYoung();

        _accrueManagementFee();
        _updateEma();

        uint256 burnedShares = epoch.totalSharesBurned;

        // Use EMA instead of spot totalAssets for manipulation resistance.
        // effectiveSupply reconstructs the pre-burn denominator.
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
    function deployToYield(uint256 sourceIndex, uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (sourceIndex >= yieldSources.length) revert InvalidSourceIndex();

        _accrueManagementFee();
        _updateEma();

        IYieldSource source = yieldSources[sourceIndex];
        IERC20(asset()).forceApprove(address(source), amount);
        source.deposit(amount);

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

    function _onlyOperator() internal view {
        if (msg.sender != operator) revert OnlyOperator();
    }
}
