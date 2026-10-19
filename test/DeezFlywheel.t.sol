// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeezBase} from "./DeezBase.t.sol";
import {DeezRewards} from "../src/DeezRewards.sol";

/// @notice End to end: trades pay the fee, anyone harvests, the epoch ends, holders claim $IMD by balance.
contract DeezFlywheelTest is DeezBase {
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0x4EE9);

    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function test_tradesBecomeHolderRewards() public {
        vm.warp(1_000 * 1 days);
        seedBalanced(1_000_000 ether);
        // Everything the test still holds goes to the pool stand-in so only alice and bob are eligible.
        token.transfer(alice, 600 ether);
        token.transfer(bob, 200 ether);
        token.transfer(address(manager), token.balanceOf(address(this)));

        buy(-10_000 ether);
        sell(-3_000 ether);
        buy(2_000 ether);
        uint256 fees = hook.pendingFees();
        assertGt(fees, 0);

        vm.prank(keeper);
        hook.harvest();
        assertEq(imd.balanceOf(address(rewards)), fees);

        uint256 epoch = rewards.currentEpoch();
        vm.warp((epoch + 1) * 1 days);

        uint256 supply = rewards.eligibleSupplyAt(epoch);
        assertEq(supply, 800 ether + token.balanceOf(address(swapper)), "pool, hook and distributor excluded");

        uint256[] memory list = new uint256[](1);
        list[0] = epoch;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.NotAccount.selector, alice));
        rewards.claim(alice, list);
        vm.prank(alice);
        uint256 paidAlice = rewards.claim(alice, list);
        vm.prank(bob);
        uint256 paidBob = rewards.claim(bob, list);
        assertEq(paidAlice, fees * 600 ether / supply);
        assertEq(paidBob, fees * 200 ether / supply);
        assertApproxEqAbs(paidAlice, 3 * paidBob, 3, "three times the bag, three times the share");
        assertEq(imd.balanceOf(alice), paidAlice);
        assertEq(imd.balanceOf(bob), paidBob);
    }

    function test_feesBelongToTheEpochTheyWereTradedInWheneverHarvested() public {
        vm.warp(1_000 * 1 days);
        seedBalanced(1_000_000 ether);
        token.transfer(alice, 1_000 ether);
        buy(-1_000 ether);
        uint256 fees = hook.pendingFees();
        uint256 epoch = rewards.currentEpoch();
        vm.warp((epoch + 1) * 1 days + 3600);
        // Harvested a day later: the fees still land in the pot of the epoch they were traded in.
        hook.harvest();
        uint256 supply = rewards.eligibleSupplyAt(epoch);
        assertEq(rewards.claimable(alice, epoch), fees * 1_000 ether / supply);
        vm.warp((epoch + 2) * 1 days);
        assertEq(rewards.claimable(alice, epoch + 1), 0, "nothing was traded in the next epoch");
    }

    function test_earlyClaimerGetsItsShareOfFeesHarvestedLater() public {
        // The review's scenario: half the day's fees are harvested at noon, the other half are still in the
        // hook when alice claims right after the day ends. Her claim harvests them, so she is paid her share
        // of the whole day in one go, and a later harvest() or second claim changes nothing for her.
        vm.warp(1_000 * 1 days);
        seedBalanced(1_000_000 ether);
        token.transfer(alice, 75_000_000 ether);
        token.transfer(bob, 25_000_000 ether);
        token.transfer(address(manager), token.balanceOf(address(this)));
        uint256 epoch = rewards.currentEpoch();

        vm.warp(1_000 * 1 days + 12 hours);
        buy(-5_000 ether);
        hook.harvest();
        vm.warp(1_000 * 1 days + 23 hours);
        buy(-5_000 ether);
        uint256 pending = hook.pendingFeesOf(epoch);
        assertEq(pending, 100 ether);

        vm.warp((epoch + 1) * 1 days);
        uint256 supply = rewards.eligibleSupplyAt(epoch);
        uint256 owedAlice = 200 ether * rewards.weightOf(alice, epoch) / supply;
        assertEq(rewards.claimable(alice, epoch), owedAlice, "claimable counts the unharvested fees");
        uint256[] memory list = new uint256[](1);
        list[0] = epoch;
        vm.prank(alice);
        uint256 paidAlice = rewards.claim(alice, list);
        assertEq(paidAlice, owedAlice, "paid her share of every fee of the epoch at once");
        assertEq(hook.pendingFeesOf(epoch), 0, "the claim harvested the epoch");
        (uint128 total,,,) = rewards.pots(epoch);
        assertEq(total, 200 ether);

        assertEq(hook.harvest(), 0, "nothing left to harvest");
        assertEq(rewards.claimable(alice, epoch), 0);
        vm.prank(alice);
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(alice, list);
        vm.prank(bob);
        uint256 paidBob = rewards.claim(bob, list);
        assertEq(paidBob, 200 ether * rewards.weightOf(bob, epoch) / supply);
        assertApproxEqAbs(paidAlice, 3 * paidBob, 3, "three times the bag, three times the share");
        assertEq(imd.balanceOf(alice), paidAlice);
    }

    function test_lastSecondBuyerCannotSnipeTheEpochsPot() public {
        // The scenario from the review: fees sit unharvested, a sniper buys one second before the epoch ends,
        // harvests, sells right after the boundary and claims. With fees credited to the epoch of the trade and
        // weights by average balance, the sniper earns one 86,400th of a day's weight on its bag.
        vm.warp(1_000 * 1 days);
        seedBalanced(1_000_000 ether);
        token.transfer(alice, 30_000_000 ether);
        token.transfer(address(manager), token.balanceOf(address(this)) - 30_000_000 ether);
        buy(-10_000 ether); // the day's trading, unharvested
        uint256 dayFees = hook.pendingFees();
        uint256 epoch = rewards.currentEpoch();

        address sniper = address(0x5141);
        vm.warp((epoch + 1) * 1 days - 1);
        token.transfer(sniper, 30_000_000 ether); // the sniper's buy, for simplicity a transfer
        vm.prank(sniper);
        hook.harvest();
        vm.warp((epoch + 1) * 1 days);
        vm.prank(sniper);
        token.transfer(address(this), 30_000_000 ether); // and the sell
        vm.warp((epoch + 1) * 1 days + 1);

        uint256[] memory list = new uint256[](1);
        list[0] = epoch;
        vm.prank(sniper);
        uint256 paidSniper = rewards.claim(sniper, list);
        vm.prank(alice);
        uint256 paidAlice = rewards.claim(alice, list);
        assertLt(paidSniper * 10_000, dayFees, "the sniper gets far less than 1% of the pot");
        // Same bag as alice, held for one second of 86,400: one 86,400th of her share (rounding aside).
        assertApproxEqRel(paidSniper * 86_400, paidAlice, 1e15, "the sniper earns one second's worth");
        assertGt(paidAlice * 10, dayFees, "alice, with 30M of ~160M eligible all day, earns well over 10%");
    }
}
