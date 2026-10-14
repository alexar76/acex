// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AgentShareToken} from "../src/AgentShareToken.sol";
import {PulseAMM} from "../src/PulseAMM.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MockUSDC6 is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract PulseAMMTest is Test {
    MockUSDC6 usdc;
    PulseAMM amm;
    AgentShareToken share;
    bytes32 listingId = keccak256("pool-agent");

    function setUp() public {
        usdc = new MockUSDC6();
        amm = new PulseAMM();
        amm.setQuoteToken(address(usdc));
        share = new AgentShareToken(address(this), listingId, "Cap", "CAP", 10_000_000e18);
        share.mintTo(address(this), 1_000_000e18);
        share.enableTrading();
        usdc.mint(address(this), 1_000_000e6);
    }

    function test_a_pool_quoted_in_another_token_is_refused() public {
        // The quote token is what the audit pool's oracle and the 1,000-USDC floor are
        // measured in; a market maker choosing it could price a CapShare in a token of its own.
        MockUSDC6 fake = new MockUSDC6();
        fake.mint(address(this), 1_000_000e6);
        share.approve(address(amm), type(uint256).max);
        fake.approve(address(amm), type(uint256).max);
        vm.expectRevert(PulseAMM.WrongQuoteToken.selector);
        amm.createPool(address(share), address(fake), 100_000e18, 100_000e6);
    }

    function test_the_quote_token_is_set_once() public {
        vm.expectRevert(PulseAMM.WrongQuoteToken.selector);
        amm.setQuoteToken(address(0xBEEF));
    }

    function test_create_pool_and_swap_both_ways() public {
        assertGe(share.balanceOf(address(this)), 500_000e18);
        share.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        amm.createPool(address(share), address(usdc), 500_000e18, 100_000e6);

        uint256 usdcBefore = usdc.balanceOf(address(this));
        amm.swapShareForUsdc(address(share), 10_000e18, 1);
        assertGt(usdc.balanceOf(address(this)), usdcBefore);

        share.approve(address(amm), 1_000e18);
        usdc.approve(address(amm), 10_000e6);
        uint256 shareBefore = share.balanceOf(address(this));
        amm.swapUsdcForShare(address(share), 5_000e6, 1);
        assertGt(share.balanceOf(address(this)), shareBefore);
    }

    function test_revert_swap_unknown_pool() public {
        vm.expectRevert();
        amm.swapShareForUsdc(address(share), 1e18, 1);
    }
}

// ── 2026-08 audit: overdrawing a locked balance must be an ERC20 error ──
contract ShareTokenLockRevertTest is Test {
    function test_overdraw_with_a_lock_set_gives_the_erc20_error_not_a_panic() public {
        AgentShareToken token = new AgentShareToken(address(this), "l", "T", "T", 1_000e18);
        token.mintTo(address(this), 100e18);
        token.enableTrading();
        token.setInitialLock(address(this), 50e18, uint64(block.timestamp + 30 days));

        // Overdraw: `balance - value` used to underflow before ERC20 could complain.
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), 100e18, 200e18
            )
        );
        token.transfer(address(0xBEEF), 200e18);

        // The lock itself still bites, with its own error.
        vm.expectRevert(AgentShareToken.TokensLocked.selector);
        token.transfer(address(0xBEEF), 60e18);

        // And the unlocked part still moves.
        assertTrue(token.transfer(address(0xBEEF), 50e18));
    }
}
