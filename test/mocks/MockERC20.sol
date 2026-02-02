// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Mintable ERC-20 for testing. Supports MockYieldSource's IMintable interface.
contract MockERC20 is ERC20 {
    uint8 private immutable _DEC;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DEC = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DEC;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
