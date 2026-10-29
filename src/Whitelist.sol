// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Whitelist is AccessControl {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    mapping(address => bool) public isWhitelisted;

    /// @notice Set when compliance removes an address. A revoked address can't use
    ///         self-service to get back in; only COMPLIANCE_ROLE can re-admit it.
    mapping(address => bool) public isRevoked;

    /// @notice Testnet demo mode: lets anyone "pass KYC" for themselves via selfWhitelist().
    ///         Stands in for an off-chain KYC provider so the dApp is usable without an
    ///         operator online. Off by default; COMPLIANCE_ROLE switches it on or off.
    bool public selfServiceEnabled;

    event AddressWhitelisted(address indexed account);
    event AddressRemoved(address indexed account);
    event SelfServiceSet(bool enabled);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
    }

    function addToWhitelist(address account) external onlyRole(COMPLIANCE_ROLE) {
        require(!isWhitelisted[account], "Address is already whitelisted");
        isWhitelisted[account] = true;
        isRevoked[account] = false; // explicit re-admission by compliance clears a revocation
        emit AddressWhitelisted(account);
    }

    function removeFromWhitelist(address account) external onlyRole(COMPLIANCE_ROLE) {
        require(isWhitelisted[account], "Address is not whitelisted");
        isWhitelisted[account] = false;
        isRevoked[account] = true;
        emit AddressRemoved(account);
    }

    /// @notice Demo KYC: whitelist the caller, if self-service is on and they weren't revoked.
    function selfWhitelist() external {
        require(selfServiceEnabled, "Self-service disabled");
        require(!isRevoked[msg.sender], "Address revoked by compliance");
        require(!isWhitelisted[msg.sender], "Address is already whitelisted");
        isWhitelisted[msg.sender] = true;
        emit AddressWhitelisted(msg.sender);
    }

    function setSelfService(bool enabled) external onlyRole(COMPLIANCE_ROLE) {
        selfServiceEnabled = enabled;
        emit SelfServiceSet(enabled);
    }
}
