// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IComplianceModule} from "../IComplianceModule.sol";

/// @title AccreditedInvestorModule
/// @notice Enforces accredited investor requirements (SEC Reg D style)
/// @dev Tracks investor type, minimum investments, and investor caps per vault
contract AccreditedInvestorModule is IComplianceModule, Ownable2Step {
    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant MODULE_ID = keccak256("ACCREDITED_INVESTOR_V1");

    bytes32 public constant REASON_NOT_ACCREDITED = keccak256("NOT_ACCREDITED");
    bytes32 public constant REASON_BELOW_MINIMUM = keccak256("BELOW_MINIMUM_INVESTMENT");
    bytes32 public constant REASON_ABOVE_MAXIMUM = keccak256("ABOVE_MAXIMUM_INVESTMENT");
    bytes32 public constant REASON_VAULT_FULL = keccak256("VAULT_INVESTOR_CAP_REACHED");

    // ═══════════════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════════════

    enum InvestorType {
        NONE,
        RETAIL, // Non-accredited (may have restrictions)
        ACCREDITED, // Accredited individual ($1M+ net worth or $200k+ income)
        QUALIFIED, // Qualified purchaser ($5M+ investments)
        INSTITUTIONAL // Institutional investor
    }

    struct VaultRequirements {
        InvestorType minInvestorType; // Minimum investor type required
        uint256 minInvestment; // Minimum per deposit (0 = none)
        uint256 maxInvestment; // Maximum total position (0 = unlimited)
        uint256 maxInvestorCount; // Cap on number of investors (0 = unlimited)
        bool requireAccredited; // If true, retail investors blocked
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

    event InvestorTypeSet(address indexed user, InvestorType investorType);
    event VaultRequirementsSet(address indexed vault, VaultRequirements requirements);
    event AttesterUpdated(address indexed attester, bool authorized);
    event InvestmentRecorded(address indexed vault, address indexed user, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Investor accreditation status
    mapping(address => InvestorType) public investorType;

    /// @notice Per-vault requirements
    mapping(address => VaultRequirements) public vaultRequirements;

    /// @notice Per-vault investor count
    mapping(address => uint256) public vaultInvestorCount;

    /// @notice Track if user has invested in vault
    mapping(address => mapping(address => bool)) public hasInvested;

    /// @notice Total investment per user per vault
    mapping(address => mapping(address => uint256)) public userVaultInvestment;

    /// @notice Authorized attesters
    mapping(address => bool) public attesters;

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

    function setAttester(address attester, bool authorized) external onlyOwner {
        if (attester == address(0)) revert ZeroAddress();
        attesters[attester] = authorized;
        emit AttesterUpdated(attester, authorized);
    }

    function setVaultRequirements(address vault, VaultRequirements calldata req) external onlyOwner {
        vaultRequirements[vault] = req;
        emit VaultRequirementsSet(vault, req);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ATTESTATION
    // ═══════════════════════════════════════════════════════════════════════

    function attestInvestorType(address user, InvestorType iType) external onlyAttester {
        if (user == address(0)) revert ZeroAddress();
        investorType[user] = iType;
        emit InvestorTypeSet(user, iType);
    }

    function batchAttestInvestors(address[] calldata users, InvestorType[] calldata types) external onlyAttester {
        if (users.length != types.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) continue;
            investorType[users[i]] = types[i];
            emit InvestorTypeSet(users[i], types[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // HOOKS (Called by vault after successful deposit)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Record a deposit (called by vault post-deposit hook)
    /// @dev This tracks investor counts and total investments
    function recordDeposit(address vault, address user, uint256 amount) external {
        // Note: In production, add access control so only vaults can call this
        if (!hasInvested[vault][user]) {
            hasInvested[vault][user] = true;
            vaultInvestorCount[vault]++;
        }
        userVaultInvestment[vault][user] += amount;
        emit InvestmentRecorded(vault, user, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMPLIANCE INTERFACE
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IComplianceModule
    function canDeposit(address vault, address user, uint256 amount)
        external
        view
        override
        returns (bool allowed, bytes32 reason)
    {
        VaultRequirements memory req = vaultRequirements[vault];

        // If no requirements set, allow all
        if (req.minInvestorType == InvestorType.NONE && !req.requireAccredited) {
            return (true, bytes32(0));
        }

        InvestorType userType = investorType[user];

        // Check investor type requirement
        if (userType < req.minInvestorType) {
            return (false, REASON_NOT_ACCREDITED);
        }

        // Check accreditation requirement
        if (req.requireAccredited && userType == InvestorType.RETAIL) {
            return (false, REASON_NOT_ACCREDITED);
        }

        // Check minimum investment
        if (req.minInvestment > 0 && amount < req.minInvestment) {
            return (false, REASON_BELOW_MINIMUM);
        }

        // Check maximum investment
        if (req.maxInvestment > 0) {
            uint256 newTotal = userVaultInvestment[vault][user] + amount;
            if (newTotal > req.maxInvestment) {
                return (false, REASON_ABOVE_MAXIMUM);
            }
        }

        // Check investor count cap (for new investors only)
        if (req.maxInvestorCount > 0 && !hasInvested[vault][user]) {
            if (vaultInvestorCount[vault] >= req.maxInvestorCount) {
                return (false, REASON_VAULT_FULL);
            }
        }

        return (true, bytes32(0));
    }

    /// @inheritdoc IComplianceModule
    function canWithdraw(address, address, uint256) external pure override returns (bool, bytes32) {
        return (true, bytes32(0)); // Always allow exit
    }

    /// @inheritdoc IComplianceModule
    function canTransfer(address vault, address, address to, uint256 amount)
        external
        view
        override
        returns (bool, bytes32)
    {
        // Recipient must meet requirements
        return this.canDeposit(vault, to, amount);
    }

    /// @inheritdoc IComplianceModule
    function moduleId() external pure override returns (bytes32) {
        return MODULE_ID;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════

    function getInvestorType(address user) external view returns (InvestorType) {
        return investorType[user];
    }

    function getVaultRequirements(address vault) external view returns (VaultRequirements memory) {
        return vaultRequirements[vault];
    }

    function getUserInvestment(address vault, address user) external view returns (uint256) {
        return userVaultInvestment[vault][user];
    }
}
