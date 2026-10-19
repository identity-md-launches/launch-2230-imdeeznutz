// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeezToken} from "../src/DeezToken.sol";
import {DeezRewards} from "../src/DeezRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";

/// @dev Stands in for the swarm's Merkle distributor or any other contract that holds $DEEZ and cannot claim.
contract HoldingContract {}

/// @notice Unit tests of the distributor alone, with a stand-in pool manager address and a mock hook.
contract DeezRewardsTest is Test {
    uint256 constant EPOCH = 1 days;
    uint256 constant SUPPLY = 1e27;

    DeezToken token;
    MockERC20 imd;
    DeezRewards rewards;
    MockHook mockHook;

    address poolManager = address(0x9001);
    address hook;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address dead = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(100 * EPOCH); // the first second of epoch 100: everything below holds for the whole epoch
        token = new DeezToken(address(this));
        imd = new MockERC20("IMD", "IMD", 0);
        mockHook = new MockHook();
        hook = address(mockHook);
        rewards = new DeezRewards(address(token), address(imd), poolManager, address(this));
        mockHook.init(imd, rewards);
        rewards.setHook(hook);
    }

    function fund(uint256 amount) internal {
        imd.mint(address(rewards), amount);
        rewards.accrue();
    }

    /// @dev Transfer `amount` of $IMD in and credit it to `epoch` the way the hook does after a harvest.
    function creditAsHook(uint256 epoch, uint256 amount) internal {
        imd.mint(address(rewards), amount);
        vm.prank(hook);
        rewards.credit(epoch, amount);
    }

    function epochs(uint256 e) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = e;
    }

    function claimAs(address account, uint256 e) internal returns (uint256) {
        vm.prank(account);
        return rewards.claim(account, epochs(e));
    }

    /// @dev The supply that earns: everything but the five excluded holders (this test is the launcher).
    function eligible() internal view returns (uint256) {
        return SUPPLY - token.balanceOf(poolManager) - token.balanceOf(dead) - token.balanceOf(hook)
            - token.balanceOf(address(rewards)) - token.balanceOf(address(this));
    }

    function test_constructorRefusesZeroAddresses() public {
        vm.expectRevert(DeezRewards.ZeroAddress.selector);
        new DeezRewards(address(0), address(imd), poolManager, address(this));
        vm.expectRevert(DeezRewards.ZeroAddress.selector);
        new DeezRewards(address(token), address(imd), poolManager, address(0));
        vm.expectRevert(DeezRewards.ZeroAddress.selector);
        new DeezRewards(address(token), address(0), poolManager, address(this));
    }

    function test_epochArithmetic() public view {
        assertEq(rewards.currentEpoch(), 100);
        assertEq(rewards.snapshotOf(100), 101 * EPOCH - 1);
        assertFalse(rewards.hasEnded(100));
        assertTrue(rewards.hasEnded(99));
        assertEq(rewards.EPOCH_LENGTH(), 1 days);
        assertEq(rewards.EPOCH_LENGTH(), token.CUMULATIVE_UNIT(), "an epoch weight is an average balance");
        assertEq(rewards.CLAIM_WINDOW(), 90);
    }

    function test_excludedAddresses() public view {
        assertTrue(rewards.isExcluded(poolManager));
        assertTrue(rewards.isExcluded(hook));
        assertTrue(rewards.isExcluded(dead));
        assertTrue(rewards.isExcluded(address(rewards)));
        assertTrue(rewards.isExcluded(address(this)), "the launcher is excluded");
        assertEq(rewards.launcher(), address(this));
        assertTrue(rewards.isExcluded(address(0)));
        assertFalse(rewards.isExcluded(alice));
    }

    function test_accrueCreditsTheCurrentEpochOnce() public {
        imd.mint(address(rewards), 1_000 ether);
        assertEq(rewards.accrue(), 1_000 ether);
        assertEq(rewards.accrue(), 0, "nothing new");
        (uint128 total,,,) = rewards.pots(100);
        assertEq(total, 1_000 ether);
        assertEq(rewards.reserved(), 1_000 ether);
    }

    function test_claimsAreProportionalToTheAverageBalance() public {
        token.transfer(alice, 300 ether);
        token.transfer(bob, 100 ether);
        token.transfer(poolManager, 500_000_000 ether); // the pool's share earns nothing
        token.transfer(dead, 1_000 ether);
        token.transfer(hook, 7 ether);
        fund(1_000 ether);
        uint256 supply = eligible();

        vm.warp(101 * EPOCH); // epoch 100 just ended
        assertTrue(rewards.hasEnded(100));
        assertEq(rewards.eligibleSupplyAt(100), supply, "held all epoch: the average is the balance");
        assertEq(rewards.weightOf(alice, 100), 300 ether);

        uint256 expectedAlice = 1_000 ether * 300 ether / supply;
        uint256 expectedBob = 1_000 ether * 100 ether / supply;
        assertEq(rewards.claimable(alice, 100), expectedAlice);
        assertEq(rewards.claimable(bob, 100), expectedBob);
        assertEq(rewards.claimable(poolManager, 100), 0);

        assertEq(claimAs(alice, 100), expectedAlice);
        assertEq(imd.balanceOf(alice), expectedAlice);
        assertEq(claimAs(bob, 100), expectedBob);
        assertEq(expectedAlice, 3 * expectedBob, "three times the bag, three times the share");
        (,, uint256 storedSupply,) = rewards.pots(100);
        assertEq(storedSupply, supply, "finalized on first claim");
        assertEq(rewards.reserved(), 1_000 ether - expectedAlice - expectedBob);
    }

    function test_onlyTheAccountItselfCanClaim() public {
        HoldingContract dist = new HoldingContract();
        token.transfer(address(dist), 100_000_000 ether); // the swarm's 10%, in a contract that cannot claim
        token.transfer(alice, 900_000_000 ether);
        fund(1_000 ether);
        vm.warp(102 * EPOCH);

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.NotAccount.selector, address(dist)));
        rewards.claim(address(dist), epochs(100));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.NotAccount.selector, alice));
        rewards.claim(alice, epochs(100));
        assertEq(imd.balanceOf(address(dist)), 0, "nothing was pushed into the contract");

        // The share stays claimable by the account alone, and anything never claimed is recycled to holders.
        assertEq(rewards.claimable(address(dist), 100), 100 ether);
        assertEq(claimAs(alice, 100), 900 ether);
        vm.warp((100 + 90 + 1) * EPOCH);
        assertEq(rewards.recycle(100), 100 ether, "the unclaimed 10% goes back to the holders");
    }

    function test_rewardsAreWeightedByHoldingTime() public {
        // alice holds 100 all day; carol holds 100 until one second before the day ends, when bob buys it and
        // sells it back right after the day ended.
        token.transfer(alice, 100 ether);
        token.transfer(carol, 100 ether);
        token.transfer(poolManager, SUPPLY - 200 ether);
        fund(1_000 ether);
        vm.warp(101 * EPOCH - 1);
        vm.prank(carol);
        token.transfer(bob, 100 ether);
        vm.warp(101 * EPOCH);
        vm.prank(bob);
        token.transfer(carol, 100 ether);

        uint256 aliceWeight = 100 ether;
        uint256 bobWeight = 100 ether * 1 / EPOCH; // one second of 86,400
        assertEq(rewards.weightOf(alice, 100), aliceWeight);
        assertEq(rewards.weightOf(bob, 100), bobWeight);
        // carol held the other 100 for all but one second.
        uint256 carolWeight = 100 ether * (EPOCH - 1) / EPOCH;
        assertEq(rewards.weightOf(carol, 100), carolWeight);
        uint256 supply = rewards.eligibleSupplyAt(100);
        assertEq(supply, 200 ether);

        assertEq(claimAs(alice, 100), 1_000 ether * aliceWeight / supply);
        assertEq(claimAs(bob, 100), 1_000 ether * bobWeight / supply);
        assertLt(imd.balanceOf(bob), 0.01 ether, "a one-second holder earns one 86,400th of a day's weight");
        assertApproxEqAbs(imd.balanceOf(alice), 500 ether, 1, "the all-day holder earns its full half");
    }

    function test_launcherHoldingNeitherEarnsNorDilutes() public {
        // The launcher (this test) keeps 250,000,000 all epoch, as `DeezLaunch` keeps the whole supply between
        // the factory transaction and `launch`. It cannot claim, so its holding must not count: alice, the only
        // eligible holder, gets the whole pot instead of half of it.
        token.transfer(alice, 250_000_000 ether);
        token.transfer(poolManager, 500_000_000 ether);
        fund(100 ether);
        vm.warp(101 * EPOCH);
        assertEq(rewards.weightOf(address(this), 100), 250_000_000 ether, "the launcher's weight is still readable");
        assertEq(rewards.eligibleSupplyAt(100), 250_000_000 ether, "but it is not eligible supply");
        assertEq(rewards.claimable(address(this), 100), 0);
        assertEq(rewards.claimable(alice, 100), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, address(this)));
        rewards.claim(address(this), epochs(100));
        assertEq(claimAs(alice, 100), 100 ether, "the whole pot goes to the holders who can claim");
        assertEq(rewards.reserved(), 0, "nothing is left stranded for the launcher");
    }

    function test_launcherHoldingBeforeALateLaunchDoesNotDiluteTheLaunchDay() public {
        // The factory transaction is at 01:00 of epoch 100 (`setUp` is at 00:00; the supply sits here either
        // way) and the launch at 12:00: the launcher held everything for half the day, then alice (the only
        // eligible holder) for the other half, so the day's pot is hers alone.
        vm.warp(100 * EPOCH + 12 hours);
        token.transfer(alice, 20_000_000 ether);
        token.transfer(poolManager, SUPPLY - 20_000_000 ether);
        creditAsHook(100, 2 ether);
        vm.warp(101 * EPOCH + 1);
        assertEq(rewards.weightOf(address(this), 100), SUPPLY / 2);
        assertEq(rewards.eligibleSupplyAt(100), 10_000_000 ether, "alice's average: 20,000,000 for half a day");
        assertEq(rewards.claimable(alice, 100), 2 ether);
        assertEq(claimAs(alice, 100), 2 ether);
    }

    function test_balanceMovedAfterTheEpochDoesNotChangeIt() public {
        token.transfer(alice, 100 ether);
        fund(100 ether);
        vm.warp(101 * EPOCH);
        vm.prank(alice);
        token.transfer(carol, 100 ether); // moved in epoch 101
        uint256 supply = eligible();
        assertEq(rewards.claimable(alice, 100), 100 ether * 100 ether / supply);
        assertEq(rewards.claimable(carol, 100), 0);
        // Epoch 101's rewards go to carol.
        fund(100 ether);
        vm.warp(102 * EPOCH);
        assertEq(rewards.claimable(alice, 101), 0);
        assertEq(rewards.claimable(carol, 101), 100 ether * 100 ether / supply);
    }

    function test_creditGoesToTheEpochTheHookNames() public {
        token.transfer(alice, 100 ether);
        vm.warp(103 * EPOCH);
        creditAsHook(100, 60 ether);
        creditAsHook(101, 40 ether);
        (uint128 pot100,,,) = rewards.pots(100);
        (uint128 pot101,,,) = rewards.pots(101);
        (uint128 pot103,,,) = rewards.pots(103);
        assertEq(pot100, 60 ether);
        assertEq(pot101, 40 ether);
        assertEq(pot103, 0);
        assertEq(rewards.reserved(), 100 ether);
        assertEq(rewards.accrue(), 0, "credited money is not accrued twice");
    }

    function test_creditRefusesOthersAndUnfundedAmounts() public {
        imd.mint(address(rewards), 10 ether);
        vm.expectRevert(DeezRewards.NotHook.selector);
        rewards.credit(100, 10 ether);
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Unfunded.selector, 11 ether, 10 ether));
        rewards.credit(100, 11 ether);
        vm.prank(hook);
        rewards.credit(100, 10 ether);
        (uint128 pot,,,) = rewards.pots(100);
        assertEq(pot, 10 ether);
    }

    function test_creditToAClosedOrFutureEpochGoesToTheCurrentOne() public {
        token.transfer(alice, 100 ether);
        vm.warp((100 + 90 + 1) * EPOCH);
        rewards.recycle(100); // closes the empty pot
        creditAsHook(100, 5 ether);
        creditAsHook(500, 5 ether);
        (uint128 now_,,,) = rewards.pots(rewards.currentEpoch());
        assertEq(now_, 10 ether);
    }

    function test_claimBeforeTheEpochEndsReverts() public {
        token.transfer(alice, 100 ether);
        fund(100 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochNotEnded.selector, 100));
        rewards.claim(alice, epochs(100));
        assertEq(rewards.claimable(alice, 100), 0);
    }

    function test_doubleClaimPaysNothingMore() public {
        token.transfer(alice, 100 ether);
        token.transfer(bob, 100 ether);
        fund(100 ether);
        vm.warp(101 * EPOCH);
        uint256 paid = claimAs(alice, 100);
        assertEq(rewards.paidOf(100, alice), paid);
        assertEq(rewards.claimable(alice, 100), 0, "nothing left for alice");
        vm.prank(alice);
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(alice, epochs(100));
        // The same epoch twice in one batch pays it once.
        uint256[] memory twice = new uint256[](2);
        twice[0] = 100;
        twice[1] = 100;
        vm.prank(bob);
        assertEq(rewards.claim(bob, twice), paid, "same bag, same share, paid once");
        assertEq(imd.balanceOf(bob), paid);
        (, uint128 claimedAmount,,) = rewards.pots(100);
        assertEq(claimedAmount, 2 * paid);
    }

    function test_lateCreditIsPaidOnASecondClaim() public {
        // Fees of epoch 100 can reach the pot after a holder claimed it (harvested later by someone else).
        token.transfer(alice, 300 ether);
        token.transfer(bob, 100 ether);
        token.transfer(poolManager, SUPPLY - 400 ether);
        vm.warp(100 * EPOCH + 12 hours);
        creditAsHook(100, 100 ether);
        vm.warp(101 * EPOCH);
        assertEq(claimAs(alice, 100), 75 ether);
        creditAsHook(100, 100 ether); // the rest of the day's fees, harvested after alice claimed
        (uint128 total,,,) = rewards.pots(100);
        assertEq(total, 200 ether);
        assertEq(rewards.claimable(alice, 100), 75 ether, "the difference against the grown pot");
        assertEq(rewards.claimable(bob, 100), 50 ether, "bob never claimed: his whole share");
        assertEq(claimAs(alice, 100), 75 ether);
        assertEq(imd.balanceOf(alice), 150 ether, "alice ends with her share of every fee of the epoch");
        assertEq(rewards.paidOf(100, alice), 150 ether);
        assertEq(claimAs(bob, 100), 50 ether);
        assertEq(rewards.reserved(), 0);
    }

    function test_claimHarvestsThePendingFeesOfTheEpochFirst() public {
        token.transfer(alice, 300 ether);
        token.transfer(bob, 100 ether);
        token.transfer(poolManager, SUPPLY - 400 ether);
        creditAsHook(100, 100 ether); // harvested during the day
        mockHook.setPending(100, 100 ether); // traded after that harvest, still in the hook
        vm.warp(101 * EPOCH);
        assertEq(rewards.claimable(alice, 100), 150 ether, "claimable counts the unharvested fees too");
        assertEq(claimAs(alice, 100), 150 ether, "one claim pays alice's share of every fee of the epoch");
        assertEq(mockHook.harvestCalls(), 1);
        assertEq(mockHook.pendingFeesOf(100), 0);
        (uint128 total,,,) = rewards.pots(100);
        assertEq(total, 200 ether, "the pending fees were credited to the epoch by the claim");
        assertEq(rewards.claimable(alice, 100), 0);
        assertEq(claimAs(bob, 100), 50 ether);
        assertEq(rewards.reserved(), 0);
    }

    function test_claimHarvestsOnlyTheEpochsItPays() public {
        token.transfer(alice, 100 ether);
        token.transfer(poolManager, SUPPLY - 100 ether);
        mockHook.setPending(100, 10 ether);
        mockHook.setPending(101, 20 ether);
        vm.warp(102 * EPOCH);
        assertEq(claimAs(alice, 100), 10 ether);
        assertEq(mockHook.pendingFeesOf(100), 0);
        assertEq(mockHook.pendingFeesOf(101), 20 ether, "epoch 101 was not listed, so not harvested");
        assertEq(rewards.claimable(alice, 101), 20 ether);
    }

    function test_excludedAddressesCannotClaim() public {
        fund(100 ether);
        vm.warp(101 * EPOCH);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, poolManager));
        rewards.claim(poolManager, epochs(100));
        vm.prank(dead);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, dead));
        rewards.claim(dead, epochs(100));
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, hook));
        rewards.claim(hook, epochs(100));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, address(this)));
        rewards.claim(address(this), epochs(100)); // the launcher
    }

    function test_emptyClaimReverts() public {
        fund(100 ether);
        vm.warp(101 * EPOCH);
        vm.prank(alice);
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(alice, epochs(100)); // alice holds nothing
        vm.prank(alice);
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(alice, epochs(99)); // no pot
    }

    function test_claimManyEpochsAtOnce() public {
        token.transfer(alice, 500_000_000 ether);
        token.transfer(poolManager, 500_000_000 ether - 1 ether);
        // alice holds 500M of 500M + 1 eligible: close to everything.
        fund(100 ether);
        vm.warp(101 * EPOCH);
        fund(200 ether);
        vm.warp(102 * EPOCH);
        fund(300 ether);
        vm.warp(103 * EPOCH + 10);
        uint256[] memory list = new uint256[](3);
        list[0] = 100;
        list[1] = 101;
        list[2] = 102;
        uint256 expected = rewards.claimableMany(alice, list);
        assertApproxEqRel(expected, 600 ether, 1e12);
        vm.prank(alice);
        assertEq(rewards.claim(alice, list), expected);
        assertEq(imd.balanceOf(alice), expected);
    }

    function test_recycleFoldsUnclaimedIntoTheCurrentEpoch() public {
        token.transfer(alice, 500_000_000 ether);
        token.transfer(bob, 500_000_000 ether - 1 ether);
        fund(100 ether);
        vm.warp(101 * EPOCH);
        claimAs(alice, 100);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.ClaimWindowOpen.selector, 100));
        rewards.recycle(100);

        vm.warp((100 + 90 + 1) * EPOCH);
        uint256 remainder = rewards.recycle(100);
        assertGt(remainder, 0);
        (uint128 total, uint128 claimedAmount,, bool closed) = rewards.pots(100);
        assertTrue(closed);
        assertEq(remainder, total - claimedAmount);
        (uint128 nowTotal,,,) = rewards.pots(rewards.currentEpoch());
        assertEq(nowTotal, remainder, "credited to the current epoch");
        assertEq(rewards.claimable(bob, 100), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochClosed.selector, 100));
        rewards.claim(bob, epochs(100));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochClosed.selector, 100));
        rewards.recycle(100);
        // Bob can still claim the recycled epoch like any other once it ends.
        vm.warp((100 + 90 + 2) * EPOCH);
        assertGt(claimAs(bob, 100 + 90 + 1), 0);
    }

    function test_finalizeRequiresAnEndedEpoch() public {
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochNotEnded.selector, 100));
        rewards.finalize(100);
        vm.warp(101 * EPOCH);
        assertEq(rewards.finalize(100), eligible());
        assertEq(rewards.finalize(100), eligible(), "idempotent");
    }

    function testFuzz_claimsNeverExceedThePotAndSplitByBalance(uint96 a, uint96 b, uint96 pot) public {
        a = uint96(bound(a, 1 ether, 1e26));
        b = uint96(bound(b, 1 ether, 1e26));
        pot = uint96(bound(pot, 1 ether, 1e24));
        token.transfer(alice, a);
        token.transfer(bob, b);
        token.transfer(poolManager, SUPPLY - uint256(a) - b); // only alice and bob are eligible
        fund(pot);
        vm.warp(101 * EPOCH);
        uint256 supply = uint256(a) + b;
        assertEq(rewards.eligibleSupplyAt(100), supply);
        uint256 paidA = claimAs(alice, 100);
        uint256 paidB = claimAs(bob, 100);
        assertEq(paidA, uint256(pot) * a / supply);
        assertEq(paidB, uint256(pot) * b / supply);
        assertLe(paidA + paidB, pot, "never pays more than the pot");
        assertGe(paidA + paidB + 2, pot, "at most rounding dust stays");
        assertEq(imd.balanceOf(address(rewards)), uint256(pot) - paidA - paidB);
    }

    function testFuzz_claimsNeverExceedThePotWithMidEpochMoves(uint96 a, uint32 t1, uint32 t2, uint96 pot) public {
        // Balances move at arbitrary seconds inside the epoch; the sum of every claim never exceeds the pot.
        a = uint96(bound(a, 1 ether, 1e26));
        t1 = uint32(bound(t1, 1, EPOCH - 2));
        t2 = uint32(bound(t2, t1 + 1, EPOCH - 1));
        pot = uint96(bound(pot, 1 ether, 1e24));
        token.transfer(poolManager, SUPPLY - 3 * uint256(a));
        token.transfer(alice, a);
        token.transfer(carol, a);
        fund(pot);
        vm.warp(100 * EPOCH + t1);
        token.transfer(bob, a); // the launcher's last tokens leave mid-epoch
        vm.warp(100 * EPOCH + t2);
        vm.prank(alice);
        token.transfer(carol, a / 2);
        vm.warp(101 * EPOCH);
        uint256 paid = claimAs(alice, 100) + claimAs(bob, 100) + claimAs(carol, 100);
        assertLe(paid, pot, "never pays more than the pot");
        // Each weight is floored to a wei-day per checkpoint segment; at pot / supply <= 1e6 that is < 1e7 wei.
        assertGe(paid + 1e7, pot, "at most rounding dust stays");
    }
}
