// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {Whitelist} from "../src/Whitelist.sol";
import {TBillToken} from "../src/TBillToken.sol";
import {Vault} from "../src/Vault.sol";

/// @notice Deploys and wires the full sgTBILL system.
/// @dev Usage (local):   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
///      Usage (Sepolia): see README "Deploy to Sepolia".
///
///      Optional env vars:
///        YIELD_BPS  annual yield rate in basis points (default 500 == 5.00%)
///        WHITELIST  comma-separated extra addresses to whitelist (the deployer is always added)
contract Deploy is Script {
    uint256 internal constant DEFAULT_YIELD_BPS = 500;

    /// @notice Burn address that permanently holds the seed shares. Nobody has its key, so
    ///         these shares can never be redeemed or moved.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice 1 mUSDC → 1 whole sgTBILL locked forever (cf. Uniswap V2 MINIMUM_LIQUIDITY).
    uint256 public constant SEED_USDC = 1e6;

    struct Deployment {
        MockUSDC usdc;
        Whitelist whitelist;
        TBillToken token;
        Vault vault;
    }

    function run() external returns (Deployment memory d) {
        uint256 yieldBps = vm.envOr("YIELD_BPS", DEFAULT_YIELD_BPS);
        address[] memory extra = vm.envOr("WHITELIST", ",", new address[](0));

        vm.startBroadcast();
        // Inside a broadcast, msg.sender is the broadcasting EOA, so the EOA (not this
        // script contract) ends up holding every admin role.
        d = deploy(msg.sender, yieldBps, extra);
        vm.stopBroadcast();

        _log(d);
        _writeDeployment(d);
    }

    /// @notice Deploy + wire everything. Split out from run() so tests can call it directly.
    function deploy(address deployer, uint256 yieldBps, address[] memory extraWhitelist)
        public
        returns (Deployment memory d)
    {
        d.usdc = new MockUSDC();
        d.whitelist = new Whitelist();
        d.token = new TBillToken(address(d.whitelist));
        d.vault = new Vault(address(d.usdc), address(d.token));

        // Vault mints/burns sgTBILL on deposit/redeem.
        d.token.grantRole(d.token.VAULT_ROLE(), address(d.vault));
        // Vault mints simulated T-bill interest into itself (Phase 4).
        d.usdc.grantRole(d.usdc.MINTER_ROLE(), address(d.vault));

        d.whitelist.addToWhitelist(deployer);
        for (uint256 i = 0; i < extraWhitelist.length; i++) {
            if (!d.whitelist.isWhitelisted(extraWhitelist[i])) {
                d.whitelist.addToWhitelist(extraWhitelist[i]);
            }
        }

        _seed(d, deployer);

        if (yieldBps > 0) d.vault.setYieldRate(yieldBps);
    }

    /// @dev Dead-shares seeding. Without it, once supply falls to a few share-units (fresh
    ///      vault, or everyone exits), a donation or yield injection inflates NAV so far that
    ///      every normal deposit rounds to zero shares and reverts — a cheap griefing DoS.
    ///      Locking 1 whole share keeps supply >= 1e18 forever, which makes that cost
    ///      ~1e18x the deposit size being blocked. See SECURITY.md (F-2).
    function _seed(Deployment memory d, address deployer) internal {
        d.whitelist.addToWhitelist(DEAD);
        d.usdc.faucet(SEED_USDC);
        d.usdc.approve(address(d.vault), SEED_USDC);
        d.vault.deposit(SEED_USDC);
        // First deposit is at NAV 1.00, so this is exactly 1e18 shares (asserted in tests).
        d.token.transfer(DEAD, d.token.balanceOf(deployer));
    }

    function _log(Deployment memory d) internal pure {
        console.log("MockUSDC   ", address(d.usdc));
        console.log("Whitelist  ", address(d.whitelist));
        console.log("TBillToken ", address(d.token));
        console.log("Vault      ", address(d.vault));
    }

    /// @dev Writes frontend/src/deployments/<chainId>.json so the dApp picks up the new
    ///      addresses without any copy-pasting.
    function _writeDeployment(Deployment memory d) internal {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "deployedAtBlock", block.number);
        vm.serializeAddress(key, "usdc", address(d.usdc));
        vm.serializeAddress(key, "whitelist", address(d.whitelist));
        vm.serializeAddress(key, "token", address(d.token));
        string memory json = vm.serializeAddress(key, "vault", address(d.vault));

        string memory path = string.concat("frontend/src/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console.log("Wrote", path);
    }
}
