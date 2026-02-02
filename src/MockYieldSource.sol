// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IYieldSource} from "./IYieldSource.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @title MockYieldSource
/// @notice Simulated lending protocol that accrues yield at a configurable rate per second.
///         Only the authorized vault can deposit/withdraw.
///         Requires a mintable ERC-20 so accrued yield is backed by real tokens.
contract MockYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable UNDERLYING_ASSET;
    address public immutable VAULT;
    uint256 public immutable RATE_PER_SECOND; // yield rate in basis points per second (e.g. 1 = 0.01% per second)

    uint256 public principal;
    uint256 public lastAccrualTimestamp;

    error OnlyVault();

    modifier onlyVault() {
        _onlyVault();
        _;
    }

    /// @param _asset The underlying ERC-20 token (must implement IMintable).
    /// @param _vault The authorized vault address.
    /// @param _ratePerSecond Yield rate in basis points per second.
    constructor(address _asset, address _vault, uint256 _ratePerSecond) {
        UNDERLYING_ASSET = IERC20(_asset);
        VAULT = _vault;
        RATE_PER_SECOND = _ratePerSecond;
        lastAccrualTimestamp = block.timestamp;
    }

    function deposit(uint256 amount) external onlyVault {
        _accrue();
        UNDERLYING_ASSET.safeTransferFrom(msg.sender, address(this), amount);
        principal += amount;
    }

    function withdraw(uint256 amount) external onlyVault {
        _accrue();
        if (amount > principal) amount = principal;
        principal -= amount;
        UNDERLYING_ASSET.safeTransfer(msg.sender, amount);
    }

    function balance() external view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        return principal + (principal * RATE_PER_SECOND * elapsed) / 1e6;
    }

    function asset() external view returns (address) {
        return address(UNDERLYING_ASSET);
    }

    function _accrue() internal {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed > 0) {
            uint256 yield_ = (principal * RATE_PER_SECOND * elapsed) / 1e6;
            if (yield_ > 0) {
                // Mint real tokens to back the accrued yield
                IMintable(address(UNDERLYING_ASSET)).mint(address(this), yield_);
                principal += yield_;
            }
            lastAccrualTimestamp = block.timestamp;
        }
    }

    function _onlyVault() internal view {
        if (msg.sender != VAULT) revert OnlyVault();
    }
}
