// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PulseDistributor} from "../src/PulseDistributor.sol";

contract MockUSDC6 is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract PulseDistributorTest is Test {
    MockUSDC6 usdc;
    PulseDistributor dist;

    // Mirrors acex_ipo.distribute() snapshot: treasury 70% / investor 30% of $5.00.
    address treasury = address(0xA1);
    address investor = address(0xB2);
    uint256 amtTreasury = 3_500_000; // $3.50 in USDC base units
    uint256 amtInvestor = 1_500_000; // $1.50
    uint256 total = 5_000_000;

    bytes32 listingId = keccak256("prod-coldoutreach");
    bytes32 leaf0;
    bytes32 leaf1;
    bytes32 root;

    function setUp() public {
        usdc = new MockUSDC6();
        dist = new PulseDistributor(address(this));

        // index assigned by ascending address: treasury(0xA1) < investor(0xB2)
        leaf0 = keccak256(abi.encodePacked(uint256(0), treasury, amtTreasury));
        leaf1 = keccak256(abi.encodePacked(uint256(1), investor, amtInvestor));
        root = _hashPair(leaf0, leaf1);

        usdc.approve(address(dist), total);
        dist.postEpoch(listingId, usdc, root, total);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_epoch_funded() public view {
        assertEq(usdc.balanceOf(address(dist)), total);
        assertEq(dist.epochCount(), 1);
    }

    function test_claims_pay_holders_pro_rata() public {
        bytes32[] memory p0 = new bytes32[](1);
        p0[0] = leaf1;
        dist.claim(1, 0, treasury, amtTreasury, p0);
        assertEq(usdc.balanceOf(treasury), amtTreasury);

        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = leaf0;
        dist.claim(1, 1, investor, amtInvestor, p1);
        assertEq(usdc.balanceOf(investor), amtInvestor);

        assertEq(usdc.balanceOf(address(dist)), 0); // fully drained
    }

    function test_double_claim_reverts() public {
        bytes32[] memory p0 = new bytes32[](1);
        p0[0] = leaf1;
        dist.claim(1, 0, treasury, amtTreasury, p0);
        vm.expectRevert(PulseDistributor.AlreadyClaimed.selector);
        dist.claim(1, 0, treasury, amtTreasury, p0);
    }

    function test_wrong_amount_reverts() public {
        bytes32[] memory p0 = new bytes32[](1);
        p0[0] = leaf1;
        vm.expectRevert(PulseDistributor.InvalidProof.selector);
        dist.claim(1, 0, treasury, amtTreasury + 1, p0);
    }

    function test_post_epoch_only_owner() public {
        vm.prank(address(0xdead));
        vm.expectRevert();
        dist.postEpoch(listingId, usdc, root, total);
    }
}
