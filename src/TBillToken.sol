//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Whitelist} from "./Whitelist.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract TBillToken is ERC20, AccessControl {
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    Whitelist public whitelist;

    error NotWhitelisted(address account);

    constructor(address whitelistAddress) ERC20("sgTBILL", "sgTBILL") {
        whitelist = Whitelist(whitelistAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address to, uint256 amount) public onlyRole(VAULT_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public onlyRole(VAULT_ROLE) {
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && !whitelist.isWhitelisted(from)) {
            revert NotWhitelisted(from);
        }
        if (to != address(0) && !whitelist.isWhitelisted(to)) {
            revert NotWhitelisted(to);
        }
        super._update(from, to, amount);
    }
}
