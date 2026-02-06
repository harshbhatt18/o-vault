// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IComplianceModule} from "../IComplianceModule.sol";

/// @title KYCModule
/// @notice Allowlist-based KYC verification module
/// @dev Integrates with off-chain KYC providers via authorized attesters
contract KYCModule is IComplianceModule, Ownable2Step {
    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant MODULE_ID = keccak256("KYC_MODULE_V1");

    bytes32 public constant REASON_NOT_VERIFIED = keccak256("KYC_NOT_VERIFIED");
    bytes32 public constant REASON_EXPIRED = keccak256("KYC_EXPIRED");
    bytes32 public constant REASON_REVOKED = keccak256("KYC_REVOKED");
    bytes32 public constant REASON_INSUFFICIENT_TIER = keccak256("KYC_INSUFFICIENT_TIER");

    // ═══════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════

    enum KYCStatus {
        NONE, // Never verified
        PENDING, // Verification in progress
        VERIFIED, // Active and verified
        EXPIRED, // Was verified, now expired
        REVOKED // Manually revoked
    }

    struct KYCRecord {
        KYCStatus status;
        uint64 verifiedAt;
        uint64 expiresAt;
        bytes32 providerRef; // Reference to off-chain provider record
        uint8 tier; // KYC tier (1=basic, 2=enhanced, 3=institutional)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error NotAttester();
    error ZeroAddress();
    error ArrayLengthMismatch();

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event KYCStatusUpdated(address indexed user, KYCStatus status, uint8 tier, bytes32 providerRef);
    event AttesterUpdated(address indexed attester, bool authorized);
    event VaultMinTierUpdated(address indexed vault, uint8 minTier);
    event DefaultValidityUpdated(uint64 newValidity);

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice KYC records per user
    mapping(address => KYCRecord) public kycRecords;

    /// @notice Authorized attesters (can set KYC status)
    mapping(address => bool) public attesters;

    /// @notice Per-vault minimum KYC tier required (0 = no KYC required)
    mapping(address => uint8) public vaultMinTier;

    /// @notice Default KYC validity period
    uint64 public defaultValidityPeriod = 365 days;

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyAttester() {
        if (!attesters[msg.sender]) revert NotAttester();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address owner_) Ownable(owner_) {}

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set attester authorization
    function setAttester(address attester, bool authorized) external onlyOwner {
        if (attester == address(0)) revert ZeroAddress();
        attesters[attester] = authorized;
        emit AttesterUpdated(attester, authorized);
    }

    /// @notice Set minimum KYC tier for a vault
    function setVaultMinTier(address vault, uint8 minTier) external onlyOwner {
        vaultMinTier[vault] = minTier;
        emit VaultMinTierUpdated(vault, minTier);
    }

    /// @notice Set default validity period for new attestations
    function setDefaultValidityPeriod(uint64 period) external onlyOwner {
        defaultValidityPeriod = period;
        emit DefaultValidityUpdated(period);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ATTESTATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Attest KYC status for a user
    /// @param user User address to attest
    /// @param tier KYC tier (1=basic, 2=enhanced, 3=institutional)
    /// @param validityPeriod How long this attestation is valid
    /// @param providerRef Reference to off-chain provider record
    function attestKYC(address user, uint8 tier, uint64 validityPeriod, bytes32 providerRef) external onlyAttester {
        if (user == address(0)) revert ZeroAddress();

        kycRecords[user] = KYCRecord({
            status: KYCStatus.VERIFIED,
            verifiedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + validityPeriod,
            providerRef: providerRef,
            tier: tier
        });

        emit KYCStatusUpdated(user, KYCStatus.VERIFIED, tier, providerRef);
    }

    /// @notice Batch attestation with default validity
    function batchAttestKYC(address[] calldata users, uint8[] calldata tiers, bytes32[] calldata providerRefs)
        external
        onlyAttester
    {
        if (users.length != tiers.length || tiers.length != providerRefs.length) {
            revert ArrayLengthMismatch();
        }

        uint64 expiresAt = uint64(block.timestamp) + defaultValidityPeriod;

        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) continue;

            kycRecords[users[i]] = KYCRecord({
                status: KYCStatus.VERIFIED,
                verifiedAt: uint64(block.timestamp),
                expiresAt: expiresAt,
                providerRef: providerRefs[i],
                tier: tiers[i]
            });

            emit KYCStatusUpdated(users[i], KYCStatus.VERIFIED, tiers[i], providerRefs[i]);
        }
    }

    /// @notice Revoke KYC status
    function revokeKYC(address user) external onlyAttester {
        kycRecords[user].status = KYCStatus.REVOKED;
        emit KYCStatusUpdated(user, KYCStatus.REVOKED, 0, bytes32(0));
    }

    /// @notice Batch revoke KYC
    function batchRevokeKYC(address[] calldata users) external onlyAttester {
        for (uint256 i = 0; i < users.length; i++) {
            kycRecords[users[i]].status = KYCStatus.REVOKED;
            emit KYCStatusUpdated(users[i], KYCStatus.REVOKED, 0, bytes32(0));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMPLIANCE INTERFACE
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IComplianceModule
    function canDeposit(address vault, address user, uint256)
        external
        view
        override
        returns (bool allowed, bytes32 reason)
    {
        return _checkKYC(vault, user);
    }

    /// @inheritdoc IComplianceModule
    function canWithdraw(address, address, uint256) external pure override returns (bool allowed, bytes32 reason) {
        // Always allow withdrawals - users should be able to exit
        return (true, bytes32(0));
    }

    /// @inheritdoc IComplianceModule
    function canTransfer(address vault, address, address to, uint256)
        external
        view
        override
        returns (bool allowed, bytes32 reason)
    {
        // Recipient must be KYC'd
        return _checkKYC(vault, to);
    }

    /// @inheritdoc IComplianceModule
    function moduleId() external pure override returns (bytes32) {
        return MODULE_ID;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Check if a user's KYC is currently valid
    function isKYCValid(address user) external view returns (bool) {
        KYCRecord memory record = kycRecords[user];
        return record.status == KYCStatus.VERIFIED && block.timestamp <= record.expiresAt;
    }

    /// @notice Get full KYC record for a user
    function getKYCRecord(address user) external view returns (KYCRecord memory) {
        return kycRecords[user];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    function _checkKYC(address vault, address user) internal view returns (bool, bytes32) {
        uint8 minTier = vaultMinTier[vault];

        // If vault has no KYC requirement, allow everyone
        if (minTier == 0) {
            return (true, bytes32(0));
        }

        KYCRecord memory record = kycRecords[user];

        if (record.status == KYCStatus.NONE || record.status == KYCStatus.PENDING) {
            return (false, REASON_NOT_VERIFIED);
        }

        if (record.status == KYCStatus.REVOKED) {
            return (false, REASON_REVOKED);
        }

        if (record.status == KYCStatus.EXPIRED || block.timestamp > record.expiresAt) {
            return (false, REASON_EXPIRED);
        }

        if (record.tier < minTier) {
            return (false, REASON_INSUFFICIENT_TIER);
        }

        return (true, bytes32(0));
    }
}
