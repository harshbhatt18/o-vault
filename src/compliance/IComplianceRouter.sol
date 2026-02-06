// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IComplianceModule} from "./IComplianceModule.sol";

/// @title IComplianceRouter
/// @notice Interface for compliance router that chains multiple modules
interface IComplianceRouter {
    /// @notice Check if deposit is allowed (reverts if not)
    function checkDeposit(address vault, address user, uint256 amount) external view;

    /// @notice Check if withdrawal is allowed (reverts if not)
    function checkWithdraw(address vault, address user, uint256 amount) external view;

    /// @notice Check if transfer is allowed (reverts if not)
    function checkTransfer(address vault, address from, address to, uint256 amount) external view;

    /// @notice View function - check deposit without reverting
    function isDepositAllowed(address vault, address user, uint256 amount)
        external
        view
        returns (bool allowed, bytes32 failedModule, bytes32 reason);

    /// @notice View function - check withdrawal without reverting
    function isWithdrawAllowed(address vault, address user, uint256 amount)
        external
        view
        returns (bool allowed, bytes32 failedModule, bytes32 reason);

    /// @notice View function - check transfer without reverting
    function isTransferAllowed(address vault, address from, address to, uint256 amount)
        external
        view
        returns (bool allowed, bytes32 failedModule, bytes32 reason);

    /// @notice Get all active modules
    function getModules() external view returns (IComplianceModule[] memory);
}
