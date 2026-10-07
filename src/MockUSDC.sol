// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MockUSDC
/// @notice A mock USDC token for testing purposes.

contract MockUSDC is ERC20, AccessControl {
    /// @notice Held by contracts allowed to mint to an arbitrary address (e.g. the Vault,
    ///         which mints simulated T-bill interest into itself).
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor() ERC20("Mock USDC", "mUSDC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Open faucet: anyone can mint play money to themselves.
    /// @dev Deliberately unrestricted — this is a testnet asset. Note it can only ever
    ///      credit the caller, so it cannot be used to inflate the vault's balance.
    function faucet(uint256 amount) public {
        _mint(msg.sender, amount);
    }

    /// @notice Mint to an arbitrary address. Gated, unlike `faucet`.
    /// @dev Restricted because minting *into the vault* raises navPerToken() for every
    ///      holder — that has to be a privileged action, not something any caller can do.
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}
