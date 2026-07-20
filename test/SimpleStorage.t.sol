// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleStorage} from "../src/SimpleStorage.sol";

contract SimpleStorageTest is Test {
    SimpleStorage public simpleStorage;

    // Runs fresh before every test — state never leaks between cases.
    function setUp() public {
        simpleStorage = new SimpleStorage();
    }

    // 1. A freshly deployed contract stores zero by default.
    function test_InitialValueIsZero() public view {
        assertEq(simpleStorage.retrieve(), 0);
    }

    // 2. store() updates the value that retrieve() returns.
    function test_StoreUpdatesValue() public {
        simpleStorage.store(42);
        assertEq(simpleStorage.retrieve(), 42);
    }

    // 3. Fuzz test — Foundry auto-runs this 256x with random x.
    //    Whatever we store must be exactly what we read back.
    function testFuzz_StoreAnyValue(uint256 x) public {
        simpleStorage.store(x);
        assertEq(simpleStorage.retrieve(), x);
    }
}
