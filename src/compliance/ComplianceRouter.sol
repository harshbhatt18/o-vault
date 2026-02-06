// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IComplianceModule} from "./IComplianceModule.sol";
import {IComplianceRouter} from "./IComplianceRouter.sol";

/// @title ComplianceRouter
/// @notice Routes compliance checks through multiple modules
/// @dev All modules must pass for an action to be allowed
contract ComplianceRouter is IComplianceRouter, Ownable2Step {
    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ComplianceCheckFailed(bytes32 moduleId, bytes32 reason);
    error ModuleAlreadyAdded(address module);
    error ModuleNotFound(address module);
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event ModuleAdded(address indexed module, bytes32 moduleId);
    event ModuleRemoved(address indexed module, bytes32 moduleId);
    event VaultModuleToggled(address indexed vault, address indexed module, bool disabled);

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Ordered list of compliance modules to check
    IComplianceModule[] internal _modules;

    /// @notice Quick lookup for module existence
    mapping(address => bool) public isModule;

    /// @notice Per-vault module overrides (vault can disable specific modules)
    mapping(address => mapping(address => bool)) public vaultModuleDisabled;

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address owner_) Ownable(owner_) {}

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Add a compliance module to the chain
    /// @param module The module contract address
    function addModule(address module) external onlyOwner {
        if (module == address(0)) revert ZeroAddress();
        if (isModule[module]) revert ModuleAlreadyAdded(module);

        _modules.push(IComplianceModule(module));
        isModule[module] = true;

        emit ModuleAdded(module, IComplianceModule(module).moduleId());
    }

    /// @notice Remove a compliance module from the chain
    /// @param module The module contract address to remove
    function removeModule(address module) external onlyOwner {
        if (!isModule[module]) revert ModuleNotFound(module);

        uint256 len = _modules.length;
        for (uint256 i = 0; i < len; i++) {
            if (address(_modules[i]) == module) {
                _modules[i] = _modules[len - 1];
                _modules.pop();
                break;
            }
        }

        isModule[module] = false;
        emit ModuleRemoved(module, IComplianceModule(module).moduleId());
    }

    /// @notice Toggle a module for a specific vault
    /// @param vault The vault address
    /// @param module The module address
    /// @param disabled Whether to disable the module for this vault
    function setVaultModuleDisabled(address vault, address module, bool disabled) external onlyOwner {
        vaultModuleDisabled[vault][module] = disabled;
        emit VaultModuleToggled(vault, module, disabled);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMPLIANCE CHECKS (REVERTING)
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IComplianceRouter
    function checkDeposit(address vault, address user, uint256 amount) external view override {
        uint256 len = _modules.length;

        for (uint256 i = 0; i < len; i++) {
            if (vaultModuleDisabled[vault][address(_modules[i])]) continue;

            (bool allowed, bytes32 reason) = _modules[i].canDeposit(vault, user, amount);
            if (!allowed) {
                revert ComplianceCheckFailed(_modules[i].moduleId(), reason);
            }
        }
    }

    /// @inheritdoc IComplianceRouter
    function checkWithdraw(address vault, address user, uint256 amount) external view override {
        uint256 len = _modules.length;

        for (uint256 i = 0; i < len; i++) {
            if (vaultModuleDisabled[vault][address(_modules[i])]) continue;

            (bool allowed, bytes32 reason) = _modules[i].canWithdraw(vault, user, amount);
            if (!allowed) {
                revert ComplianceCheckFailed(_modules[i].moduleId(), reason);
            }
        }
    }

    /// @inheritdoc IComplianceRouter
    function checkTransfer(address vault, address from, address to, uint256 amount) external view override {
        uint256 len = _modules.length;

        for (uint256 i = 0; i < len; i++) {
            if (vaultModuleDisabled[vault][address(_modules[i])]) continue;

            (bool allowed, bytes32 reason) = _modules[i].canTransfer(vault, from, to, amount);
            if (!allowed) {
                revert ComplianceCheckFailed(_modules[i].moduleId(), reason);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COMPLIANCE CHECKS (NON-REVERTING)
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IComplianceRouter
    function isDepositAllowed(address vault, address user, uint256 amount)
        external
        view
        override
        returns (bool allowed, bytes32 failedModule, bytes32 reason)
    {
        uint256 len = _modules.length;

        for (uint256 i = 0; i < len; i++) {
            if (vaultModuleDisabled[vault][address(_modules[i])]) continue;

            (bool ok, bytes32 r) = _modules[i].canDeposit(vault, user, amount);
            if (!ok) {
                return (false, _modules[i].moduleId(), r);
            }
        }

        return (true, bytes32(0), bytes32(0));
    }

    /// @inheritdoc IComplianceRouter
    function isWithdrawAllowed(address vault, address user, uint256 amount)
        external
        view
        override
        returns (bool allowed, bytes32 failedModule, bytes32 reason)
    {
        uint256 len = _modules.length;

        for (uint256 i = 0; i < len; i++) {
            if (vaultModuleDisabled[vault][address(_modules[i])]) continue;

            (bool ok, bytes32 r) = _modules[i].canWithdraw(vault, user, amount);
            if (!ok) {
                return (false, _modules[i].moduleId(), r);
            }
        }

        return (true, bytes32(0), bytes32(0));
    }

    /// @inheritdoc IComplianceRouter
    function isTransferAllowed(address vault, address from, address to, uint256 amount)
        external
        view
        override
        returns (bool allowed, bytes32 failedModule, bytes32 reason)
    {
        uint256 len = _modules.length;

        for (uint256 i = 0; i < len; i++) {
            if (vaultModuleDisabled[vault][address(_modules[i])]) continue;

            (bool ok, bytes32 r) = _modules[i].canTransfer(vault, from, to, amount);
            if (!ok) {
                return (false, _modules[i].moduleId(), r);
            }
        }

        return (true, bytes32(0), bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IComplianceRouter
    function getModules() external view override returns (IComplianceModule[] memory) {
        return _modules;
    }

    /// @notice Get module count
    function moduleCount() external view returns (uint256) {
        return _modules.length;
    }
}
