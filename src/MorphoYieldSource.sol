// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IYieldSource} from "./IYieldSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MorphoYieldSource
/// @notice Yield source adapter for MetaMorpho vaults (ERC-4626).
///         Deposits underlying into a MetaMorpho vault and tracks balance via share appreciation.
/// @dev This contract holds its own MetaMorpho vault shares. Only the authorized vault can interact.
contract MorphoYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable UNDERLYING_ASSET;
    IERC4626 public immutable MORPHO_VAULT;
    address public immutable VAULT;

    error OnlyVault();

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    /// @param _morphoVault The MetaMorpho ERC-4626 vault address.
    /// @param _vault The StreamVault that owns this adapter.
    constructor(address _morphoVault, address _vault) {
        MORPHO_VAULT = IERC4626(_morphoVault);
        UNDERLYING_ASSET = IERC20(IERC4626(_morphoVault).asset());
        VAULT = _vault;
    }

    /// @notice Pull underlying from the vault and deposit into MetaMorpho.
    function deposit(uint256 amount) external onlyVault {
        UNDERLYING_ASSET.safeTransferFrom(msg.sender, address(this), amount);
        UNDERLYING_ASSET.forceApprove(address(MORPHO_VAULT), amount);
        MORPHO_VAULT.deposit(amount, address(this));
    }

    /// @notice Withdraw underlying from MetaMorpho and send back to the vault.
    /// @dev Measures actual balance change to handle rounding in the Morpho vault.
    function withdraw(uint256 amount) external onlyVault {
        uint256 before = UNDERLYING_ASSET.balanceOf(address(this));
        MORPHO_VAULT.withdraw(amount, address(this), address(this));
        uint256 actual = UNDERLYING_ASSET.balanceOf(address(this)) - before;
        UNDERLYING_ASSET.safeTransfer(VAULT, actual);
    }

    /// @notice Current balance: convert held shares to underlying assets at current exchange rate.
    function balance() external view returns (uint256) {
        uint256 shares = MORPHO_VAULT.balanceOf(address(this));
        return MORPHO_VAULT.convertToAssets(shares);
    }

    /// @notice The underlying asset address.
    function asset() external view returns (address) {
        return address(UNDERLYING_ASSET);
    }

    function _onlyVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }
}
