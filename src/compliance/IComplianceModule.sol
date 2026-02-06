// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IComplianceModule
/// @notice Interface for pluggable compliance modules
/// @dev Modules check whether deposit/withdraw/transfer actions are allowed
interface IComplianceModule {
    /// @notice Check if a deposit is allowed
    /// @param vault The vault address
    /// @param user The depositor address
    /// @param amount Amount being deposited
    /// @return allowed True if deposit is allowed
    /// @return reason Reason code if not allowed (bytes32(0) if allowed)
    function canDeposit(address vault, address user, uint256 amount)
        external
        view
        returns (bool allowed, bytes32 reason);

    /// @notice Check if a withdrawal is allowed
    /// @param vault The vault address
    /// @param user The withdrawer address
    /// @param amount Amount being withdrawn
    /// @return allowed True if withdrawal is allowed
    /// @return reason Reason code if not allowed
    function canWithdraw(address vault, address user, uint256 amount)
        external
        view
        returns (bool allowed, bytes32 reason);

    /// @notice Check if a share transfer is allowed
    /// @param vault The vault address
    /// @param from Sender address
    /// @param to Recipient address
    /// @param amount Amount being transferred
    /// @return allowed True if transfer is allowed
    /// @return reason Reason code if not allowed
    function canTransfer(address vault, address from, address to, uint256 amount)
        external
        view
        returns (bool allowed, bytes32 reason);

    /// @notice Unique identifier for this module
    /// @return moduleId The module's identifier hash
    function moduleId() external pure returns (bytes32);
}
