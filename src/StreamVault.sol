// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IYieldSource} from "./IYieldSource.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC7540Redeem, IERC7540Operator} from "./interfaces/IERC7540.sol";
import {FeeLib} from "./libraries/FeeLib.sol";
import {IComplianceRouter} from "./compliance/IComplianceRouter.sol";

/// @title StreamVault
/// @notice UUPS-upgradeable ERC-4626 vault with async (epoch-based) withdrawals, multi-connector
///         yield sources, compliance module integration, and continuous management fee accrual.
///         Deposits are instant. Withdrawals go through a three-step process:
///         requestWithdraw → settleEpoch → claimWithdrawal.
contract StreamVault is
    Initializable,
    ERC4626Upgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    UUPSUpgradeable,
    EIP712,
    IERC7540Redeem
{
    using SafeERC20 for IERC20;
    using Math for uint256;
    using FeeLib for uint256;

    // ─── Constants ────────────────────────────────────────────────────────

    uint256 public constant MAX_YIELD_SOURCES = 20;
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 5_000; // 50%
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 500; // 5% annual
    uint256 public constant SECONDS_PER_YEAR = 365.25 days; // 31_557_600
    uint256 public constant MIN_EPOCH_DURATION = 300; // 5 minutes — prevents settlement timing attacks
    uint256 public constant MAX_DRAWDOWN_BPS = 5_000; // Max configurable drawdown: 50%
    uint256 public constant DEFAULT_MAX_DRAWDOWN_BPS = 1_000; // Default: 10% drawdown triggers pause
    uint256 public constant MAX_WITHDRAWAL_FEE_BPS = 100; // 1% max exit fee
    uint256 public constant MAX_LOCKUP_PERIOD = 7 days;

    // ─── RBAC Role Constants ────────────────────────────────────────────
    bytes32 public constant ROLE_GUARDIAN = keccak256("ROLE_GUARDIAN");

    // ─── EIP-712 Typehash ──────────────────────────────────────────────
    bytes32 public constant SET_OPERATOR_TYPEHASH =
        keccak256("SetOperator(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)");

    // ─── Types ──────────────────────────────────────────────────────────

    enum EpochStatus {
        OPEN,
        SETTLED
    }

    struct Epoch {
        EpochStatus status;
        uint256 totalSharesBurned;
        uint256 totalAssetsOwed;
        uint256 totalAssetsClaimed;
    }

    struct WithdrawRequest {
        uint256 shares;
    }

    // ─── State ──────────────────────────────────────────────────────────

    IYieldSource[] public yieldSources;
    address public operator;
    address public pendingOperator;
    address public feeRecipient;
    uint256 public performanceFeeBps;

    uint256 public currentEpochId;
    uint256 public totalPendingShares;
    uint256 public totalClaimableAssets;

    mapping(uint256 => uint256) public lastHarvestedBalance;

    // ─── Management Fee State ───────────────────────────────────────────

    uint256 public managementFeeBps;
    uint256 public lastFeeAccrualTimestamp;

    // ─── Epoch Timing ───────────────────────────────────────────────────

    uint256 public epochOpenedAt;

    // ─── Drawdown Protection State ───────────────────────────────────────

    uint256 public navHighWaterMark;
    uint256 public maxDrawdownBps;

    // ─── Compliance Module ──────────────────────────────────────────────

    IComplianceRouter public complianceRouter;

    // ─── Mappings ───────────────────────────────────────────────────────

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => WithdrawRequest)) public withdrawRequests;

    // ─── Feature: Deposit Cap ─────────────────────────────────────────────

    uint256 public depositCap;

    // ─── Feature: Withdrawal Fee ──────────────────────────────────────────

    uint256 public withdrawalFeeBps;

    // ─── Feature: Deposit Lockup ──────────────────────────────────────────

    uint256 public lockupPeriod;
    mapping(address => uint256) public depositTimestamp;

    // ─── Feature: Transfer Restrictions ───────────────────────────────────

    bool public transfersRestricted;
    mapping(address => bool) public transferWhitelist;

    // ─── Feature: EIP-7540 Operator ───────────────────────────────────────

    mapping(address => mapping(address => bool)) private _isOperator7540;

    // ─── Feature: RBAC ─────────────────────────────────────────────────
    mapping(bytes32 => mapping(address => bool)) private _roles;

    // ─── Feature: EIP-712 Nonces ───────────────────────────────────────
    mapping(address => uint256) public nonces;

    // ─── Storage Gap ─────────────────────────────────────────────────────

    uint256[40] private __gap;

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
    event OperatorTransferRequested(address indexed currentOperator, address indexed pendingOperator);
    event OperatorUpdated(address indexed newOperator);
    event FeeRecipientUpdated(address indexed newFeeRecipient);
    event ManagementFeeUpdated(uint256 newFeeBps);
    event VaultPaused(address indexed by);
    event VaultUnpaused(address indexed by);
    event DrawdownCircuitBreaker(uint256 currentNav, uint256 highWaterMark, uint256 drawdownBps);
    event NavHighWaterMarkUpdated(uint256 newHighWaterMark);
    event MaxDrawdownUpdated(uint256 newMaxDrawdownBps);
    event DepositCapUpdated(uint256 newCap);
    event WithdrawalFeeUpdated(uint256 newFeeBps);
    event WithdrawalFeePaid(address indexed user, uint256 feeAmount, address indexed feeRecipient);
    event LockupPeriodUpdated(uint256 newPeriod);
    event TransfersRestrictionUpdated(bool restricted);
    event TransferWhitelistUpdated(address indexed account, bool whitelisted);
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ComplianceRouterUpdated(address indexed router);

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
    error EpochTooYoung();
    error InvalidDrawdownThreshold();
    error ArrayLengthMismatch();
    error SyncWithdrawDisabled();
    error OnlyPendingOperator();
    error NoPendingOperator();
    error WithdrawalFeeTooHigh();
    error LockupPeriodActive();
    error LockupPeriodTooLong();
    error TransferRestricted();
    error ERC7540Unauthorized();
    error RescueUnderlyingForbidden();
    error SignatureExpired();
    error InvalidSigner();
    error SlippageExceeded(uint256 actual, uint256 minimum);
    error YieldSourceBalanceMismatch(uint256 expected, uint256 actual);

    // ─── Modifiers ──────────────────────────────────────────────────────

    modifier onlyOperator() {
        _onlyOperator();
        _;
    }

    modifier onlyRole(bytes32 role) {
        if (msg.sender != operator && !_roles[role][msg.sender]) revert OnlyOperator();
        _;
    }

    // ─── Constructor & Initializer ──────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() EIP712("StreamVault", "1") {
        _disableInitializers();
    }

    /// @notice Initialize the vault (called once via proxy).
    /// @param _asset The underlying asset (e.g., USDC).
    /// @param _operator The operator address (manages yield, settles epochs).
    /// @param _feeRecipient The address receiving performance and management fees.
    /// @param _performanceFeeBps Performance fee in basis points (e.g., 1000 = 10%).
    /// @param _managementFeeBps Annual management fee in basis points (e.g., 200 = 2%).
    /// @param _name ERC-20 share token name.
    /// @param _symbol ERC-20 share token symbol.
    function initialize(
        IERC20 _asset,
        address _operator,
        address _feeRecipient,
        uint256 _performanceFeeBps,
        uint256 _managementFeeBps,
        string memory _name,
        string memory _symbol
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __ERC4626_init(_asset);
        __Pausable_init();

        if (_operator == address(0)) revert ZeroAddress();
        if (_performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        if (_managementFeeBps > MAX_MANAGEMENT_FEE_BPS) revert FeeTooHigh();

        operator = _operator;
        feeRecipient = _feeRecipient;
        performanceFeeBps = _performanceFeeBps;
        managementFeeBps = _managementFeeBps;
        lastFeeAccrualTimestamp = block.timestamp;
        epochOpenedAt = block.timestamp;

        // Initialize drawdown protection with default 10% threshold
        maxDrawdownBps = DEFAULT_MAX_DRAWDOWN_BPS;
        navHighWaterMark = 0;
    }

    // ─── ERC-4626 Overrides ─────────────────────────────────────────────

    /// @notice Total assets under management, excluding assets already owed to settled withdrawers.
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));

        uint256 deployed;
        uint256 len = yieldSources.length;
        for (uint256 i; i < len; ++i) {
            deployed += yieldSources[i].balance();
        }

        uint256 gross = idle + deployed;
        if (gross < totalClaimableAssets) return 0;
        return gross - totalClaimableAssets;
    }

    /// @dev Virtual share offset for inflation attack protection.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @notice Override to accrue management fee and run compliance check.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        whenNotPaused
    {
        // Compliance check
        if (address(complianceRouter) != address(0)) {
            complianceRouter.checkDeposit(address(this), receiver, assets);
        }

        _accrueManagementFee();

        super._deposit(caller, receiver, assets, shares);

        // Track deposit timestamp for lockup enforcement
        depositTimestamp[receiver] = block.timestamp;
    }

    /// @notice Disable standard ERC-4626 withdraw.
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert SyncWithdrawDisabled();
    }

    /// @notice Disable standard ERC-4626 redeem.
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert SyncWithdrawDisabled();
    }

    /// @notice Returns 0 when paused. Respects deposit cap when set.
    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 current = totalAssets();
        return current >= depositCap ? 0 : depositCap - current;
    }

    /// @notice Returns 0 when paused. Respects deposit cap when set.
    function maxMint(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 current = totalAssets();
        if (current >= depositCap) return 0;
        return convertToShares(depositCap - current);
    }

    /// @notice Always returns 0 — sync withdrawals are disabled.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Always returns 0 — sync redeems are disabled.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    // ─── Slippage-Protected Deposit Functions ─────────────────────────────

    /// @notice Deposit assets with slippage protection.
    function depositWithSlippage(uint256 assets, address receiver, uint256 minSharesOut)
        external
        returns (uint256 shares)
    {
        shares = deposit(assets, receiver);
        if (shares < minSharesOut) {
            revert SlippageExceeded(shares, minSharesOut);
        }
    }

    /// @notice Mint exact shares with slippage protection on assets spent.
    function mintWithSlippage(uint256 shares, address receiver, uint256 maxAssetsIn) external returns (uint256 assets) {
        assets = mint(shares, receiver);
        if (assets > maxAssetsIn) {
            revert SlippageExceeded(assets, maxAssetsIn);
        }
    }

    /// @notice Always reverts — sync withdrawals are disabled.
    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert SyncWithdrawDisabled();
    }

    /// @notice Always reverts — sync redeems are disabled.
    function previewRedeem(uint256) public pure override returns (uint256) {
        revert SyncWithdrawDisabled();
    }

    // ─── Yield Source Management ────────────────────────────────────────

    /// @notice Add a new yield source connector.
    function addYieldSource(IYieldSource source) external onlyOperator {
        _addYieldSourceInternal(source);
    }

    /// @notice Remove a yield source. Must have zero balance.
    function removeYieldSource(uint256 sourceIndex) external onlyOperator {
        _removeYieldSourceInternal(sourceIndex);
    }

    /// @notice Returns the number of registered yield sources.
    function yieldSourceCount() external view returns (uint256) {
        return yieldSources.length;
    }

    // ─── Async Withdrawal: Step 1 — Request ────────────────────────────

    /// @notice Burn shares and queue a withdrawal request in the current epoch.
    function requestWithdraw(uint256 shares) external nonReentrant whenNotPaused {
        if (shares == 0) revert ZeroShares();
        if (lockupPeriod > 0 && block.timestamp < depositTimestamp[msg.sender] + lockupPeriod) {
            revert LockupPeriodActive();
        }

        _accrueManagementFee();

        _burn(msg.sender, shares);

        uint256 epochId = currentEpochId;
        epochs[epochId].totalSharesBurned += shares;
        withdrawRequests[epochId][msg.sender].shares += shares;
        totalPendingShares += shares;

        emit WithdrawRequested(msg.sender, epochId, shares);
    }

    // ─── Async Withdrawal: Step 2 — Settle ─────────────────────────────

    /// @notice Settle the current epoch using spot NAV.
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

        // Apply withdrawal fee
        uint256 fee;
        if (withdrawalFeeBps > 0 && feeRecipient != address(0)) {
            fee = FeeLib.computeWithdrawalFee(payout, withdrawalFeeBps);
            payout -= fee;
        }

        epoch.totalAssetsClaimed += payout + fee;
        totalClaimableAssets -= (payout + fee);

        IERC20(asset()).safeTransfer(msg.sender, payout);
        if (fee > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, fee);
            emit WithdrawalFeePaid(msg.sender, fee, feeRecipient);
        }

        emit WithdrawalClaimed(msg.sender, epochId, payout);
    }

    // ─── Operator Functions ─────────────────────────────────────────────

    /// @notice Deploy idle USDC to a specific yield source.
    function deployToYield(uint256 sourceIndex, uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (sourceIndex >= yieldSources.length) revert InvalidSourceIndex();

        _accrueManagementFee();

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

        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        yieldSources[sourceIndex].withdraw(amount);
        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));

        uint256 received = balanceAfter - balanceBefore;
        if (received + 1 < amount) {
            revert YieldSourceBalanceMismatch(amount, received);
        }

        emit WithdrawnFromYield(sourceIndex, amount);
    }

    /// @notice Harvest yield from all sources using per-source high water marks.
    function harvestYield() external onlyOperator nonReentrant {
        _accrueManagementFee();
        _checkDrawdown();

        uint256 totalProfit;
        uint256 len = yieldSources.length;

        for (uint256 i; i < len; ++i) {
            uint256 currentBalance = yieldSources[i].balance();
            uint256 hwm = lastHarvestedBalance[i];

            if (currentBalance > hwm) {
                totalProfit += currentBalance - hwm;
                lastHarvestedBalance[i] = currentBalance;
            }
        }

        if (totalProfit == 0 || performanceFeeBps == 0 || feeRecipient == address(0)) return;

        uint256 feeAssets = FeeLib.computePerformanceFee(totalProfit, performanceFeeBps);
        uint256 feeShares = FeeLib.convertToShares(feeAssets, totalSupply(), totalAssets(), _decimalsOffset());

        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
            emit YieldHarvested(totalProfit, feeShares);
        }
    }

    // ─── Internal: Management Fee ───────────────────────────────────────

    /// @notice Accrue time-proportional management fee via share dilution.
    function _accrueManagementFee() internal {
        if (managementFeeBps == 0 || feeRecipient == address(0)) return;

        uint256 elapsed = block.timestamp - lastFeeAccrualTimestamp;
        if (elapsed == 0) return;

        uint256 netAssets = totalAssets();

        if (netAssets == 0) {
            lastFeeAccrualTimestamp = block.timestamp;
            return;
        }

        uint256 feeAssets = FeeLib.computeManagementFee(netAssets, managementFeeBps, elapsed, SECONDS_PER_YEAR);

        lastFeeAccrualTimestamp = block.timestamp;

        if (feeAssets == 0) return;

        uint256 feeShares = FeeLib.convertToShares(feeAssets, totalSupply(), netAssets, _decimalsOffset());

        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
            emit ManagementFeeAccrued(feeAssets, feeShares, elapsed);
        }
    }

    /// @notice Calculate the current NAV per share in 18-decimal precision.
    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return totalAssets().mulDiv(1e18, supply, Math.Rounding.Floor);
    }

    /// @notice Check for excessive drawdown and auto-pause if threshold exceeded.
    function _checkDrawdown() internal {
        if (maxDrawdownBps == 0) return;

        uint256 currentNav = navPerShare();

        if (currentNav > navHighWaterMark) {
            navHighWaterMark = currentNav;
            emit NavHighWaterMarkUpdated(currentNav);
            return;
        }

        uint256 drawdownBps = ((navHighWaterMark - currentNav) * 10_000) / navHighWaterMark;

        if (drawdownBps >= maxDrawdownBps && !paused()) {
            _pause();
            emit DrawdownCircuitBreaker(currentNav, navHighWaterMark, drawdownBps);
            emit VaultPaused(address(this));
        }
    }

    // ─── Batch Operations ─────────────────────────────────────────────

    /// @notice Claim withdrawals from multiple settled epochs in a single transaction.
    function batchClaimWithdrawals(uint256[] calldata epochIds) external nonReentrant {
        uint256 len = epochIds.length;
        uint256 totalPayout;
        uint256 totalFee;

        for (uint256 i; i < len; ++i) {
            uint256 epochId = epochIds[i];
            Epoch storage epoch = epochs[epochId];
            if (epoch.status != EpochStatus.SETTLED) revert EpochNotSettled();

            WithdrawRequest storage req = withdrawRequests[epochId][msg.sender];
            if (req.shares == 0) revert NoRequestInEpoch();

            uint256 userShares = req.shares;
            req.shares = 0;

            uint256 payout = userShares.mulDiv(epoch.totalAssetsOwed, epoch.totalSharesBurned, Math.Rounding.Floor);

            uint256 fee;
            if (withdrawalFeeBps > 0 && feeRecipient != address(0)) {
                fee = FeeLib.computeWithdrawalFee(payout, withdrawalFeeBps);
                payout -= fee;
                totalFee += fee;
            }

            epoch.totalAssetsClaimed += payout + fee;
            totalPayout += payout;

            emit WithdrawalClaimed(msg.sender, epochId, payout);
            if (fee > 0) emit WithdrawalFeePaid(msg.sender, fee, feeRecipient);
        }

        totalClaimableAssets -= (totalPayout + totalFee);
        IERC20(asset()).safeTransfer(msg.sender, totalPayout);
        if (totalFee > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, totalFee);
        }
    }

    // ─── View Functions ──────────────────────────────────────────────────

    /// @notice Get a user's withdraw request for a specific epoch.
    function getUserWithdrawRequest(uint256 epochId, address user) external view returns (uint256 shares) {
        shares = withdrawRequests[epochId][user].shares;
    }

    /// @notice Get full epoch info.
    function getEpochInfo(uint256 epochId)
        external
        view
        returns (EpochStatus status, uint256 totalSharesBurned, uint256 totalAssetsOwed, uint256 totalAssetsClaimed)
    {
        Epoch storage epoch = epochs[epochId];
        return (epoch.status, epoch.totalSharesBurned, epoch.totalAssetsOwed, epoch.totalAssetsClaimed);
    }

    /// @notice Get the balance of every registered yield source.
    function getAllYieldSourceBalances() external view returns (uint256[] memory balances) {
        uint256 len = yieldSources.length;
        balances = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            balances[i] = yieldSources[i].balance();
        }
    }

    /// @notice Current idle balance available for deployment.
    function idleBalance() external view returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return idle > totalClaimableAssets ? idle - totalClaimableAssets : 0;
    }

    /// @notice Returns all registered yield source addresses.
    function getYieldSources() external view returns (address[] memory sources) {
        uint256 len = yieldSources.length;
        sources = new address[](len);
        for (uint256 i; i < len; ++i) {
            sources[i] = address(yieldSources[i]);
        }
    }

    /// @notice Returns pending withdrawal amount for current epoch.
    function getPendingEpochWithdrawals() external view returns (uint256 pending) {
        pending = epochs[currentEpochId].totalSharesBurned;
    }

    /// @notice Returns epoch timing info.
    function getCurrentEpochInfo() external view returns (uint256 epochId, uint256 startTime, uint256 minDuration) {
        epochId = currentEpochId;
        startTime = epochOpenedAt;
        minDuration = MIN_EPOCH_DURATION;
    }

    // ─── Admin Functions ────────────────────────────────────────────────

    /// @notice Propose a new operator (step 1 of 2-step transfer).
    function transferOperator(address _pendingOperator) external onlyOperator {
        if (_pendingOperator == address(0)) revert ZeroAddress();
        pendingOperator = _pendingOperator;
        emit OperatorTransferRequested(operator, _pendingOperator);
    }

    /// @notice Accept the operator role (step 2 of 2-step transfer).
    function acceptOperator() external {
        if (msg.sender != pendingOperator) revert OnlyPendingOperator();
        if (pendingOperator == address(0)) revert NoPendingOperator();
        operator = pendingOperator;
        pendingOperator = address(0);
        emit OperatorUpdated(msg.sender);
    }

    /// @notice Update the fee recipient address.
    function setFeeRecipient(address _feeRecipient) external onlyOperator {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    /// @notice Update the management fee rate.
    function setManagementFee(uint256 _managementFeeBps) external onlyOperator {
        _setManagementFeeInternal(_managementFeeBps);
    }

    /// @notice Pause deposits and new withdrawal requests.
    function pause() external onlyRole(ROLE_GUARDIAN) {
        _pause();
        emit VaultPaused(msg.sender);
    }

    /// @notice Resume normal operations after pause.
    function unpause() external onlyRole(ROLE_GUARDIAN) {
        _unpause();
        emit VaultUnpaused(msg.sender);
    }

    /// @notice Update the max drawdown threshold.
    function setMaxDrawdown(uint256 _maxDrawdownBps) external onlyOperator {
        if (_maxDrawdownBps > MAX_DRAWDOWN_BPS) revert InvalidDrawdownThreshold();
        maxDrawdownBps = _maxDrawdownBps;
        emit MaxDrawdownUpdated(_maxDrawdownBps);
    }

    /// @notice Reset the NAV high water mark to current NAV.
    function resetNavHighWaterMark() external onlyOperator {
        uint256 currentNav = navPerShare();
        navHighWaterMark = currentNav;
        emit NavHighWaterMarkUpdated(currentNav);
    }

    /// @notice Set the compliance router address.
    function setComplianceRouter(address router) external onlyOperator {
        complianceRouter = IComplianceRouter(router);
        emit ComplianceRouterUpdated(router);
    }

    // ─── Feature: Deposit Cap ─────────────────────────────────────────────

    /// @notice Set the maximum total assets (TVL cap). 0 = unlimited.
    function setDepositCap(uint256 _depositCap) external onlyOperator {
        depositCap = _depositCap;
        emit DepositCapUpdated(_depositCap);
    }

    // ─── Feature: Withdrawal Fee ──────────────────────────────────────────

    /// @notice Set the withdrawal fee in basis points (max 100 = 1%).
    function setWithdrawalFee(uint256 _withdrawalFeeBps) external onlyOperator {
        _setWithdrawalFeeInternal(_withdrawalFeeBps);
    }

    // ─── Feature: Deposit Lockup ──────────────────────────────────────────

    /// @notice Set the deposit lockup period. 0 = disabled.
    function setLockupPeriod(uint256 _lockupPeriod) external onlyOperator {
        if (_lockupPeriod > MAX_LOCKUP_PERIOD) revert LockupPeriodTooLong();
        lockupPeriod = _lockupPeriod;
        emit LockupPeriodUpdated(_lockupPeriod);
    }

    // ─── Feature: Transfer Restrictions ───────────────────────────────────

    /// @notice Enable or disable share transfer restrictions.
    function setTransfersRestricted(bool _restricted) external onlyOperator {
        transfersRestricted = _restricted;
        emit TransfersRestrictionUpdated(_restricted);
    }

    /// @notice Set whitelist status for a single address.
    function setTransferWhitelist(address account, bool whitelisted) external onlyOperator {
        if (account == address(0)) revert ZeroAddress();
        transferWhitelist[account] = whitelisted;
        emit TransferWhitelistUpdated(account, whitelisted);
    }

    /// @notice Batch set whitelist status for multiple addresses.
    function batchSetTransferWhitelist(address[] calldata accounts, bool[] calldata statuses) external onlyOperator {
        if (accounts.length != statuses.length) revert ArrayLengthMismatch();
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            transferWhitelist[accounts[i]] = statuses[i];
            emit TransferWhitelistUpdated(accounts[i], statuses[i]);
        }
    }

    // ─── Feature: EIP-7540 Async Redeem ───────────────────────────────────

    /// @notice EIP-7540: Set an operator who can manage redemption requests on your behalf.
    function setOperator(address _operator, bool approved) external returns (bool) {
        _isOperator7540[msg.sender][_operator] = approved;
        emit OperatorSet(msg.sender, _operator, approved);
        return true;
    }

    /// @notice EIP-7540: Check if an address is approved as an operator for a controller.
    function isOperator(address controller, address _operator) external view returns (bool) {
        return _isOperator7540[controller][_operator];
    }

    /// @notice EIP-7540: Request async redemption.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroShares();
        if (owner != msg.sender && !_isOperator7540[owner][msg.sender]) {
            revert ERC7540Unauthorized();
        }
        if (lockupPeriod > 0 && block.timestamp < depositTimestamp[owner] + lockupPeriod) {
            revert LockupPeriodActive();
        }

        _accrueManagementFee();

        _burn(owner, shares);

        uint256 epochId = currentEpochId;
        epochs[epochId].totalSharesBurned += shares;
        withdrawRequests[epochId][controller].shares += shares;
        totalPendingShares += shares;

        requestId = epochId;

        emit WithdrawRequested(controller, epochId, shares);
        emit RedeemRequest(controller, owner, epochId, msg.sender, shares);
    }

    /// @notice EIP-7540: Returns pending (unsettled) shares for a controller in an epoch.
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares) {
        if (epochs[requestId].status == EpochStatus.OPEN) {
            return withdrawRequests[requestId][controller].shares;
        }
        return 0;
    }

    /// @notice EIP-7540: Returns claimable shares for a controller in a settled epoch.
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares)
    {
        if (epochs[requestId].status == EpochStatus.SETTLED) {
            return withdrawRequests[requestId][controller].shares;
        }
        return 0;
    }

    /// @notice ERC-165 interface detection.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == 0x01ffc9a7;
    }

    // ─── UUPS Upgrade Authorization ──────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyOperator {
        // Operator-only upgrade authorization
    }

    // ─── Internal Settlement Logic ───────────────────────────────────────

    function _settleCurrentEpoch() internal {
        uint256 epochId = currentEpochId;
        Epoch storage epoch = epochs[epochId];

        if (epoch.status == EpochStatus.SETTLED) revert EpochAlreadySettled();
        if (block.timestamp - epochOpenedAt < MIN_EPOCH_DURATION) revert EpochTooYoung();

        _accrueManagementFee();
        _checkDrawdown();

        uint256 burnedShares = epoch.totalSharesBurned;
        uint256 currentTotalAssets = totalAssets();
        uint256 effectiveSupply = totalSupply() + totalPendingShares;
        uint256 assetsOwed =
            (effectiveSupply > 0) ? burnedShares.mulDiv(currentTotalAssets, effectiveSupply, Math.Rounding.Floor) : 0;

        // Pull from yield sources if idle funds are insufficient
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 available = idle > totalClaimableAssets ? idle - totalClaimableAssets : 0;

        if (assetsOwed > available) {
            uint256 remaining = assetsOwed - available;
            uint256 len = yieldSources.length;

            for (uint256 i; i < len && remaining > 0; ++i) {
                uint256 srcBal = yieldSources[i].balance();
                if (srcBal == 0) continue;

                uint256 pull = remaining > srcBal ? srcBal : remaining;
                uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
                yieldSources[i].withdraw(pull);
                uint256 received = IERC20(asset()).balanceOf(address(this)) - balanceBefore;

                if (received + 1 < pull) {
                    revert YieldSourceBalanceMismatch(pull, received);
                }

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

    // ─── Transfer Restrictions (ERC20 hook) ────────────────────────────

    function _update(address from, address to, uint256 value) internal override {
        // Compliance check for transfers (not mints/burns)
        if (from != address(0) && to != address(0)) {
            if (address(complianceRouter) != address(0)) {
                complianceRouter.checkTransfer(address(this), from, to, value);
            }

            if (transfersRestricted && !transferWhitelist[to]) {
                revert TransferRestricted();
            }
        }
        super._update(from, to, value);
    }

    // ─── Feature: RBAC ───────────────────────────────────────────────────

    function grantRole(bytes32 role, address account) external onlyOperator {
        if (account == address(0)) revert ZeroAddress();
        _roles[role][account] = true;
        emit RoleGranted(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyOperator {
        _roles[role][account] = false;
        emit RoleRevoked(role, account);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return account == operator || _roles[role][account];
    }

    // ─── Feature: Rescuable ─────────────────────────────────────────────

    function rescueToken(IERC20 token, address to, uint256 amount) external onlyOperator {
        if (address(token) == asset()) revert RescueUnderlyingForbidden();
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit TokenRescued(address(token), to, amount);
    }

    // ─── Feature: EIP-712 Gasless Operator Approval ─────────────────────

    function setOperatorWithSig(
        address signer,
        address _operator,
        bool approved,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash =
            keccak256(abi.encode(SET_OPERATOR_TYPEHASH, signer, _operator, approved, nonces[signer]++, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);

        address recovered = ECDSA.recover(digest, v, r, s);
        if (recovered != signer) revert InvalidSigner();

        _isOperator7540[signer][_operator] = approved;
        emit OperatorSet(signer, _operator, approved);
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _addYieldSourceInternal(IYieldSource source) internal {
        if (address(source) == address(0)) revert ZeroAddress();
        if (source.asset() != asset()) revert AssetMismatch();
        if (yieldSources.length >= MAX_YIELD_SOURCES) revert TooManyYieldSources();

        yieldSources.push(source);
        emit YieldSourceAdded(yieldSources.length - 1, address(source));
    }

    function _removeYieldSourceInternal(uint256 sourceIndex) internal {
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

    function _setManagementFeeInternal(uint256 _managementFeeBps) internal {
        _accrueManagementFee();
        if (_managementFeeBps > MAX_MANAGEMENT_FEE_BPS) revert FeeTooHigh();
        managementFeeBps = _managementFeeBps;
        emit ManagementFeeUpdated(_managementFeeBps);
    }

    function _setWithdrawalFeeInternal(uint256 _withdrawalFeeBps) internal {
        if (_withdrawalFeeBps > MAX_WITHDRAWAL_FEE_BPS) revert WithdrawalFeeTooHigh();
        withdrawalFeeBps = _withdrawalFeeBps;
        emit WithdrawalFeeUpdated(_withdrawalFeeBps);
    }


    // ─── Internal Helpers ─────────────────────────────────────────────────

    function _onlyOperator() internal view {
        if (msg.sender != operator) revert OnlyOperator();
    }
}
