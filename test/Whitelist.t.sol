// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Whitelist} from "../src/Whitelist.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract WhitelistTest is Test {
    Whitelist whitelist;
    address alice = makeAddr("alice");
    address officer = makeAddr("officer");

    event AddressWhitelisted(address indexed account);
    event AddressRemoved(address indexed account);

    function setUp() public {
        whitelist = new Whitelist();
    }

    function test_DeployerHoldsAdminAndCompliance() public view {
        assertTrue(whitelist.hasRole(whitelist.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(whitelist.hasRole(whitelist.COMPLIANCE_ROLE(), address(this)));
    }

    function test_AddEmitsAndSets() public {
        vm.expectEmit(true, false, false, false, address(whitelist));
        emit AddressWhitelisted(alice);
        whitelist.addToWhitelist(alice);
        assertTrue(whitelist.isWhitelisted(alice));
    }

    function test_RemoveEmitsAndClears() public {
        whitelist.addToWhitelist(alice);
        vm.expectEmit(true, false, false, false, address(whitelist));
        emit AddressRemoved(alice);
        whitelist.removeFromWhitelist(alice);
        assertFalse(whitelist.isWhitelisted(alice));
    }

    function test_AddTwiceReverts() public {
        whitelist.addToWhitelist(alice);
        vm.expectRevert("Address is already whitelisted");
        whitelist.addToWhitelist(alice);
    }

    function test_RemoveUnlistedReverts() public {
        vm.expectRevert("Address is not whitelisted");
        whitelist.removeFromWhitelist(alice);
    }

    function test_NonComplianceCannotAdd() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, whitelist.COMPLIANCE_ROLE()
            )
        );
        vm.prank(alice);
        whitelist.addToWhitelist(alice);
    }

    function test_NonComplianceCannotRemove() public {
        whitelist.addToWhitelist(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, whitelist.COMPLIANCE_ROLE()
            )
        );
        vm.prank(alice);
        whitelist.removeFromWhitelist(alice);
    }

    // Role separation: the admin can delegate compliance to a dedicated officer key.
    function test_AdminCanDelegateCompliance() public {
        whitelist.grantRole(whitelist.COMPLIANCE_ROLE(), officer);
        vm.prank(officer);
        whitelist.addToWhitelist(alice);
        assertTrue(whitelist.isWhitelisted(alice));
    }
}
