//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TBillToken} from "./TBillToken.sol";

contract Vault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- State & constants ---
    IERC20 public immutable usdc; // the asset users deposit (6 decimals)
    TBillToken public immutable shareToken; // the fund share token, sgTBILL (18 decimals)

    bytes32 public constant YIELD_ADMIN_ROLE = keccak256("YIELD_ADMIN_ROLE");

    uint256 private constant PRECISION = 1e18; // fixed-point scale for NAV (1e18 == "1.00")
    uint256 private constant SCALE = 1e12; // 10^(18-6): bridges USDC 6dp and sgTBILL 18dp

    // --- Events ---
    event Deposited(address indexed user, uint256 usdcIn, uint256 sharesOut);
    event Redeemed(address indexed user, uint256 sharesIn, uint256 usdcOut);
    event YieldAccrued(uint256 usdcAdded, uint256 newNavPerToken);

    constructor(address usdcAddress, address shareTokenAddress) {
        usdc = IERC20(usdcAddress);
        shareToken = TBillToken(shareTokenAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(YIELD_ADMIN_ROLE, msg.sender);
    }

    // --- Views ---

    /// @notice Total USDC held by the vault, in USDC's own 6-decimal base units.
    function totalAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice USD value of one whole share, in 18-decimal fixed point (1e18 == 1.00).
    /// @dev Assets (6dp) are lifted by SCALE so they compare like-for-like with supply (18dp).
    function navPerToken() public view returns (uint256) {
        uint256 supply = shareToken.totalSupply();
        if (supply == 0) return PRECISION; // 1.00 before anyone deposits
        return (totalAssets() * SCALE * PRECISION) / supply;
    }

    // --- Core actions ---

    /// @notice Deposit USDC, receive newly minted sgTBILL at the current NAV.
    /// @dev Caller must approve() this vault for `usdcAmount` on the USDC token first.
    function deposit(uint256 usdcAmount) external nonReentrant {
        require(usdcAmount > 0, "zero deposit");

        uint256 nav = navPerToken();
        // usdc (6dp) -> shares (18dp): lift by SCALE, then divide by NAV.
        uint256 sharesOut = (usdcAmount * SCALE * PRECISION) / nav;
        require(sharesOut > 0, "shares rounded to zero");

        // Interaction 1: pull the user's USDC in (needs prior approval).
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        // Effect: mint shares to the user (reverts if user not whitelisted — Phase 2 gate).
        shareToken.mint(msg.sender, sharesOut);

        emit Deposited(msg.sender, usdcAmount, sharesOut);
    }

    /// @notice Burn sgTBILL, receive USDC back at the current NAV.
    function redeem(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "zero redeem");

        uint256 nav = navPerToken();
        // shares (18dp) -> usdc (6dp): apply NAV, then drop PRECISION and SCALE.
        uint256 usdcOut = (shareAmount * nav) / PRECISION / SCALE;
        require(usdcOut > 0, "usdc rounded to zero");

        // Effects first (checks-effects-interactions): burn the user's shares...
        shareToken.burn(msg.sender, shareAmount);
        // ...then interact: send USDC out.
        usdc.safeTransfer(msg.sender, usdcOut);

        emit Redeemed(msg.sender, shareAmount, usdcOut);
    }

    function accrueYield(uint256 usdcAmount) external onlyRole(YIELD_ADMIN_ROLE) {
        require(usdcAmount > 0, "zero yield");
        // Interaction: pull the yield in (needs prior approval).
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        emit YieldAccrued(usdcAmount, navPerToken());
    }
}
