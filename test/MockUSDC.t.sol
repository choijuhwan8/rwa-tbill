//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC public mockUSDC;

    // Runs fresh before every test — a clean MockUSDC each time.
    function setUp() public {
        mockUSDC = new MockUSDC();
    }

    // 1. decimals() returns 6 (mimics real USDC, not the ERC-20 default of 18).
    function test_DecimalsIsSix() public view {
        assertEq(mockUSDC.decimals(), 6);
    }

    // 2. faucet mints the requested amount to the caller (address(this) here)
    //    and increases totalSupply by the same amount.
    function test_FaucetMintsToCaller() public {
        mockUSDC.faucet(1_000_000); // 1 whole mUSDC (6 decimals)

        assertEq(mockUSDC.balanceOf(address(this)), 1_000_000);
        assertEq(mockUSDC.totalSupply(), 1_000_000);
    }

    // 3. A standard ERC-20 transfer works — proves the inherited logic is wired up.
    function test_TransferWorks() public {
        mockUSDC.faucet(1_000_000);

        address bob = makeAddr("bob");
        assertTrue(mockUSDC.transfer(bob, 400_000));

        assertEq(mockUSDC.balanceOf(bob), 400_000);
        assertEq(mockUSDC.balanceOf(address(this)), 600_000);
    }

    // 4. (Fuzz) faucet mints any amount correctly, whatever the input.
    function testFuzz_FaucetAnyAmount(uint256 amount) public {
        mockUSDC.faucet(amount);
        assertEq(mockUSDC.balanceOf(address(this)), amount);
    }
}
