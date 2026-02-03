// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockERC4626Vault
/// @notice Minimal ERC-4626 vault for testnet use as a Morpho stand-in.
///         Wraps an underlying asset 1:1 with no yield generation.
///         MorphoYieldSource adapter treats this as a real MetaMorpho vault.
contract MockERC4626Vault is ERC4626 {
    constructor(IERC20 _asset) ERC4626(_asset) ERC20("Mock Morpho USDC Vault", "mmUSDC") {}
}
