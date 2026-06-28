// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PulseAMM — constant-product AMM for CapShare / USDC pairs
contract PulseAMM is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    error PoolNotFound();
    error InsufficientOutput();
    error Unauthorized();
    error InsufficientLiquidity();

    /// @dev Floor below which a reserve may not be driven by a swap. A near-empty pool yields a
    ///      cheaply-manipulable spot price, which the AgentAuditPool oracle reads — so we forbid
    ///      draining a side below this minimum.
    uint256 public constant MIN_RESERVE = 1000;

    event PoolCreated(address indexed shareToken, address indexed usdc, uint256 shareReserve, uint256 usdcReserve);
    event Swapped(address indexed shareToken, address indexed trader, bool shareToUsdc, uint256 amountIn, uint256 amountOut);

    struct Pool {
        IERC20 shareToken;
        IERC20 usdc;
        uint256 reserveShare;
        uint256 reserveUsdc;
        bool active;
    }

    mapping(address => Pool) public pools;
    mapping(address => bool) public marketMakers;

    constructor() Ownable(msg.sender) {}

    function setMarketMaker(address mm, bool allowed) external onlyOwner {
        marketMakers[mm] = allowed;
    }

    function createPool(
        address shareToken,
        address usdc,
        uint256 initialShares,
        uint256 initialUsdc
    ) external nonReentrant whenNotPaused {
        if (pools[shareToken].active) revert();
        IERC20(shareToken).safeTransferFrom(msg.sender, address(this), initialShares);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), initialUsdc);
        pools[shareToken] = Pool({
            shareToken: IERC20(shareToken),
            usdc: IERC20(usdc),
            reserveShare: initialShares,
            reserveUsdc: initialUsdc,
            active: true
        });
        emit PoolCreated(shareToken, usdc, initialShares, initialUsdc);
    }

    /// @notice Swap CapShares → USDC
    function swapShareForUsdc(address shareToken, uint256 shareIn, uint256 minUsdcOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        Pool storage p = pools[shareToken];
        if (!p.active) revert PoolNotFound();
        usdcOut = _getAmountOut(shareIn, p.reserveShare, p.reserveUsdc);
        if (usdcOut < minUsdcOut) revert InsufficientOutput();
        p.shareToken.safeTransferFrom(msg.sender, address(this), shareIn);
        p.usdc.safeTransfer(msg.sender, usdcOut);
        p.reserveShare += shareIn;
        p.reserveUsdc -= usdcOut;
        if (p.reserveShare < MIN_RESERVE || p.reserveUsdc < MIN_RESERVE) revert InsufficientLiquidity();
        emit Swapped(shareToken, msg.sender, true, shareIn, usdcOut);
    }

    /// @notice Swap USDC → CapShares
    function swapUsdcForShare(address shareToken, uint256 usdcIn, uint256 minShareOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shareOut)
    {
        Pool storage p = pools[shareToken];
        if (!p.active) revert PoolNotFound();
        shareOut = _getAmountOut(usdcIn, p.reserveUsdc, p.reserveShare);
        if (shareOut < minShareOut) revert InsufficientOutput();
        p.usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        p.shareToken.safeTransfer(msg.sender, shareOut);
        p.reserveUsdc += usdcIn;
        p.reserveShare -= shareOut;
        if (p.reserveShare < MIN_RESERVE || p.reserveUsdc < MIN_RESERVE) revert InsufficientLiquidity();
        emit Swapped(shareToken, msg.sender, false, usdcIn, shareOut);
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        return numerator / denominator;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
