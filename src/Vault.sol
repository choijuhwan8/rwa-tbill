//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TBillToken} from "./TBillToken.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract Vault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // --- State & constants ---
    IERC20 public immutable usdc; // the asset users deposit (6 decimals)
    TBillToken public immutable shareToken; // the fund share token, sgTBILL (18 decimals)

    bytes32 public constant YIELD_ADMIN_ROLE = keccak256("YIELD_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 private constant PRECISION = 1e18; // fixed-point scale for NAV (1e18 == "1.00")
    uint256 private constant SCALE = 1e12; // 10^(18-6): bridges USDC 6dp and sgTBILL 18dp
    uint256 private constant BPS_DENOMINATOR = 10_000; // 10000 bps == 100%
    uint256 private constant YEAR = 365 days; // simple ACT/365 day count (see _realizeYield)

    /// @notice Hard ceiling on the yield rate (20.00%). Because yield is *minted*, an
    ///         uncapped rate would let a compromised YIELD_ADMIN inflate NAV without limit.
    uint256 public constant MAX_YIELD_BPS = 2_000;

    /// @notice Annualized yield rate in basis points (500 == 5.00% APY, simple not compounding).
    uint256 public annualYieldRateBps;

    /// @notice Timestamp through which time-based yield has already been minted.
    uint256 public lastAccrualTimestamp;

    // --- Events ---
    event Deposited(address indexed user, uint256 usdcIn, uint256 sharesOut);
    event Redeemed(address indexed user, uint256 sharesIn, uint256 usdcOut);
    event YieldAccrued(uint256 usdcAdded, uint256 newNavPerToken);
    event YieldRateSet(uint256 oldBps, uint256 newBps);

    constructor(address usdcAddress, address shareTokenAddress) {
        require(usdcAddress != address(0) && shareTokenAddress != address(0), "zero address");
        usdc = IERC20(usdcAddress);
        shareToken = TBillToken(shareTokenAddress);
        lastAccrualTimestamp = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(YIELD_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
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

    /// @notice Yield that has accrued in wall-clock time but has not been minted yet.
    /// @dev Purely informational — a UI can add this to totalAssets() to show a live NAV.
    ///      It is NOT folded into navPerToken(), which stays a cheap, non-mutating read.
    function pendingYield() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        // slither-disable-next-line incorrect-equality,timestamp
        if (elapsed == 0 || annualYieldRateBps == 0) return 0;
        return (totalAssets() * annualYieldRateBps * elapsed) / (BPS_DENOMINATOR * YEAR);
    }

    // --- Yield accrual ---

    /// @notice Mint the yield owed for the elapsed period and advance the accrual clock.
    /// @dev Simple (non-compounding) interest over the elapsed window, ACT/365:
    ///        yield = assets * rateBps * elapsed / (10000 * 365 days)
    ///      Multiply-before-divide keeps the integer truncation to a single final rounding,
    ///      which rounds *down* — i.e. against the holders, never against the vault.
    ///
    ///      Lazy settlement: this only runs when someone actually transacts. Between calls
    ///      the on-chain balance is stale-but-conservative; nothing is lost, it just hasn't
    ///      been minted yet. That is how ERC-4626-style vaults usually handle streaming yield.
    function _realizeYield() internal {
        _mintYield(_checkpointYield());
    }

    /// @dev Effects half of settlement: compute what the elapsed window owes at the
    ///      *current* rate and advance the clock. Touches no external contract, so callers
    ///      can finish all their own state writes before `_mintYield` makes the external call.
    function _checkpointYield() internal returns (uint256 yieldAmount) {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        // Advance the clock unconditionally: a no-op window (same block, or rate == 0) must
        // still be stamped so a later rate change doesn't retroactively pay for it. Doing it
        // before any mint also means a re-entrant call would see elapsed == 0.
        lastAccrualTimestamp = block.timestamp;

        // (Strict equality on `elapsed` is intended: it is a no-op guard, not a deadline, and
        // a validator nudging the timestamp by seconds moves yield by a negligible amount.)
        // slither-disable-next-line incorrect-equality,timestamp
        if (elapsed == 0 || annualYieldRateBps == 0) return 0;

        yieldAmount = (totalAssets() * annualYieldRateBps * elapsed) / (BPS_DENOMINATOR * YEAR);
    }

    /// @dev Interactions half of settlement.
    function _mintYield(uint256 yieldAmount) internal {
        // slither-disable-next-line incorrect-equality,timestamp
        if (yieldAmount == 0) return;
        // `usdc` is an immutable, trusted token set at construction, so the event after the
        // mint can't be reordered by a hostile callee. The event reads the post-mint NAV.
        // slither-disable-next-line reentrancy-events
        MockUSDC(address(usdc)).mint(address(this), yieldAmount);
        emit YieldAccrued(yieldAmount, navPerToken());
    }

    /// @notice Set the annualized yield rate, in basis points.
    /// @dev Settles the outstanding period at the OLD rate before switching. Without this,
    ///      changing the rate would retroactively reprice every unsettled second.
    ///      Checks → effects (checkpoint at old rate, store new rate) → interaction (mint).
    function setYieldRate(uint256 bps) external nonReentrant onlyRole(YIELD_ADMIN_ROLE) {
        require(bps <= MAX_YIELD_BPS, "rate too high");
        uint256 owed = _checkpointYield();
        emit YieldRateSet(annualYieldRateBps, bps);
        annualYieldRateBps = bps;
        _mintYield(owed);
    }

    // --- Core actions ---

    /// @notice Deposit USDC, receive newly minted sgTBILL at the current NAV.
    /// @dev Caller must approve() this vault for `usdcAmount` on the USDC token first.
    function deposit(uint256 usdcAmount) external nonReentrant whenNotPaused {
        require(usdcAmount > 0, "zero deposit");

        // Settle first: price this deposit at the post-accrual NAV, so the new depositor
        // doesn't get shares cheaply and dilute the yield earned before they arrived.
        _realizeYield();

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
    function redeem(uint256 shareAmount) external nonReentrant whenNotPaused {
        require(shareAmount > 0, "zero redeem");

        // Settle first: the redeemer is entitled to yield accrued right up to this block.
        _realizeYield();

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

    /// @notice Manually inject real yield (e.g. a coupon paid by the underlying T-bills).
    function accrueYield(uint256 usdcAmount) external nonReentrant onlyRole(YIELD_ADMIN_ROLE) {
        require(usdcAmount > 0, "zero yield");
        // Settle time-based yield first, so this manual injection isn't used as the
        // principal base for the period that preceded it.
        _realizeYield();
        // Interaction: pull the yield in (needs prior approval).
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        emit YieldAccrued(usdcAmount, navPerToken());
    }

    // --- Emergency controls ---

    /// @notice Halt deposits and redemptions (e.g. custodian incident, oracle/NAV dispute).
    /// @dev Yield keeps accruing while paused; holders lose nothing, they just can't exit
    ///      until unpaused. Admin and compliance functions stay available.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
