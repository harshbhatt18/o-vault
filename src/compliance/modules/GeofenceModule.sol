// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IComplianceModule} from "../IComplianceModule.sol";

/// @title GeofenceModule
/// @notice Geographic and sanctions-based restrictions
/// @dev Blocks users based on country codes and sanctions lists
contract GeofenceModule is IComplianceModule, Ownable2Step {
    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant MODULE_ID = keccak256("GEOFENCE_V1");

    bytes32 public constant REASON_BLOCKED_COUNTRY = keccak256("BLOCKED_COUNTRY");
    bytes32 public constant REASON_SANCTIONED = keccak256("SANCTIONED_ADDRESS");
    bytes32 public constant REASON_NOT_ATTESTED = keccak256("COUNTRY_NOT_ATTESTED");

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error NotAttester();
    error ZeroAddress();
    error ArrayLengthMismatch();

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event CountryAttested(address indexed user, bytes2 country);
    event GlobalCountryBlocked(bytes2 indexed country, bool blocked);
    event VaultCountryBlocked(address indexed vault, bytes2 indexed country, bool blocked);
    event AddressSanctioned(address indexed user, bool sanctioned);
    event AttesterUpdated(address indexed attester, bool authorized);
    event SanctionsOracleUpdated(address indexed oracle);

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice User's attested country (ISO 3166-1 alpha-2, e.g., "US", "GB")
    mapping(address => bytes2) public userCountry;

    /// @notice Whether a country attestation exists
    mapping(address => bool) public hasCountryAttestation;

    /// @notice Globally blocked countries (e.g., OFAC sanctioned)
    mapping(bytes2 => bool) public globalBlockedCountries;

    /// @notice Per-vault blocked countries
    mapping(address => mapping(bytes2 => bool)) public vaultBlockedCountries;

    /// @notice Sanctioned addresses (OFAC SDN list)
    mapping(address => bool) public sanctioned;

    /// @notice Authorized geo attesters
    mapping(address => bool) public geoAttesters;

    /// @notice Sanctions oracle address (e.g., Chainalysis)
    address public sanctionsOracle;

    /// @notice Whether vaults require country attestation (if false, unattested users allowed)
    mapping(address => bool) public vaultRequiresAttestation;

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyAttester() {
        if (!geoAttesters[msg.sender]) revert NotAttester();
        _;
    }

    modifier onlyOracleOrOwner() {
        if (msg.sender != sanctionsOracle && msg.sender != owner()) revert NotAttester();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address owner_) Ownable(owner_) {}

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════

    function setGeoAttester(address attester, bool authorized) external onlyOwner {
        if (attester == address(0)) revert ZeroAddress();
        geoAttesters[attester] = authorized;
        emit AttesterUpdated(attester, authorized);
    }

    function setSanctionsOracle(address oracle) external onlyOwner {
        sanctionsOracle = oracle;
        emit SanctionsOracleUpdated(oracle);
    }

    function setGlobalBlockedCountry(bytes2 country, bool blocked) external onlyOwner {
        globalBlockedCountries[country] = blocked;
        emit GlobalCountryBlocked(country, blocked);
    }

    function setVaultBlockedCountry(address vault, bytes2 country, bool blocked) external onlyOwner {
        vaultBlockedCountries[vault][country] = blocked;
        emit VaultCountryBlocked(vault, country, blocked);
    }

    function setVaultRequiresAttestation(address vault, bool required) external onlyOwner {
        vaultRequiresAttestation[vault] = required;
    }

    function setSanctioned(address user, bool isSanctioned) external onlyOracleOrOwner {
        sanctioned[user] = isSanctioned;
        emit AddressSanctioned(user, isSanctioned);
    }

    function batchSetSanctioned(address[] calldata users, bool isSanctioned) external onlyOracleOrOwner {
        for (uint256 i = 0; i < users.length; i++) {
            sanctioned[users[i]] = isSanctioned;
            emit AddressSanctioned(users[i], isSanctioned);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PRESETS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Apply common OFAC sanctioned countries
    function applyOFACPreset() external onlyOwner {
        globalBlockedCountries["KP"] = true; // North Korea
        globalBlockedCountries["IR"] = true; // Iran
        globalBlockedCountries["CU"] = true; // Cuba
        globalBlockedCountries["SY"] = true; // Syria

        emit GlobalCountryBlocked("KP", true);
        emit GlobalCountryBlocked("IR", true);
        emit GlobalCountryBlocked("CU", true);
        emit GlobalCountryBlocked("SY", true);
    }

    /// @notice Block US for a specific vault (unregistered securities)
    function blockUSForVault(address vault) external onlyOwner {
        vaultBlockedCountries[vault]["US"] = true;
        emit VaultCountryBlocked(vault, "US", true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ATTESTATION
    // ═══════════════════════════════════════════════════════════════════════

    function attestCountry(address user, bytes2 country) external onlyAttester {
        if (user == address(0)) revert ZeroAddress();
        userCountry[user] = country;
        hasCountryAttestation[user] = true;
        emit CountryAttested(user, country);
    }

    function batchAttestCountry(address[] calldata users, bytes2[] calldata countries) external onlyAttester {
        if (users.length != countries.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) continue;
            userCountry[users[i]] = countries[i];
            hasCountryAttestation[users[i]] = true;
            emit CountryAttested(users[i], countries[i]);
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
        return _checkGeofence(vault, user);
    }

    /// @inheritdoc IComplianceModule
    function canWithdraw(address, address user, uint256) external view override returns (bool allowed, bytes32 reason) {
        // Even for withdrawals, check sanctions (cannot release funds to sanctioned addresses)
        if (sanctioned[user]) {
            return (false, REASON_SANCTIONED);
        }
        return (true, bytes32(0));
    }

    /// @inheritdoc IComplianceModule
    function canTransfer(address vault, address from, address to, uint256)
        external
        view
        override
        returns (bool allowed, bytes32 reason)
    {
        // Check both parties for sanctions
        if (sanctioned[from] || sanctioned[to]) {
            return (false, REASON_SANCTIONED);
        }

        // Check recipient's country
        return _checkGeofence(vault, to);
    }

    /// @inheritdoc IComplianceModule
    function moduleId() external pure override returns (bytes32) {
        return MODULE_ID;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    function _checkGeofence(address vault, address user) internal view returns (bool, bytes32) {
        // Sanctions check first (highest priority)
        if (sanctioned[user]) {
            return (false, REASON_SANCTIONED);
        }

        // Check if vault requires attestation
        if (vaultRequiresAttestation[vault] && !hasCountryAttestation[user]) {
            return (false, REASON_NOT_ATTESTED);
        }

        // If user has no attestation and vault doesn't require it, allow
        if (!hasCountryAttestation[user]) {
            return (true, bytes32(0));
        }

        bytes2 country = userCountry[user];

        // Global blocks
        if (globalBlockedCountries[country]) {
            return (false, REASON_BLOCKED_COUNTRY);
        }

        // Vault-specific blocks
        if (vaultBlockedCountries[vault][country]) {
            return (false, REASON_BLOCKED_COUNTRY);
        }

        return (true, bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════

    function getUserCountry(address user) external view returns (bytes2) {
        return userCountry[user];
    }

    function isCountryBlocked(address vault, bytes2 country) external view returns (bool) {
        return globalBlockedCountries[country] || vaultBlockedCountries[vault][country];
    }

    function isSanctioned(address user) external view returns (bool) {
        return sanctioned[user];
    }
}
