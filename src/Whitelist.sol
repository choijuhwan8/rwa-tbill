// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Whitelist is AccessControl {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    mapping(address => bool) public isWhitelisted;

    event AddressWhitelisted(address indexed account);
    event AddressRemoved(address indexed account);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
    }

    function addToWhitelist(address account) external onlyRole(COMPLIANCE_ROLE) {
        require(!isWhitelisted[account], "Address is already whitelisted");
        isWhitelisted[account] = true;
        emit AddressWhitelisted(account);
    }

    function removeFromWhitelist(address account) external onlyRole(COMPLIANCE_ROLE) {
        require(isWhitelisted[account], "Address is not whitelisted");
        isWhitelisted[account] = false;
        emit AddressRemoved(account);
    }
}
