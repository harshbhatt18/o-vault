// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IYieldSource} from "./IYieldSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal Aave V3 Pool interface (supply-only, no borrowing).
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );
}

/// @title AaveV3YieldSource
/// @notice Yield source adapter for Aave V3. Deposits underlying into the Aave Pool
///         and tracks balance via the rebasing aToken.
/// @dev This contract holds its own aToken position. Only the authorized vault can interact.
contract AaveV3YieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable UNDERLYING_ASSET;
    IERC20 public immutable A_TOKEN;
    IPool public immutable POOL;
    address public immutable VAULT;

    error OnlyVault();

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    /// @param _asset The underlying asset (e.g. USDC).
    /// @param _pool The Aave V3 Pool contract.
    /// @param _aToken The corresponding aToken (e.g. aUSDC).
    /// @param _vault The StreamVault that owns this adapter.
    constructor(address _asset, address _pool, address _aToken, address _vault) {
        UNDERLYING_ASSET = IERC20(_asset);
        POOL = IPool(_pool);
        A_TOKEN = IERC20(_aToken);
        VAULT = _vault;
    }

    /// @notice Pull underlying from the vault and supply to Aave.
    function deposit(uint256 amount) external onlyVault {
        UNDERLYING_ASSET.safeTransferFrom(msg.sender, address(this), amount);
        UNDERLYING_ASSET.forceApprove(address(POOL), amount);
        POOL.supply(address(UNDERLYING_ASSET), amount, address(this), 0);
    }

    /// @notice Withdraw underlying from Aave and send back to the vault.
    /// @dev Uses the actual amount returned by Aave to handle potential rounding.
    function withdraw(uint256 amount) external onlyVault {
        uint256 actual = POOL.withdraw(address(UNDERLYING_ASSET), amount, address(this));
        UNDERLYING_ASSET.safeTransfer(VAULT, actual);
    }

    /// @notice Current balance including accrued interest (aToken rebases automatically).
    function balance() external view returns (uint256) {
        return A_TOKEN.balanceOf(address(this));
    }

    /// @notice The underlying asset address.
    function asset() external view returns (address) {
        return address(UNDERLYING_ASSET);
    }

    // ─── CRE View Functions ─────────────────────────────────────────────

    /// @notice Returns Aave pool utilization for the underlying asset.
    /// @dev Utilization = totalDebt / (totalDebt + availableLiquidity)
    ///      Returns in basis points (10000 = 100% utilization).
    function getPoolUtilization() external view returns (uint256 utilizationBps) {
        // Total liquidity available in the pool is the aToken total supply minus what's borrowed
        // Available liquidity = underlying balance of the aToken contract
        uint256 availableLiquidity = UNDERLYING_ASSET.balanceOf(address(A_TOKEN));

        // Total aToken supply represents total deposits (available + borrowed)
        uint256 totalDeposits = A_TOKEN.totalSupply();

        if (totalDeposits == 0) return 0;

        // Borrowed = totalDeposits - availableLiquidity
        uint256 totalBorrowed = totalDeposits > availableLiquidity ? totalDeposits - availableLiquidity : 0;

        // Utilization = borrowed / totalDeposits
        utilizationBps = (totalBorrowed * 10000) / totalDeposits;
    }

    /// @notice Returns available liquidity we could withdraw right now.
    /// @dev This is the minimum of our balance and the pool's available liquidity.
    function getAvailableLiquidity() external view returns (uint256) {
        uint256 ourBalance = A_TOKEN.balanceOf(address(this));
        uint256 poolLiquidity = UNDERLYING_ASSET.balanceOf(address(A_TOKEN));
        return ourBalance < poolLiquidity ? ourBalance : poolLiquidity;
    }

    function _onlyVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }
}
