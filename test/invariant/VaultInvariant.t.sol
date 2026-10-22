// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {TBillToken} from "../../src/TBillToken.sol";
import {Whitelist} from "../../src/Whitelist.sol";

/// @notice Random sequences of user + admin actions. The fuzzer calls these with arbitrary
///         inputs; each action bounds its inputs so it represents a *valid* operation.
contract VaultHandler is Test {
    Vault public vault;
    MockUSDC public usdc;
    TBillToken public token;
    address public admin;

    address[] public actors;

    // Ghost state, checked by the invariants.
    bool public navDecreased;
    uint256 public calls;

    constructor(Vault _vault, MockUSDC _usdc, TBillToken _token, address _admin, address[] memory _actors) {
        vault = _vault;
        usdc = _usdc;
        token = _token;
        admin = _admin;
        actors = _actors;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// Records whether this action lowered NAV. Only meaningful while shares exist: when
    /// supply hits zero navPerToken() resets to the 1.00 sentinel by definition.
    modifier trackNav() {
        uint256 supplyBefore = token.totalSupply();
        uint256 navBefore = vault.navPerToken();
        _;
        calls++;
        if (supplyBefore > 0 && token.totalSupply() > 0 && vault.navPerToken() < navBefore) {
            navDecreased = true;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint256 amount) external trackNav {
        address a = _actor(actorSeed);
        amount = bound(amount, 1e6, 10_000_000e6);
        vm.startPrank(a);
        usdc.faucet(amount);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 fractionBps) external trackNav {
        address a = _actor(actorSeed);
        uint256 bal = token.balanceOf(a);
        uint256 shares = (bal * bound(fractionBps, 1, 10_000)) / 10_000;
        // Skip dust that would round to 0 USDC (the vault correctly rejects it).
        if (shares == 0 || (shares * vault.navPerToken()) / 1e30 == 0) return;
        vm.prank(a);
        vault.redeem(shares);
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external trackNav {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function warp(uint256 secs) external trackNav {
        skip(bound(secs, 1, 400 days));
    }

    function setRate(uint256 bps) external trackNav {
        bps = bound(bps, 0, vault.MAX_YIELD_BPS());
        vm.prank(admin);
        vault.setYieldRate(bps);
    }

    function accrueYield(uint256 amount) external trackNav {
        amount = bound(amount, 1, 100_000e6);
        vm.startPrank(admin);
        usdc.faucet(amount);
        usdc.approve(address(vault), amount);
        vault.accrueYield(amount);
        vm.stopPrank();
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// (Every handler action is a valid operation, so any revert — e.g. a deposit rounding to
///  zero shares — is itself a bug. This is how the dust-supply griefing, F-2, was found.)
contract VaultInvariantTest is Test {
    Vault vault;
    MockUSDC usdc;
    TBillToken token;
    Whitelist whitelist;
    VaultHandler handler;

    function setUp() public {
        usdc = new MockUSDC();
        whitelist = new Whitelist();
        token = new TBillToken(address(whitelist));
        vault = new Vault(address(usdc), address(token));
        token.grantRole(token.VAULT_ROLE(), address(vault));
        usdc.grantRole(usdc.MINTER_ROLE(), address(vault));

        address[] memory actors = new address[](4);
        for (uint256 i = 0; i < actors.length; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            whitelist.addToWhitelist(actors[i]);
        }

        // Mirror script/Deploy.s.sol: 1 share locked at a burn address keeps supply >= 1e18.
        address dead = 0x000000000000000000000000000000000000dEaD;
        whitelist.addToWhitelist(dead);
        whitelist.addToWhitelist(address(this));
        usdc.faucet(1e6);
        usdc.approve(address(vault), 1e6);
        vault.deposit(1e6);
        token.transfer(dead, 1e18);

        handler = new VaultHandler(vault, usdc, token, address(this), actors);
        targetContract(address(handler));
    }

    /// Shares only ever live with whitelisted actors (+ the dead seed), so they sum to supply.
    function invariant_SupplyEqualsSumOfBalances() public view {
        uint256 sum = token.balanceOf(0x000000000000000000000000000000000000dEaD);
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// Solvency: if every holder redeemed right now at the settled NAV, the vault could pay.
    function invariant_VaultIsSolvent() public view {
        uint256 nav = vault.navPerToken();
        uint256 owed = (token.balanceOf(0x000000000000000000000000000000000000dEaD) * nav) / 1e30;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            owed += (token.balanceOf(handler.actors(i)) * nav) / 1e30;
        }
        assertLe(owed, vault.totalAssets());
    }

    /// No deposit, redeem, transfer or accrual can lower NAV for existing holders: every
    /// rounding step rounds in the vault's favour, and yield is never negative.
    function invariant_NavNeverDecreases() public view {
        assertFalse(handler.navDecreased());
    }

    /// The rate can never exceed the hard cap, whatever sequence of admin calls happened.
    function invariant_RateWithinCap() public view {
        assertLe(vault.annualYieldRateBps(), vault.MAX_YIELD_BPS());
    }
}
