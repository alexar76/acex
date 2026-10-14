// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

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
    error BelowMinimumLiquidity();
    error WrongQuoteToken();

    /// @dev Floor below which a reserve may not be driven by a swap. A near-empty pool yields a
    ///      cheaply-manipulable spot price, which the AgentAuditPool oracle reads — so we forbid
    ///      draining a side below this minimum.
    uint256 public constant MIN_RESERVE = 1000;

    /// @dev Floor on the USDC side AT CREATION. MIN_RESERVE is 1000 raw units — for 6-decimal
    ///      USDC that is 0.001 USDC, i.e. economically zero, so it never actually made the spot
    ///      price expensive to move. Since {AgentAuditPool} reads this pool's reserves as its
    ///      price oracle, and a defaulted listing pays slashed auditor stake to note holders,
    ///      a dust pool was a cheap lever on real money. Matched to MIN_COVER_USDC — the amount
    ///      a single auditor coverage puts at risk — so moving the oracle costs the same order
    ///      as what manipulating it can win.
    uint256 public constant MIN_INITIAL_USDC = 1_000e6;

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

    /// @notice The one token every pool is quoted in (USDC). Set once by the owner. The
    ///         creator of a pool used to choose it — and the audit pool's oracle and the
    ///         1,000-USDC creation floor are both measured in it.
    IERC20 public quoteToken;

    /// @dev Reserves as they stood when the current block began, per pool: written by the
    ///      first swap of a block, before it moves anything. {AgentAuditPool} reads its oracle
    ///      price from these, so a crash and its reversal inside one transaction — a flash
    ///      swap — never reaches the price it records. Keyed by block.timestamp, which is
    ///      strictly increasing per block on the chains this runs on.
    mapping(address => uint256) public lastSwapTimestamp;
    mapping(address => uint256) private _blockStartShare;
    mapping(address => uint256) private _blockStartUsdc;

    /// @notice Time-weighted price accumulator per pool: the sum of priceE18 x seconds the
    ///         price held, folded in by every swap BEFORE it moves the reserves (Uniswap v2's
    ///         oracle shape). A price counts for exactly as long as it stood, so a crash held
    ///         across one block boundary weighs two seconds, not the day a sample-and-hold
    ///         oracle gave it until somebody observed again.
    mapping(address => uint256) public priceCumulativeLast;
    mapping(address => uint256) public priceCumulativeTimestamp;

    constructor() Ownable(msg.sender) {}

    function setQuoteToken(address token) external onlyOwner {
        if (token == address(0) || address(quoteToken) != address(0)) revert WrongQuoteToken();
        quoteToken = IERC20(token);
    }

    function setMarketMaker(address mm, bool allowed) external onlyOwner {
        marketMakers[mm] = allowed;
    }

    /// @notice Open the market for a CapShare. Permissioned: the first caller for a given
    ///         share token fixes the pool forever (`active` blocks re-creation) and therefore
    ///         defines the price {AgentAuditPool} reads as its oracle. The `marketMakers`
    ///         allow-list below existed from the start but was never consulted — writing to it
    ///         had no effect, and anyone could front-run the intended market maker.
    function createPool(
        address shareToken,
        address usdc,
        uint256 initialShares,
        uint256 initialUsdc
    ) external nonReentrant whenNotPaused {
        if (msg.sender != owner() && !marketMakers[msg.sender]) revert Unauthorized();
        if (address(quoteToken) == address(0) || usdc != address(quoteToken)) revert WrongQuoteToken();
        if (pools[shareToken].active) revert();
        // A pool created below the swap floor can never be swapped (every swap trips the
        // post-condition) and can never be re-created — a permanent DoS on that CapShare's
        // market for the price of dust.
        if (initialUsdc < MIN_INITIAL_USDC || initialShares < MIN_RESERVE) {
            revert BelowMinimumLiquidity();
        }
        IERC20(shareToken).safeTransferFrom(msg.sender, address(this), initialShares);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), initialUsdc);
        pools[shareToken] = Pool({
            shareToken: IERC20(shareToken),
            usdc: IERC20(usdc),
            reserveShare: initialShares,
            reserveUsdc: initialUsdc,
            active: true
        });
        priceCumulativeTimestamp[shareToken] = block.timestamp;
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
        _snapshotBlockStart(p, shareToken);
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
        _snapshotBlockStart(p, shareToken);
        shareOut = _getAmountOut(usdcIn, p.reserveUsdc, p.reserveShare);
        if (shareOut < minShareOut) revert InsufficientOutput();
        p.usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        p.shareToken.safeTransfer(msg.sender, shareOut);
        p.reserveUsdc += usdcIn;
        p.reserveShare -= shareOut;
        if (p.reserveShare < MIN_RESERVE || p.reserveUsdc < MIN_RESERVE) revert InsufficientLiquidity();
        emit Swapped(shareToken, msg.sender, false, usdcIn, shareOut);
    }

    function _snapshotBlockStart(Pool storage p, address shareToken) internal {
        uint256 lastCum = priceCumulativeTimestamp[shareToken];
        if (block.timestamp > lastCum) {
            if (p.reserveShare > 0) {
                priceCumulativeLast[shareToken] +=
                    ((p.reserveUsdc * 1e18) / p.reserveShare) * (block.timestamp - lastCum);
            }
            priceCumulativeTimestamp[shareToken] = block.timestamp;
        }
        if (lastSwapTimestamp[shareToken] != block.timestamp) {
            lastSwapTimestamp[shareToken] = block.timestamp;
            _blockStartShare[shareToken] = p.reserveShare;
            _blockStartUsdc[shareToken] = p.reserveUsdc;
        }
    }

    /// @notice The pool's price (USDC per share, 1e18-scaled) from its reserves at the start
    ///         of the current block. A swap earlier in this block — in this transaction or
    ///         another — does not move it; holding a manipulated price costs a block boundary.
    function blockStartPriceE18(address shareToken) external view returns (uint256) {
        Pool storage p = pools[shareToken];
        if (!p.active) return 0;
        uint256 rs = p.reserveShare;
        uint256 ru = p.reserveUsdc;
        if (lastSwapTimestamp[shareToken] == block.timestamp) {
            rs = _blockStartShare[shareToken];
            ru = _blockStartUsdc[shareToken];
        }
        if (rs == 0) return 0;
        return (ru * 1e18) / rs;
    }

    /// @notice The accumulator as of now: what is stored plus the current price for the time
    ///         since the last swap. A swap earlier in this block already folded and stamped
    ///         the block's start, so nothing done inside this block adds weight until the
    ///         next one — a manipulation must be held to be counted, and only for how long.
    function currentCumulativePrice(address shareToken) external view returns (uint256 cumulative) {
        Pool storage p = pools[shareToken];
        cumulative = priceCumulativeLast[shareToken];
        uint256 last = priceCumulativeTimestamp[shareToken];
        if (p.active && last != 0 && block.timestamp > last && p.reserveShare > 0) {
            cumulative += ((p.reserveUsdc * 1e18) / p.reserveShare) * (block.timestamp - last);
        }
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
