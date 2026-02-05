// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StreamVault} from "../../src/StreamVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title StreamVaultHarness
/// @notice Harness contract exposing internal state for Certora verification.
/// @dev Inherits StreamVault and adds view functions for CVL specs.
contract StreamVaultHarness is StreamVault {
    constructor() StreamVault() {}

    // ═══════════════════════════════════════════════════════════════════════════
    // Getters for internal state
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Get number of yield sources
    function getYieldSourcesLength() external view returns (uint256) {
        return yieldSources.length;
    }

    /// @notice Get yield source at index
    function getYieldSource(uint256 index) external view returns (address) {
        return address(yieldSources[index]);
    }

    /// @notice Get epoch status
    function getEpochStatus(uint256 epochId) external view returns (StreamVault.EpochStatus) {
        return epochs[epochId].status;
    }

    /// @notice Get epoch total shares burned
    function getEpochTotalSharesBurned(uint256 epochId) external view returns (uint256) {
        return epochs[epochId].totalSharesBurned;
    }

    /// @notice Get epoch total assets owed
    function getEpochTotalAssetsOwed(uint256 epochId) external view returns (uint256) {
        return epochs[epochId].totalAssetsOwed;
    }

    /// @notice Get epoch total assets claimed
    function getEpochTotalAssetsClaimed(uint256 epochId) external view returns (uint256) {
        return epochs[epochId].totalAssetsClaimed;
    }

    /// @notice Get user's withdraw request shares for an epoch
    function getUserWithdrawShares(uint256 epochId, address user) external view returns (uint256) {
        return withdrawRequests[epochId][user].shares;
    }

    /// @notice Get the underlying asset address
    function getAsset() external view returns (address) {
        return asset();
    }

    /// @notice Get vault's asset balance (idle funds)
    function getIdleBalance() external view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Check if an address has a role (wraps external hasRole)
    function hasRoleView(bytes32 role, address account) external view returns (bool) {
        // Call the external hasRole function via this contract
        return this.hasRole(role, account);
    }

    /// @notice Get the current block timestamp for spec comparisons
    function getBlockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }
}
