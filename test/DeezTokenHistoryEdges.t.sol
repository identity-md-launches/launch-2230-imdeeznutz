// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DeezToken} from "src/DeezToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract DeezTokenHistoryEdgesTest is Test {
    DeezToken private token;
    address private alice;
    address private bob;
    uint256 private constant START = 1_700_000_007;

    function setUp() public {
        vm.warp(START);
        alice = makeAddr("edge-alice");
        bob = makeAddr("edge-bob");
        token = new DeezToken(alice);
    }

    function test_failedTransferFromRestoresSpentAllowanceAndBothHistories() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        vm.warp(START + 13);
        uint256 supply = token.TOTAL_SUPPLY();
        uint256 amount = supply + 1;
        uint256 beforeArea = token.getCumulativeBalanceOf(alice, block.timestamp);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, supply, amount));
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, bob), type(uint256).max - 1);
        assertEq(token.numCheckpoints(alice), 1);
        assertEq(token.numCheckpoints(bob), 0);
        assertEq(token.getCumulativeBalanceOf(alice, block.timestamp), beforeArea);
        assertEq(token.balanceOf(alice), token.TOTAL_SUPPLY());
    }

    function test_allowanceFailureLeavesHistoriesUntouched() public {
        vm.prank(alice);
        token.approve(bob, 1);
        vm.warp(START + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 1, 2));
        token.transferFrom(alice, bob, 2);
        assertEq(token.allowance(alice, bob), 1);
        assertEq(token.numCheckpoints(alice), 1);
        assertEq(token.numCheckpoints(bob), 0);
    }

    function test_zeroReceiverCannotBurnSupplyOrCreateCheckpoints() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
        assertEq(token.numCheckpoints(address(0)), 0);
        assertEq(token.numCheckpoints(alice), 1);
    }

    function test_fullSupplyRoundTripInOneSecondHasNoRewardWeight() public {
        vm.warp(START + 1 days);
        uint256 amount = token.TOTAL_SUPPLY();
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);
        vm.warp(START + 2 days);
        assertEq(token.getPastBalanceOf(bob, START + 1 days), 0);
        assertEq(token.getCumulativeBalanceOf(bob, block.timestamp), 0);
        assertEq(token.getCumulativeBalanceOf(alice, block.timestamp), 2 * amount);
        assertEq(token.numCheckpoints(bob), 1, "same-second round trip should coalesce");
    }

    function test_zeroAndSelfTransfersPreserveExactWholeDayTokenTime() public {
        vm.warp(START + 1 days);
        vm.prank(alice);
        token.transfer(bob, 0);
        uint256 supply = token.TOTAL_SUPPLY();
        vm.prank(alice);
        token.transfer(alice, supply);
        vm.warp(START + 2 days);
        assertEq(token.getCumulativeBalanceOf(alice, block.timestamp), 2 * token.TOTAL_SUPPLY());
        assertEq(token.getCumulativeBalanceOf(bob, block.timestamp), 0);
        assertEq(token.balanceOf(alice), token.TOTAL_SUPPLY());
    }

    function testFuzz_binarySearchFindsEveryIntervalOfLongHistory(uint256 seed, uint256 spacingSeed, uint256 amountSeed)
        public
    {
        uint256 spacing = bound(spacingSeed, 2, 3 days);
        uint256 amount = bound(amountSeed, 1, token.TOTAL_SUPPLY() / 32);
        // Alternating balances make choosing the wrong neighboring checkpoint observable.
        for (uint256 i; i < 32; ++i) {
            vm.warp(START + (i + 1) * spacing);
            vm.prank(i % 2 == 0 ? alice : bob);
            token.transfer(i % 2 == 0 ? bob : alice, amount);
        }
        vm.warp(START + 33 * spacing);
        uint256 interval = seed % 32;
        uint256 at = START + (interval + 1) * spacing;
        uint256 expected = interval % 2 == 0 ? amount : 0;
        assertEq(token.getPastBalanceOf(bob, at), expected);
        assertEq(token.getPastBalanceOf(bob, at + spacing - 1), expected);
        assertEq(token.getPastBalanceOf(bob, at - 1), interval % 2 == 0 ? 0 : amount);
        assertEq(token.getPastBalanceOf(bob, START - 1), 0);
        assertEq(token.numCheckpoints(bob), 32);
        // Sixteen disjoint holds; each completed interval can lose less than one wei-day.
        uint256 exactFloor = amount * spacing * 16 / 1 days;
        uint256 integral = token.getCumulativeBalanceOf(bob, block.timestamp);
        assertLe(integral, exactFloor);
        assertLe(exactFloor - integral, 16);
    }
}
