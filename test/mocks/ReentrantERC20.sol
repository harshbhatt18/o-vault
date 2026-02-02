// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ReentrantERC20
/// @notice Malicious ERC-20 that attempts reentrancy on transfer.
///         Used to verify that ReentrancyGuard protects claimWithdrawal.
contract ReentrantERC20 is ERC20 {
    address public target;
    bytes public attackPayload;
    bool public attackEnabled;

    constructor() ERC20("Reentrant Token", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAttack(address _target, bytes calldata _payload) external {
        target = _target;
        attackPayload = _payload;
        attackEnabled = true;
    }

    function disableAttack() external {
        attackEnabled = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        _tryReenter();
        return result;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        _tryReenter();
        return result;
    }

    function _tryReenter() internal {
        if (attackEnabled && target != address(0) && attackPayload.length > 0) {
            attackEnabled = false; // prevent infinite loop
            (bool success,) = target.call(attackPayload);
            // Swallow result — we just want to test that reentrancy is blocked
            success;
        }
    }
}
