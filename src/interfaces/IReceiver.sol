// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IReceiver
/// @notice Chainlink CRE (Compute Runtime Environment) consumer interface.
/// @dev Contracts implementing this interface can receive verified workflow reports
///      from the Chainlink KeystoneForwarder after DON consensus verification.
///      The Forwarder validates signatures from the DON before calling onReport().
interface IReceiver {
    /// @notice Called by the KeystoneForwarder after DON consensus verification.
    /// @dev The Forwarder has already verified that the DON reached consensus on this report.
    ///      Implementers should validate msg.sender == configured forwarder address.
    /// @param metadata Workflow identification data (workflow name, owner, report name).
    ///                 Can be used for routing or validation in multi-workflow scenarios.
    /// @param report ABI-encoded payload containing the workflow's output data.
    ///               The encoding format is defined by the workflow and must match
    ///               the consumer contract's expected decoding format.
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
