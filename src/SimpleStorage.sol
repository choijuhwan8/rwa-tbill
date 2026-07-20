// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SimpleStorage
/// @notice A minimal contract ported from the Remix days to learn the Foundry
///         build/test/deploy loop. Stores a single number.
contract SimpleStorage {
    uint256 private storedValue;

    /// @notice Emitted whenever the stored value changes.
    event ValueStored(uint256 newValue);

    /// @notice Store a new value.
    function store(uint256 value) public {
        storedValue = value;
        emit ValueStored(value);
    }

    /// @notice Read the currently stored value.
    function retrieve() public view returns (uint256) {
        return storedValue;
    }
}
