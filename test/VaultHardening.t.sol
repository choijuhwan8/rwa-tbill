// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {TBillToken} from "../src/TBillToken.sol";
import {Whitelist} from "../src/Whitelist.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Phase 6: tests for the hardening changes (pause, rate cap, input validation)
///         plus fuzz tests on the rounding / economic-attack surface.
contract VaultHardeningTest is Test {
    MockUSDC usdc;
    Whitelist whitelist;
    TBillToken token;
    Vault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        whitelist = new Whitelist();
        token = new TBillToken(address(whitelist));
        vault = new Vault(address(usdc), address(token));
        token.grantRole(token.VAULT_ROLE(), address(vault));
        usdc.grantRole(usdc.MINTER_ROLE(), address(vault));
        whitelist.addToWhitelist(alice);
        whitelist.addToWhitelist(bob);
        whitelist.addToWhitelist(attacker);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.faucet(amount);
        usdc.approve(address(vault), amount);
        uint256 before = token.balanceOf(who);
        vault.deposit(amount);
        shares = token.balanceOf(who) - before;
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------------

    function test_PauseBlocksDepositAndRedeem() public {
        _deposit(alice, 100 * ONE_USDC);
        vault.pause();

        vm.startPrank(alice);
        usdc.faucet(ONE_USDC);
        usdc.approve(address(vault), ONE_USDC);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(ONE_USDC);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.redeem(1e18);
        vm.stopPrank();
    }

    function test_UnpauseRestoresRedeem() public {
        uint256 shares = _deposit(alice, 100 * ONE_USDC);
        vault.pause();
        vault.unpause();
        vm.prank(alice);
        vault.redeem(shares);
        assertEq(usdc.balanceOf(alice), 100 * ONE_USDC);
    }

    function test_YieldKeepsAccruingWhilePaused() public {
        vault.setYieldRate(500);
        uint256 shares = _deposit(alice, 1_000 * ONE_USDC);
        vault.pause();
        skip(365 days);
        vault.unpause();
        vm.prank(alice);
        vault.redeem(shares);
        assertEq(usdc.balanceOf(alice), 1_050 * ONE_USDC);
    }

    function test_OnlyPauserCanPause() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.PAUSER_ROLE())
        );
        vm.prank(alice);
        vault.pause();
    }

    // ---------------------------------------------------------------------
    // Yield rate cap
    // ---------------------------------------------------------------------

    function test_RateAtCapAllowed() public {
        vault.setYieldRate(vault.MAX_YIELD_BPS());
        assertEq(vault.annualYieldRateBps(), 2_000);
    }

    function test_RateAboveCapReverts() public {
        uint256 cap = vault.MAX_YIELD_BPS();
        vm.expectRevert("rate too high");
        vault.setYieldRate(cap + 1);
    }

    // ---------------------------------------------------------------------
    // Constructor validation
    // ---------------------------------------------------------------------

    function test_VaultRejectsZeroAddresses() public {
        vm.expectRevert("zero address");
        new Vault(address(0), address(token));
        vm.expectRevert("zero address");
        new Vault(address(usdc), address(0));
    }

    function test_TokenRejectsZeroWhitelist() public {
        vm.expectRevert("zero whitelist");
        new TBillToken(address(0));
    }

    // ---------------------------------------------------------------------
    // Fuzz: rounding always favours the vault
    // ---------------------------------------------------------------------

    /// Deposit then immediately redeem never returns more than was put in, at any NAV.
    function testFuzz_RoundTripNeverProfits(uint256 seed, uint256 yieldUsdc, uint256 amount) public {
        seed = bound(seed, 1 * ONE_USDC, 1_000_000 * ONE_USDC);
        yieldUsdc = bound(yieldUsdc, 0, 1_000_000 * ONE_USDC);
        amount = bound(amount, 1, 1_000_000 * ONE_USDC);

        // Establish an arbitrary, non-round NAV.
        _deposit(alice, seed);
        if (yieldUsdc > 0) {
            usdc.faucet(yieldUsdc);
            usdc.approve(address(vault), yieldUsdc);
            vault.accrueYield(yieldUsdc);
        }

        vm.startPrank(bob);
        usdc.faucet(amount);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount) {
            uint256 shares = token.balanceOf(bob);
            // A dust deposit can mint shares worth < 1 base unit; redeeming those reverts
            // ("usdc rounded to zero") and the dust stays in the vault. Rounding against
            // the user is exactly the property under test, so only redeem when payable.
            if ((shares * vault.navPerToken()) / 1e30 > 0) vault.redeem(shares);
        } catch {
            // Deposit rounded to zero shares → reverted, bob keeps his USDC. Also fine.
        }
        vm.stopPrank();

        assertLe(usdc.balanceOf(bob), amount, "round trip extracted value");
    }

    /// Redeeming in many small pieces can't beat redeeming in one go.
    function testFuzz_SplitRedeemNoBetterThanWhole(uint256 amount, uint8 pieces) public {
        amount = bound(amount, 100 * ONE_USDC, 1_000_000 * ONE_USDC);
        pieces = uint8(bound(pieces, 2, 50));
        vault.setYieldRate(500);
        uint256 shares = _deposit(alice, amount);
        skip(123 days);

        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        vault.redeem(shares);
        uint256 whole = usdc.balanceOf(alice);
        vm.revertToState(snapshot);

        uint256 chunk = shares / pieces;
        vm.startPrank(alice);
        for (uint256 i = 0; i < pieces - 1; i++) {
            vault.redeem(chunk);
        }
        vault.redeem(token.balanceOf(alice));
        vm.stopPrank();

        assertLe(usdc.balanceOf(alice), whole);
    }

    // ---------------------------------------------------------------------
    // First-depositor / donation ("inflation") attack
    // ---------------------------------------------------------------------

    /// Classic ERC-4626 attack: be first in with 1 base unit, donate to inflate NAV, and
    /// capture the victim's rounding loss. The 6→18 decimal SCALE means the attacker's
    /// 1 base unit mints 1e12 share-units, so the victim's loss (≤ 1 share-unit of value)
    /// is at most (1 + donation) / 1e12 base units. The attack *can* net a few micro-USDC,
    /// but stealing $1 requires parking ~$1 trillion in the vault. See SECURITY.md (F-1).
    function testFuzz_DonationAttackBounded(uint256 donation, uint256 victimDeposit) public {
        donation = bound(donation, 1, 10_000_000 * ONE_USDC);
        victimDeposit = bound(victimDeposit, ONE_USDC, 1_000_000 * ONE_USDC);

        // Attacker: deposit 1 base unit, then donate directly (no shares minted for it).
        uint256 attackerShares = _deposit(attacker, 1);
        vm.startPrank(attacker);
        usdc.faucet(donation);
        usdc.transfer(address(vault), donation);
        vm.stopPrank();
        uint256 attackerCost = 1 + donation;

        // Victim deposits (may revert if their shares would round to zero — then they lose nothing).
        vm.startPrank(alice);
        usdc.faucet(victimDeposit);
        usdc.approve(address(vault), victimDeposit);
        try vault.deposit(victimDeposit) {} catch {}
        vm.stopPrank();

        // Attacker exits.
        vm.prank(attacker);
        vault.redeem(attackerShares);

        // Profit is bounded by one share-unit of value: (1 + donation) / 1e12, rounded up.
        uint256 maxProfit = attackerCost / 1e12 + 1;
        assertLe(usdc.balanceOf(attacker), attackerCost + maxProfit, "profit above rounding bound");
    }

    // ---------------------------------------------------------------------
    // Dust-supply griefing (found by the invariant fuzzer) — SECURITY.md F-2
    // ---------------------------------------------------------------------

    /// Without dead shares: drain supply to dust, inject yield, and ordinary deposits
    /// round to zero shares. The attacker owns the dust, so they get the donation back.
    function test_DustSupplyGriefsDepositsWithoutSeed() public {
        uint256 shares = _deposit(attacker, 100 * ONE_USDC);
        vm.startPrank(attacker);
        vault.redeem(shares - 1); // keep a single share-unit (1e-18 sgTBILL)
        usdc.faucet(1_000 * ONE_USDC);
        usdc.transfer(address(vault), 1_000 * ONE_USDC); // donation
        vm.stopPrank();

        // NAV is now ~$1e15 per whole share: any deposit under ~$1,000 mints 0 shares.
        vm.startPrank(alice);
        usdc.faucet(999 * ONE_USDC);
        usdc.approve(address(vault), 999 * ONE_USDC);
        vm.expectRevert("shares rounded to zero");
        vault.deposit(999 * ONE_USDC);
        vm.stopPrank();

        // ...and the grief is free: the attacker's 1 share-unit redeems the donation back.
        uint256 before = usdc.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeem(1);
        assertGe(usdc.balanceOf(attacker) - before, 1_000 * ONE_USDC);
    }

    /// With 1 whole share locked at a burn address (what script/Deploy.s.sol does), the same
    /// attack leaves deposits working and the victim's rounding loss is sub-micro-USDC.
    function test_DeadSharesNeutraliseDustGriefing() public {
        address dead = 0x000000000000000000000000000000000000dEaD;
        whitelist.addToWhitelist(dead);
        whitelist.addToWhitelist(address(this));
        _deposit(address(this), ONE_USDC);
        token.transfer(dead, token.balanceOf(address(this)));

        uint256 shares = _deposit(attacker, 100 * ONE_USDC);
        vm.startPrank(attacker);
        vault.redeem(shares); // attacker exits completely; supply floor is the dead share
        usdc.faucet(100 * ONE_USDC);
        usdc.transfer(address(vault), 100 * ONE_USDC); // donation now mostly gifts the dead share
        vm.stopPrank();

        uint256 aliceShares = _deposit(alice, 10 * ONE_USDC);
        assertGt(aliceShares, 0);
        vm.prank(alice);
        vault.redeem(aliceShares);
        assertGe(usdc.balanceOf(alice), 10 * ONE_USDC - 1); // at most 1 base unit of rounding
    }
}
