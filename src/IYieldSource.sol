// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IYieldSource {
    /// @notice Deposit assets into the yield source.
    /// @param amount The amount of the underlying asset to deposit.
    function deposit(uint256 amount) external;

    /// @notice Withdraw assets from the yield source.
    /// @param amount The amount of the underlying asset to withdraw.
    function withdraw(uint256 amount) external;

    /// @notice Returns the total balance (principal + accrued yield) held for the caller.
    function balance() external view returns (uint256);

    /// @notice Returns the address of the underlying asset (e.g. USDC).
    function asset() external view returns (address);
}
