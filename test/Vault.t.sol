// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {TBillToken} from "../src/TBillToken.sol";
import {Whitelist} from "../src/Whitelist.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract VaultTest is Test {
    MockUSDC public usdc;
    Whitelist public whitelist;
    TBillToken public token;
    Vault public vault;

    address admin = address(this); // deploys everything → holds all admin roles
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant ONE_USDC = 1e6; // 1 USDC (6 decimals)
    uint256 constant ONE_SHARE = 1e18; // 1 sgTBILL (18 decimals)

    function setUp() public {
        // Deploy the four contracts.
        usdc = new MockUSDC();
        whitelist = new Whitelist();
        token = new TBillToken(address(whitelist));
        vault = new Vault(address(usdc), address(token));

        // The vault must hold VAULT_ROLE on the token so it can mint/burn shares.
        token.grantRole(token.VAULT_ROLE(), address(vault));

        // Phase 4: the vault mints simulated interest into itself, so it needs MINTER_ROLE
        // on the asset token.
        usdc.grantRole(usdc.MINTER_ROLE(), address(vault));

        // Phase 2 gate: every address that will HOLD sgTBILL must be whitelisted.
        // That includes the users (they receive shares on deposit).
        whitelist.addToWhitelist(alice);
        whitelist.addToWhitelist(bob);

        // Give the users some USDC to deposit.
        vm.prank(alice);
        usdc.faucet(1_000 * ONE_USDC);
        vm.prank(bob);
        usdc.faucet(1_000 * ONE_USDC);
    }

    // Helper: alice approves + deposits `usdcAmount` in one go.
    function _deposit(address who, uint256 usdcAmount) internal {
        vm.startPrank(who);
        usdc.approve(address(vault), usdcAmount);
        vault.deposit(usdcAmount);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // NAV
    // ---------------------------------------------------------------------

    // Before any deposit, NAV is exactly 1.00 (1e18).
    function test_InitialNavIsOne() public view {
        assertEq(vault.navPerToken(), 1e18);
    }

    // ---------------------------------------------------------------------
    // Deposit
    // ---------------------------------------------------------------------

    // Deposit 100 USDC at NAV 1.00 → receive 100 whole shares (100e18).
    // This proves the 6dp -> 18dp scaling works.
    function test_DepositAtNavOne() public {
        _deposit(alice, 100 * ONE_USDC);

        assertEq(token.balanceOf(alice), 100 * ONE_SHARE); // 100 shares
        assertEq(usdc.balanceOf(address(vault)), 100 * ONE_USDC); // vault holds the USDC
        assertEq(vault.navPerToken(), 1e18); // NAV unchanged by a fair deposit
    }

    // Depositing without approving first must revert (the approve/transferFrom gate).
    function test_DepositWithoutApproveReverts() public {
        vm.prank(alice);
        vm.expectRevert(); // SafeERC20 reverts on the failed transferFrom (no allowance)
        vault.deposit(100 * ONE_USDC);
    }

    // Depositing zero reverts.
    function test_DepositZeroReverts() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100 * ONE_USDC);
        vm.expectRevert(bytes("zero deposit"));
        vault.deposit(0);
        vm.stopPrank();
    }

    // A non-whitelisted depositor can't receive shares (mint reverts in _update).
    function test_DepositByNonWhitelistedReverts() public {
        address carol = makeAddr("carol"); // never whitelisted
        vm.prank(carol);
        usdc.faucet(100 * ONE_USDC);

        vm.startPrank(carol);
        usdc.approve(address(vault), 100 * ONE_USDC);
        vm.expectRevert(abi.encodeWithSelector(TBillToken.NotWhitelisted.selector, carol));
        vault.deposit(100 * ONE_USDC);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Redeem
    // ---------------------------------------------------------------------

    // Deposit then immediately redeem everything → get the original USDC back.
    function test_DepositThenRedeemRoundTrip() public {
        uint256 before = usdc.balanceOf(alice);

        _deposit(alice, 100 * ONE_USDC);
        uint256 shares = token.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares);

        assertEq(token.balanceOf(alice), 0); // shares burned
        assertEq(usdc.balanceOf(alice), before); // full USDC returned (NAV 1.00, no rounding loss)
    }

    // ---------------------------------------------------------------------
    // Yield accrual & NAV drift
    // ---------------------------------------------------------------------

    // accrueYield by a non-admin reverts.
    function test_AccrueYieldNonAdminReverts() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10 * ONE_USDC);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.YIELD_ADMIN_ROLE()
            )
        );
        vault.accrueYield(10 * ONE_USDC);
        vm.stopPrank();
    }

    // After accrueYield, NAV rises, and a later depositor gets FEWER shares per USDC.
    function test_YieldRaisesNavAndLaterDepositorGetsFewerShares() public {
        // Alice deposits 100 USDC at NAV 1.00 → 100 shares.
        _deposit(alice, 100 * ONE_USDC);
        assertEq(vault.navPerToken(), 1e18);

        // Admin injects 10 USDC of "yield" (this test contract holds YIELD_ADMIN_ROLE).
        usdc.faucet(10 * ONE_USDC);
        usdc.approve(address(vault), 10 * ONE_USDC);
        vault.accrueYield(10 * ONE_USDC);

        // Vault now holds 110 USDC, still 100 shares → NAV = 1.10.
        assertEq(vault.navPerToken(), 1.1e18);

        // Bob deposits the SAME 100 USDC, but at NAV 1.10 → fewer shares than Alice got.
        _deposit(bob, 100 * ONE_USDC);
        uint256 bobShares = token.balanceOf(bob);

        assertLt(bobShares, 100 * ONE_SHARE); // fewer than Alice's 100 shares
        // Exact: 100e6 * 1e12 * 1e18 / 1.1e18 = 90.909...e18
        assertEq(bobShares, (100 * ONE_USDC * 1e12 * 1e18) / 1.1e18);
    }

    // Alice, who held through the yield, can now redeem for MORE USDC than she put in.
    function test_HolderThroughYieldRedeemsMore() public {
        _deposit(alice, 100 * ONE_USDC);

        // Admin injects yield. accrueYield pulls USDC from msg.sender (this test contract),
        // so this contract needs USDC + an approval. It does NOT need to be whitelisted:
        // accrueYield moves USDC, not shares, so the token's _update gate never runs.
        usdc.faucet(10 * ONE_USDC);
        usdc.approve(address(vault), 10 * ONE_USDC);
        vault.accrueYield(10 * ONE_USDC);

        uint256 before = usdc.balanceOf(alice);
        // NOTE: read the share balance BEFORE prank — vm.prank only affects the very next
        // external call, and evaluating token.balanceOf(alice) as an argument would consume it,
        // leaving redeem() to run as the test contract (which isn't whitelisted).
        uint256 aliceShares = token.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares);

        // She redeems all 100 shares at NAV 1.10 → ~110 USDC (she's the only holder).
        assertEq(usdc.balanceOf(alice) - before, 110 * ONE_USDC);
    }

    // ---------------------------------------------------------------------
    // Phase 4 — time-based continuous accrual
    // ---------------------------------------------------------------------

    uint256 constant BPS = 10_000;

    // Only YIELD_ADMIN_ROLE can change the rate.
    function test_SetYieldRateNonAdminReverts() public {
        // Read the role BEFORE pranking — evaluating vault.YIELD_ADMIN_ROLE() as an argument
        // is itself an external call and would consume the prank (same trap as Phase 3).
        bytes32 role = vault.YIELD_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        vm.prank(alice);
        vault.setYieldRate(500);
    }

    // Time passes, then someone deposits: the deposit must be priced AFTER settlement,
    // so totalAssets() already includes the accrued interest when shares are computed.
    function test_DepositSettlesPendingYieldFirst() public {
        _deposit(alice, 100 * ONE_USDC);
        vault.setYieldRate(500); // 5% APY

        skip(365 days);

        // Nothing minted yet — accrual is lazy, so the stored balance is still 100.
        assertEq(vault.totalAssets(), 100 * ONE_USDC);
        uint256 expectedYield = (100 * ONE_USDC * 500 * uint256(365 days)) / (BPS * uint256(365 days));
        assertEq(vault.pendingYield(), expectedYield); // 5 USDC

        // Bob's deposit triggers settlement first.
        _deposit(bob, 100 * ONE_USDC);

        // 100 principal + 5 yield + 100 from Bob.
        assertEq(vault.totalAssets(), 205 * ONE_USDC);

        // Bob was priced at the risen NAV (1.05), so he got fewer than 100 shares.
        assertLt(token.balanceOf(bob), 100 * ONE_SHARE);
    }

    // 5% APY held for exactly one year ≈ 5% NAV increase.
    function test_NavRisesProportionallyToElapsedTime() public {
        _deposit(alice, 100 * ONE_USDC);
        vault.setYieldRate(500);
        assertEq(vault.navPerToken(), 1e18);

        skip(365 days);

        // navPerToken() is a view and does NOT settle — still reads 1.00 until someone acts.
        assertEq(vault.navPerToken(), 1e18);

        // Any settling call realizes it; setYieldRate to the same value works as a poke.
        vault.setYieldRate(500);

        // 100 USDC -> 105 USDC against an unchanged 100e18 supply -> NAV 1.05.
        assertEq(vault.totalAssets(), 105 * ONE_USDC);
        assertEq(vault.navPerToken(), 1.05e18);
    }

    // Half a year at 5% ≈ 2.5%, showing accrual is linear in elapsed time.
    function test_NavRisesProRataForPartialYear() public {
        _deposit(alice, 100 * ONE_USDC);
        vault.setYieldRate(500);

        skip(182.5 days);
        vault.setYieldRate(500);

        assertEq(vault.totalAssets(), 102.5 * 1e6); // 100 + 2.5
    }

    // Changing the rate mid-flight must settle the old rate's window first.
    function test_RateChangeSettlesAtOldRateFirst() public {
        _deposit(alice, 100 * ONE_USDC);

        // Window 1: 5% APY for a year -> +5 USDC.
        vault.setYieldRate(500);
        skip(365 days);

        // Window 2 begins at 10%. This call settles window 1 at the OLD 5% rate.
        vault.setYieldRate(1000);
        assertEq(vault.totalAssets(), 105 * ONE_USDC);

        // A year at 10% on the new 105 base -> +10.5 USDC.
        skip(365 days);
        vault.setYieldRate(1000);
        assertEq(vault.totalAssets(), 115.5 * 1e6);

        // Had the 10% rate been applied retroactively to window 1, we'd have seen
        // 100 -> 110 -> 121. It didn't, which is the point of settling before switching.
    }

    // A holder who does nothing but wait gets paid on redeem, with no manual accrueYield().
    function test_RedeemSettlesYieldWithoutManualAccrual() public {
        uint256 before = usdc.balanceOf(alice);

        _deposit(alice, 100 * ONE_USDC);
        vault.setYieldRate(500);

        skip(365 days);

        uint256 aliceShares = token.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares);

        // Sole holder: she gets principal + the full year of accrued yield.
        assertEq(usdc.balanceOf(alice), before + 5 * ONE_USDC);
        assertEq(token.balanceOf(alice), 0);
    }

    // Two settlements in the same block: elapsed == 0, so no double-count and no revert.
    function test_ZeroElapsedAccruesNothing() public {
        _deposit(alice, 100 * ONE_USDC);
        vault.setYieldRate(500);
        skip(365 days);

        vault.setYieldRate(500); // settles -> 105
        assertEq(vault.totalAssets(), 105 * ONE_USDC);

        // Same block, no time passed. Must be a no-op, not a repeat payout.
        vault.setYieldRate(500);
        vault.setYieldRate(500);
        assertEq(vault.totalAssets(), 105 * ONE_USDC);
        assertEq(vault.pendingYield(), 0);
    }

    // With the rate at zero (the default), time alone accrues nothing.
    function test_NoYieldWhenRateIsZero() public {
        _deposit(alice, 100 * ONE_USDC);

        skip(365 days);
        assertEq(vault.pendingYield(), 0);

        _deposit(bob, 100 * ONE_USDC); // settles, but rate is 0
        assertEq(vault.totalAssets(), 200 * ONE_USDC);
        assertEq(vault.navPerToken(), 1e18);
    }

    // An idle window at rate 0 must not be paid retroactively once a rate is set.
    function test_IdleWindowNotPaidRetroactively() public {
        _deposit(alice, 100 * ONE_USDC);

        skip(365 days); // a year at 0%

        vault.setYieldRate(500); // stamps the clock; pays nothing for the idle year
        assertEq(vault.totalAssets(), 100 * ONE_USDC);

        skip(365 days); // a year at 5%
        vault.setYieldRate(500);
        assertEq(vault.totalAssets(), 105 * ONE_USDC); // one year's yield, not two
    }

    // ---------------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------------

    // To genuinely test nonReentrant we need a token that CALLS BACK into the
    // attacker during a transfer (a plain ERC-20 never does). We deploy a
    // separate Vault whose "USDC" is a hooked token that re-enters on payout.
    function test_ReentrancyOnRedeemReverts() public {
        // A malicious asset token that invokes a callback on the recipient during transfer.
        HookedToken hooked = new HookedToken();

        // A fresh token+vault wired to the hooked asset (SCALE math still holds:
        // hooked token uses 6 decimals like USDC).
        Whitelist wl2 = new Whitelist();
        TBillToken shares2 = new TBillToken(address(wl2));
        Vault vault2 = new Vault(address(hooked), address(shares2));
        shares2.grantRole(shares2.VAULT_ROLE(), address(vault2));

        ReentrantAttacker attacker = new ReentrantAttacker(vault2, hooked, shares2);
        wl2.addToWhitelist(address(attacker));

        // Fund the attacker and have it deposit so it holds shares to redeem.
        hooked.mint(address(attacker), 100 * ONE_USDC);
        attacker.deposit(100 * ONE_USDC);

        // Arm the attacker: on receiving the redeem payout it will try to re-enter.
        attacker.arm();

        // The re-entry attempt must be blocked by nonReentrant → whole tx reverts.
        vm.expectRevert();
        attacker.attack();
    }
}

// A 6-decimal ERC-20 that calls `onTokenReceived()` on the recipient during
// transfer — enough to trigger a reentrancy attempt on the vault's payout.
contract HookedToken {
    string public name = "Hooked";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // The malicious hook: notify the recipient, letting it re-enter.
        if (to.code.length > 0) {
            IReentryTarget(to).onTokenReceived();
        }
        return true;
    }
}

interface IReentryTarget {
    function onTokenReceived() external;
}

// A malicious contract that re-enters the vault's redeem() from the token callback.
contract ReentrantAttacker is IReentryTarget {
    Vault public vault;
    HookedToken public asset;
    TBillToken public shares;
    bool internal armed;

    constructor(Vault _vault, HookedToken _asset, TBillToken _shares) {
        vault = _vault;
        asset = _asset;
        shares = _shares;
    }

    function deposit(uint256 amount) external {
        asset.approve(address(vault), amount);
        vault.deposit(amount);
    }

    function arm() external {
        armed = true;
    }

    function attack() external {
        vault.redeem(shares.balanceOf(address(this)));
    }

    // Fired by HookedToken during the redeem payout → attempt a nested redeem.
    function onTokenReceived() external {
        if (armed) {
            armed = false; // avoid infinite loop if the guard somehow failed
            vault.redeem(1);
        }
    }
}
