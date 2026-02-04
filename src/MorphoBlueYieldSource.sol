// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IYieldSource} from "./IYieldSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ═══════════════════════════════════════════════════════════════════════════
// Morpho Blue Types (minimal — only what we need)
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Parameters that identify a Morpho Blue market.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Minimal interface for Morpho Blue core contract.
/// @dev Full interface: https://github.com/morpho-org/morpho-blue/blob/main/src/interfaces/IMorpho.sol
interface IMorphoBlue {
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function createMarket(MarketParams memory marketParams) external;

    /// @dev Auto-generated getter for `mapping(bytes32 => mapping(address => Position)) public position`.
    ///      Returns (supplyShares, borrowShares, collateral).
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);

    /// @dev Auto-generated getter for `mapping(bytes32 => Market) public market`.
    ///      Returns (totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee).
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
}

// ═══════════════════════════════════════════════════════════════════════════

/// @title MorphoBlueYieldSource
/// @notice Yield source adapter for Morpho Blue (direct market supply).
///         Supplies underlying (e.g. USDC) directly to a Morpho Blue lending market
///         and tracks balance via supply share appreciation.
/// @dev This contract holds its own supply position on Morpho Blue. Only the authorized vault can interact.
///      Market ID is precomputed as keccak256(abi.encode(marketParams)) per Morpho Blue spec.
contract MorphoBlueYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    /// @dev Virtual amounts used by Morpho Blue for share price manipulation resistance.
    ///      See: https://github.com/morpho-org/morpho-blue/blob/main/src/libraries/SharesMathLib.sol
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    IMorphoBlue public immutable MORPHO;
    IERC20 public immutable UNDERLYING_ASSET;
    address public immutable VAULT;

    // Market identification — stored as individual immutables for gas efficiency
    // (structs cannot be immutable in Solidity)
    address public immutable COLLATERAL_TOKEN;
    address public immutable ORACLE;
    address public immutable IRM_ADDRESS;
    uint256 public immutable LLTV;
    bytes32 public immutable MARKET_ID;

    error OnlyVault();
    error ZeroAddress();

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    /// @param _morpho Morpho Blue core contract address.
    /// @param _marketParams The market parameters identifying the lending market to supply to.
    /// @param _vault The StreamVault that owns this adapter.
    constructor(address _morpho, MarketParams memory _marketParams, address _vault) {
        if (_morpho == address(0) || _vault == address(0) || _marketParams.loanToken == address(0)) {
            revert ZeroAddress();
        }

        MORPHO = IMorphoBlue(_morpho);
        UNDERLYING_ASSET = IERC20(_marketParams.loanToken);
        VAULT = _vault;

        // Store market params as immutables
        COLLATERAL_TOKEN = _marketParams.collateralToken;
        ORACLE = _marketParams.oracle;
        IRM_ADDRESS = _marketParams.irm;
        LLTV = _marketParams.lltv;

        // Precompute market ID: keccak256(abi.encode(marketParams))
        MARKET_ID = keccak256(abi.encode(_marketParams));
    }

    /// @notice Pull underlying from the vault and supply to Morpho Blue market.
    function deposit(uint256 amount) external onlyVault {
        UNDERLYING_ASSET.safeTransferFrom(msg.sender, address(this), amount);
        UNDERLYING_ASSET.forceApprove(address(MORPHO), amount);
        MORPHO.supply(_marketParams(), amount, 0, address(this), "");
    }

    /// @notice Withdraw underlying from Morpho Blue market and send back to the vault.
    /// @dev Uses the actual amount returned by Morpho to handle rounding.
    function withdraw(uint256 amount) external onlyVault {
        (uint256 assetsWithdrawn,) = MORPHO.withdraw(_marketParams(), amount, 0, address(this), address(this));
        UNDERLYING_ASSET.safeTransfer(VAULT, assetsWithdrawn);
    }

    /// @notice Current balance: convert held supply shares to underlying assets.
    /// @dev Uses Morpho Blue's virtual share accounting for accurate conversion.
    ///      Formula: assets = shares * (totalSupplyAssets + 1) / (totalSupplyShares + 1e6)
    function balance() external view returns (uint256) {
        (uint256 supplyShares,,) = MORPHO.position(MARKET_ID, address(this));
        if (supplyShares == 0) return 0;

        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = MORPHO.market(MARKET_ID);

        // Morpho Blue share-to-asset conversion with virtual amounts (mulDivDown)
        return
            (supplyShares * (uint256(totalSupplyAssets) + VIRTUAL_ASSETS))
                / (uint256(totalSupplyShares) + VIRTUAL_SHARES);
    }

    /// @notice The underlying asset address.
    function asset() external view returns (address) {
        return address(UNDERLYING_ASSET);
    }

    // ─── CRE View Functions ─────────────────────────────────────────────

    /// @notice Returns Morpho Blue market utilization.
    /// @dev Utilization = totalBorrowAssets / totalSupplyAssets.
    ///      Returns in basis points (10000 = 100% utilization).
    function getMarketUtilization() external view returns (uint256 utilizationBps) {
        (uint128 totalSupplyAssets,, uint128 totalBorrowAssets,,,) = MORPHO.market(MARKET_ID);
        if (totalSupplyAssets == 0) return 0;
        utilizationBps = (uint256(totalBorrowAssets) * 10_000) / uint256(totalSupplyAssets);
    }

    /// @notice Returns available liquidity we could withdraw right now.
    /// @dev Minimum of our balance and the market's unborrowed liquidity.
    function getAvailableLiquidity() external view returns (uint256) {
        (uint256 supplyShares,,) = MORPHO.position(MARKET_ID, address(this));
        if (supplyShares == 0) return 0;

        (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets,,,) = MORPHO.market(MARKET_ID);

        // Our balance in assets
        uint256 ourBalance = (supplyShares * (uint256(totalSupplyAssets) + VIRTUAL_ASSETS))
            / (uint256(totalSupplyShares) + VIRTUAL_SHARES);

        // Market available (unborrowed) liquidity
        uint256 available = uint256(totalSupplyAssets) - uint256(totalBorrowAssets);

        return ourBalance < available ? ourBalance : available;
    }

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev Reconstruct MarketParams from stored immutables.
    function _marketParams() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(UNDERLYING_ASSET),
            collateralToken: COLLATERAL_TOKEN,
            oracle: ORACLE,
            irm: IRM_ADDRESS,
            lltv: LLTV
        });
    }

    function _onlyVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }
}
