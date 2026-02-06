// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title VaultTimelockController
/// @notice External timelock controller for StreamVault operator actions.
/// @dev Transfer the vault's operator role to this contract, then schedule/execute
///      timelocked operations. Emergency actions bypass the timelock.
contract VaultTimelockController is Ownable2Step {
    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 7 days;

    // ─── Storage ─────────────────────────────────────────────────────────────

    address public vault;
    uint256 public delay;

    struct Operation {
        uint256 readyAt;
        bytes32 dataHash;
    }

    mapping(bytes32 => Operation) public operations;

    // ─── Events ──────────────────────────────────────────────────────────────

    event OperationScheduled(bytes32 indexed opId, address indexed target, bytes data, uint256 readyAt);
    event OperationExecuted(bytes32 indexed opId);
    event OperationCancelled(bytes32 indexed opId);
    event DelayUpdated(uint256 newDelay);
    event VaultUpdated(address newVault);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error InvalidDelay();
    error ZeroAddress();
    error OperationNotScheduled();
    error OperationNotReady();
    error OperationAlreadyScheduled();
    error DataMismatch();
    error ExecutionFailed();

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(address _vault, uint256 _delay, address _owner) Ownable(_owner) {
        if (_vault == address(0)) revert ZeroAddress();
        if (_delay < MIN_DELAY || _delay > MAX_DELAY) revert InvalidDelay();

        vault = _vault;
        delay = _delay;
    }

    // ─── Scheduling ──────────────────────────────────────────────────────────

    /// @notice Schedule an operation to be executed after the delay.
    /// @param data The calldata to execute on the vault.
    /// @return opId The operation ID.
    function schedule(bytes calldata data) external onlyOwner returns (bytes32 opId) {
        opId = keccak256(abi.encode(vault, data, block.timestamp));

        if (operations[opId].readyAt != 0) revert OperationAlreadyScheduled();

        uint256 readyAt = block.timestamp + delay;
        operations[opId] = Operation({readyAt: readyAt, dataHash: keccak256(data)});

        emit OperationScheduled(opId, vault, data, readyAt);
    }

    /// @notice Execute a scheduled operation.
    /// @param opId The operation ID.
    /// @param data The calldata (must match scheduled data).
    function execute(bytes32 opId, bytes calldata data) external onlyOwner {
        Operation storage op = operations[opId];
        if (op.readyAt == 0) revert OperationNotScheduled();
        if (block.timestamp < op.readyAt) revert OperationNotReady();
        if (keccak256(data) != op.dataHash) revert DataMismatch();

        delete operations[opId];
        emit OperationExecuted(opId);

        (bool success,) = vault.call(data);
        if (!success) revert ExecutionFailed();
    }

    /// @notice Cancel a scheduled operation.
    function cancel(bytes32 opId) external onlyOwner {
        if (operations[opId].readyAt == 0) revert OperationNotScheduled();
        delete operations[opId];
        emit OperationCancelled(opId);
    }

    // ─── Emergency Actions (No Timelock) ─────────────────────────────────────

    /// @notice Emergency pause - bypasses timelock.
    function emergencyPause() external onlyOwner {
        (bool success,) = vault.call(abi.encodeWithSignature("pause()"));
        if (!success) revert ExecutionFailed();
    }

    /// @notice Emergency unpause - bypasses timelock.
    function emergencyUnpause() external onlyOwner {
        (bool success,) = vault.call(abi.encodeWithSignature("unpause()"));
        if (!success) revert ExecutionFailed();
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Update the timelock delay.
    function setDelay(uint256 _delay) external onlyOwner {
        if (_delay < MIN_DELAY || _delay > MAX_DELAY) revert InvalidDelay();
        delay = _delay;
        emit DelayUpdated(_delay);
    }

    /// @notice Update the vault address.
    function setVault(address _vault) external onlyOwner {
        if (_vault == address(0)) revert ZeroAddress();
        vault = _vault;
        emit VaultUpdated(_vault);
    }

    // ─── View ────────────────────────────────────────────────────────────────

    /// @notice Get operation details.
    function getOperation(bytes32 opId) external view returns (uint256 readyAt, bytes32 dataHash) {
        Operation storage op = operations[opId];
        return (op.readyAt, op.dataHash);
    }

    /// @notice Check if an operation is ready for execution.
    function isOperationReady(bytes32 opId) external view returns (bool) {
        Operation storage op = operations[opId];
        return op.readyAt != 0 && block.timestamp >= op.readyAt;
    }
}
