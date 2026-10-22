// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract DeployTest is Test {
    Deploy script;
    Deploy.Deployment d;

    address deployer;
    address alice = makeAddr("alice");

    function setUp() public {
        script = new Deploy();
        // Contracts created inside deploy() are created by the script contract, so it is
        // the one holding admin roles here (on a real broadcast it is the EOA).
        deployer = address(script);

        address[] memory extra = new address[](2);
        extra[0] = alice;
        extra[1] = alice; // duplicates must not revert
        d = script.deploy(deployer, 500, extra);
    }

    function test_WiresRoles() public view {
        assertTrue(d.token.hasRole(d.token.VAULT_ROLE(), address(d.vault)));
        assertTrue(d.usdc.hasRole(d.usdc.MINTER_ROLE(), address(d.vault)));
        assertEq(address(d.token.whitelist()), address(d.whitelist));
        assertEq(address(d.vault.usdc()), address(d.usdc));
        assertEq(address(d.vault.shareToken()), address(d.token));
    }

    function test_WhitelistsDeployerAndExtras() public view {
        assertTrue(d.whitelist.isWhitelisted(deployer));
        assertTrue(d.whitelist.isWhitelisted(alice));
    }

    function test_SeedSharesLockedAtDeadAddress() public view {
        assertEq(d.token.balanceOf(script.DEAD()), 1e18);
        assertEq(d.token.totalSupply(), 1e18);
        assertEq(d.token.balanceOf(deployer), 0);
        assertEq(d.vault.totalAssets(), script.SEED_USDC());
        assertEq(d.vault.navPerToken(), 1e18);
    }

    function test_SetsYieldRate() public view {
        assertEq(d.vault.annualYieldRateBps(), 500);
    }

    function test_EndToEndDepositAfterDeploy() public {
        vm.startPrank(alice);
        d.usdc.faucet(100e6);
        d.usdc.approve(address(d.vault), 100e6);
        d.vault.deposit(100e6);
        vm.stopPrank();
        assertEq(d.token.balanceOf(alice), 100e18);
    }
}
