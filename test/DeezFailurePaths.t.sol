// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeezBase} from "./DeezBase.t.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {DeezToken} from "../src/DeezToken.sol";
import {DeezHook} from "../src/DeezHook.sol";
import {DeezRewards} from "../src/DeezRewards.sol";
import {DeezLiquidityLock} from "../src/DeezLiquidityLock.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";

/// @notice Edges and refusals of the distributor: window boundaries, batches that mix good and bad epochs,
/// time-weighted balances at the epoch edges, empty eligible supply, rounding to zero, who may claim.
/// Setup mints at the first second of epoch START, so a balance held from setup on weighs exactly itself.
contract DeezRewardsFailurePathsTest is Test {
    uint256 constant EPOCH = 1 days;
    uint256 constant START = 100;

    DeezToken token;
    MockERC20 imd;
    DeezRewards rewards;
    address poolManager = address(0x9001);
    MockHook mockHook;
    address hookAddr;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(START * EPOCH);
        token = new DeezToken(address(this));
        imd = new MockERC20("IMD", "IMD", 0);
        mockHook = new MockHook();
        hookAddr = address(mockHook);
        rewards = new DeezRewards(address(token), address(imd), poolManager, address(this));
        mockHook.init(imd, rewards);
        rewards.setHook(hookAddr);
        token.transfer(poolManager, 900_000_000 ether);
        token.transfer(alice, 75_000_000 ether);
        token.transfer(bob, 25_000_000 ether);
    }

    function fund(uint256 amount) internal {
        imd.mint(address(rewards), amount);
        rewards.accrue();
    }

    function one(uint256 e) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = e;
    }

    function two(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = a;
        list[1] = b;
    }

    function nextEpoch() internal {
        vm.warp((rewards.currentEpoch() + 1) * EPOCH + 1);
    }

    function claimAs(address account, uint256[] memory epochs) internal returns (uint256) {
        vm.prank(account);
        return rewards.claim(account, epochs);
    }

    function test_accrueWithNothingNewCreditsNothing() public {
        assertEq(rewards.accrue(), 0);
        fund(1 ether);
        assertEq(rewards.accrue(), 0, "the same balance is never credited twice");
        (uint128 total,,,) = rewards.pots(START);
        assertEq(total, 1 ether);
        assertEq(rewards.reserved(), 1 ether);
    }

    function test_nobodyCanClaimForSomeoneElse() public {
        fund(100 ether);
        nextEpoch();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.NotAccount.selector, alice));
        rewards.claim(alice, one(START));
        // Not even the hook or the pool.
        vm.prank(hookAddr);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.NotAccount.selector, alice));
        rewards.claim(alice, one(START));
        assertEq(rewards.paidOf(START, alice), 0);
        assertEq(claimAs(alice, one(START)), 75 ether);
        assertEq(imd.balanceOf(alice), 75 ether);
        assertEq(imd.balanceOf(bob), 0);
    }

    function test_excludedAddressesCannotClaimEvenForThemselves() public {
        fund(100 ether);
        nextEpoch();
        address[5] memory excluded = [poolManager, rewards.BURN_ADDRESS(), hookAddr, address(rewards), address(this)];
        for (uint256 i = 0; i < excluded.length; i++) {
            vm.prank(excluded[i]);
            vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, excluded[i]));
            rewards.claim(excluded[i], one(START));
            assertEq(rewards.claimable(excluded[i], START), 0);
        }
        assertEq(rewards.claimable(poolManager, START), 0, "the pool's 90% earns nothing");
    }

    function test_duplicateEpochInOneBatchPaysItOnce() public {
        fund(100 ether);
        nextEpoch();
        assertEq(claimAs(alice, two(START, START)), 75 ether, "the repeat pays the difference, which is zero");
        assertEq(imd.balanceOf(alice), 75 ether);
        assertEq(rewards.paidOf(START, alice), 75 ether);
        vm.prank(alice);
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(alice, one(START));
        assertEq(rewards.claimable(alice, START), 0);
    }

    function test_lateFeeAfterSomeClaimedStillSplitsExactlyByBalance() public {
        fund(100 ether);
        nextEpoch();
        assertEq(claimAs(alice, one(START)), 75 ether);
        // 40 IMD of fees traded in START were still unharvested when alice claimed.
        mockHook.setPending(START, 40 ether);
        assertEq(rewards.claimable(alice, START), 30 ether, "the view counts unharvested fees");
        assertEq(rewards.claimable(bob, START), 35 ether);
        assertEq(claimAs(bob, one(START)), 35 ether, "bob's claim harvests and pays 25% of 140");
        assertEq(mockHook.pendingFeesOf(START), 0);
        assertEq(claimAs(alice, one(START)), 30 ether, "alice is topped up to 75% of 140");
        (uint128 total, uint128 claimed,,) = rewards.pots(START);
        assertEq(total, 140 ether);
        assertEq(claimed, 140 ether);
        assertEq(rewards.reserved(), 0);
        assertEq(imd.balanceOf(address(rewards)), 0);
    }

    function test_pendingFeesOfAClosedEpochGoToTheCurrentPot() public {
        fund(100 ether);
        vm.warp((START + rewards.CLAIM_WINDOW() + 1) * EPOCH);
        rewards.recycle(START);
        mockHook.setPending(START, 10 ether);
        assertEq(rewards.claimable(alice, START), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochClosed.selector, START));
        rewards.claim(alice, one(START));
        assertEq(mockHook.pendingFeesOf(START), 10 ether, "the reverted claim harvested nothing");
        mockHook.harvestEpochs(one(START));
        (uint128 current,,,) = rewards.pots(rewards.currentEpoch());
        assertEq(current, 110 ether, "recycled 100 plus the late 10, owned by the current epoch's holders");
        (uint128 closedTotal,,, bool closed) = rewards.pots(START);
        assertTrue(closed);
        assertEq(closedTotal, 100 ether, "the closed pot takes nothing");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_claimOrderAndLateFeesDoNotChangeFinalShares(
        uint96 a,
        uint128 early,
        uint128 late,
        uint8 order,
        uint32 moveAt
    ) public {
        address c = address(0xCA201);
        vm.warp(START * EPOCH + bound(moveAt, 0, EPOCH - 1));
        vm.prank(alice);
        token.transfer(c, bound(a, 0, 75_000_000 ether));
        uint256 p1 = bound(early, 0, 1e30);
        uint256 p2 = bound(late, 0, 1e30);
        if (p1 > 0) fund(p1);
        nextEpoch();
        address[3] memory holders = [alice, bob, c];
        // A random subset claims before the late fees are known.
        for (uint256 i = 0; i < 3; i++) {
            if ((order >> i) & 1 == 1 && rewards.claimable(holders[i], START) > 0) claimAs(holders[i], one(START));
        }
        mockHook.setPending(START, p2);
        for (uint256 i = 0; i < 3; i++) {
            if (rewards.claimable(holders[i], START) > 0) claimAs(holders[i], one(START));
        }
        // A fee too small to pay anyone a wei is never pulled in by a claim; anyone may still harvest it.
        mockHook.harvestEpochs(one(START));
        uint256 supply = rewards.eligibleSupplyAt(START);
        uint256 paid;
        for (uint256 i = 0; i < 3; i++) {
            uint256 expected = (p1 + p2) * rewards.weightOf(holders[i], START) / supply;
            assertEq(rewards.paidOf(START, holders[i]), expected, "final share is the full-pot share");
            assertEq(imd.balanceOf(holders[i]), expected);
            paid += expected;
        }
        assertLe(paid, p1 + p2);
        (uint128 total, uint128 claimed,,) = rewards.pots(START);
        assertEq(total, p1 + p2);
        assertEq(claimed, paid);
        assertEq(imd.balanceOf(address(rewards)), p1 + p2 - paid);
    }

    function test_batchWithAnUnendedEpochPaysNothing() public {
        fund(100 ether);
        nextEpoch();
        uint256 current = rewards.currentEpoch();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochNotEnded.selector, current));
        rewards.claim(alice, two(START, current));
        assertEq(imd.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochNotEnded.selector, current + 1000));
        rewards.claim(alice, one(current + 1000));
    }

    function test_emptyBatchReverts() public {
        fund(100 ether);
        nextEpoch();
        vm.prank(alice);
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(alice, new uint256[](0));
    }

    function test_holderWithNoBalanceInTheEpochHasNothingToClaim() public {
        fund(100 ether);
        nextEpoch();
        address nobody = address(0xC0FFEE);
        vm.prank(nobody);
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(nobody, one(START));
        assertEq(rewards.claimable(nobody, START), 0);
    }

    function test_shareThatRoundsToZeroIsRefusedNotPaid() public {
        // One wei of DEEZ against a 1 wei pot: 1 * 1 / 100M ether rounds to zero.
        vm.prank(alice);
        token.transfer(address(0xD00D), 1);
        fund(1);
        nextEpoch();
        assertEq(rewards.claimable(address(0xD00D), START), 0);
        vm.prank(address(0xD00D));
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(address(0xD00D), one(START));
    }

    function test_epochWithNoEligibleSupplyPaysNobodyAndIsRecycled() public {
        vm.prank(alice);
        token.transfer(poolManager, 75_000_000 ether);
        address burn = rewards.BURN_ADDRESS();
        vm.prank(bob);
        token.transfer(burn, 25_000_000 ether);
        fund(10 ether);
        nextEpoch();
        assertEq(rewards.eligibleSupplyAt(START), 0);
        assertEq(rewards.claimable(alice, START), 0);
        vm.prank(alice);
        vm.expectRevert(DeezRewards.NothingToClaim.selector);
        rewards.claim(alice, one(START));
        vm.warp((START + rewards.CLAIM_WINDOW() + 1) * EPOCH);
        assertEq(rewards.recycle(START), 10 ether, "the stranded pot comes back");
        (uint128 total,,,) = rewards.pots(rewards.currentEpoch());
        assertEq(total, 10 ether);
        assertEq(rewards.reserved(), 10 ether);
    }

    function test_recycleOpensExactlyAfterTheClaimWindow() public {
        fund(100 ether);
        uint256 window = rewards.CLAIM_WINDOW();
        vm.warp((START + window) * EPOCH + EPOCH - 1); // last second of epoch START + window
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.ClaimWindowOpen.selector, START));
        rewards.recycle(START);
        // Still claimable on the last second of the window.
        assertEq(claimAs(bob, one(START)), 25 ether);
        vm.warp((START + window + 1) * EPOCH);
        assertEq(rewards.recycle(START), 75 ether);
    }

    function test_recycleOfAnEpochThatNeverHadAPotClosesItForNothing() public {
        vm.warp((START + rewards.CLAIM_WINDOW() + 1) * EPOCH);
        assertEq(rewards.recycle(START), 0);
        (,,, bool closed) = rewards.pots(START);
        assertTrue(closed);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochClosed.selector, START));
        rewards.recycle(START);
    }

    function test_closedEpochRefusesClaimsAndASecondRecycle() public {
        fund(100 ether);
        vm.warp((START + rewards.CLAIM_WINDOW() + 1) * EPOCH);
        rewards.recycle(START);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochClosed.selector, START));
        rewards.claim(alice, one(START));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochClosed.selector, START));
        rewards.recycle(START);
        assertEq(rewards.claimable(alice, START), 0);
    }

    function test_recycledRewardsArePaidByTheNewEpochsBalances() public {
        fund(100 ether);
        uint256 into = START + rewards.CLAIM_WINDOW() + 1;
        vm.warp(into * EPOCH);
        // Alice sold everything to the pool in the first second of the new epoch.
        vm.prank(alice);
        token.transfer(poolManager, 75_000_000 ether);
        rewards.recycle(START);
        nextEpoch();
        assertEq(claimAs(bob, one(into)), 100 ether, "bob is now the only eligible holder");
        assertEq(rewards.claimable(alice, into), 0);
    }

    function test_lastSecondBuyerWeighsOneSecond() public {
        fund(86_400 ether);
        address sniper = address(0x5419E7);
        vm.warp(rewards.snapshotOf(START));
        vm.prank(alice);
        token.transfer(sniper, 25_000_000 ether); // held for the last second of the epoch only
        nextEpoch();
        // weight = 25M / 86400 of 100M eligible: 86400 ether * (25M / 86400) / 100M = 0.25 ether.
        assertEq(rewards.weightOf(sniper, START), uint256(25_000_000 ether) / EPOCH);
        assertApproxEqAbs(claimAs(sniper, one(START)), 0.25 ether, 1, "one second of 25M is 1/86400 of it");
        assertApproxEqAbs(claimAs(alice, one(START)), 64_800 ether - 0.25 ether, 1);
        assertEq(claimAs(bob, one(START)), 21_600 ether);
    }

    function test_balanceMovedInTheFirstSecondOfTheNextEpochDoesNotCount() public {
        fund(100 ether);
        vm.warp(rewards.snapshotOf(START) + 1);
        vm.prank(bob);
        token.transfer(alice, 25_000_000 ether);
        assertEq(claimAs(alice, one(START)), 75 ether);
        assertEq(claimAs(bob, one(START)), 25 ether);
    }

    function test_weightReadsRevertUntilTheEpochHasEnded() public {
        fund(100 ether);
        vm.expectRevert();
        rewards.weightOf(alice, START);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochNotEnded.selector, START));
        rewards.finalize(START);
        assertEq(rewards.claimable(alice, START), 0, "the view reports zero instead of reverting");
        vm.warp(rewards.snapshotOf(START) + 1);
        assertEq(rewards.weightOf(alice, START), 75_000_000 ether);
    }

    function test_unaccruedDonationGoesToTheCurrentEpochNotAnEndedOne() public {
        fund(100 ether);
        nextEpoch();
        imd.mint(address(rewards), 40 ether); // nobody called accrue
        assertEq(claimAs(alice, one(START)), 75 ether, "the ended pot is unchanged");
        (uint128 current,,,) = rewards.pots(rewards.currentEpoch());
        assertEq(current, 40 ether);
        assertEq(rewards.reserved(), 25 ether + 40 ether);
    }

    function test_finalizeIsIdempotentAndIgnoresLaterTransfers() public {
        fund(100 ether);
        nextEpoch();
        uint256 supply = rewards.finalize(START);
        assertEq(supply, 100_000_000 ether);
        vm.prank(alice);
        token.transfer(poolManager, 75_000_000 ether);
        assertEq(rewards.finalize(START), supply);
        assertEq(rewards.eligibleSupplyAt(START), supply);
    }

    function test_creditCannotBeForgedOrOverdrawn() public {
        vm.expectRevert(DeezRewards.NotHook.selector);
        rewards.credit(START, 0);
        imd.mint(address(rewards), 5 ether);
        rewards.accrue(); // already reserved: not available to credit again
        vm.prank(hookAddr);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Unfunded.selector, 1, 0));
        rewards.credit(START, 1);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_allHoldersTogetherNeverDrainMoreThanThePot(
        uint96 a,
        uint96 b,
        uint128 pot,
        uint32 when,
        uint32 moveAt
    ) public {
        uint256 amountA = bound(a, 0, 75_000_000 ether);
        uint256 amountB = bound(b, 0, 25_000_000 ether);
        address c = address(0xCA201);
        // Moves happen at a random second of the epoch, so all three weights are partial averages.
        vm.warp(START * EPOCH + bound(moveAt, 0, EPOCH - 1));
        vm.prank(alice);
        token.transfer(c, amountA);
        vm.prank(bob);
        token.transfer(c, amountB);
        uint256 funded = bound(pot, 1, 1e30);
        vm.warp(block.timestamp + bound(when, 0, START * EPOCH + EPOCH - 1 - block.timestamp));
        fund(funded);
        nextEpoch();
        address[3] memory holders = [alice, bob, c];
        uint256 paid;
        for (uint256 i = 0; i < 3; i++) {
            uint256 expected = rewards.claimable(holders[i], START);
            if (expected == 0) continue;
            assertEq(claimAs(holders[i], one(START)), expected);
            paid += expected;
        }
        assertLe(paid, funded);
        // Each weight is floored once per balance segment, so the weights sum a few wei under the eligible
        // supply; what that leaves is a few wei of the pot per wei of supply, and stays recyclable.
        uint256 supply = rewards.eligibleSupplyAt(START);
        assertLe(funded - paid, 3 + funded * 8 / supply, "only weight rounding is left behind");
        assertEq(imd.balanceOf(address(rewards)), funded - paid);
    }
}

/// @notice Refusals and edges of the hook and the lock on a live pool.
abstract contract DeezHookFailurePaths is DeezBase {
    function test_unlockCallbacksRefuseEveryoneButThePoolManager() public {
        vm.expectRevert(DeezHook.NotPoolManager.selector);
        hook.unlockCallback("");
        DeezLiquidityLock lock = hook.liquidityLock();
        vm.expectRevert(DeezLiquidityLock.NotPoolManager.selector);
        lock.unlockCallback(abi.encode(key, int24(-60), int24(60), uint128(1)));
    }

    function test_swapCallbacksRefuseAnyOtherPoolKey() public {
        PoolKey memory other = key;
        other.fee = 3000;
        SwapParams memory params = SwapParams(true, -1 ether, 0);
        vm.startPrank(address(manager));
        vm.expectRevert(DeezHook.WrongPool.selector);
        hook.beforeSwap(address(this), other, params, "");
        vm.expectRevert(DeezHook.WrongPool.selector);
        hook.afterSwap(address(this), other, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    function test_hookCallbacksRefuseBeforeInitialization() public {
        DeezHook fresh = DeezHook(deployHook(manager, address(token), address(imd)));
        assertFalse(fresh.initialized());
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        vm.prank(address(manager));
        vm.expectRevert(DeezHook.WrongPool.selector);
        fresh.beforeSwap(address(this), k, SwapParams(true, -1 ether, 0), "");
        DeezLiquidityLock freshLock = fresh.liquidityLock();
        vm.expectRevert(DeezLiquidityLock.PoolNotInitialized.selector);
        freshLock.lock();
    }

    function test_dustSwapsTradeWithoutAFee() public {
        seedBalanced(1_000_000 ether);
        buy(-49); // 49 * 2% rounds to zero
        sell(-1);
        assertEq(hook.pendingFees(), 0);
        assertEq(hookClaims(), 0);
        assertEq(hook.harvest(), 0);
    }

    function test_harvestTwiceMovesTheFeesOnce() public {
        seedBalanced(1_000_000 ether);
        buy(-1_000 ether);
        uint256 fee = hook.pendingFees();
        assertEq(hook.harvest(), fee);
        assertEq(hook.harvest(), 0);
        assertEq(hook.totalHarvested(), fee);
        assertEq(imd.balanceOf(address(rewards)), fee);
        assertEq(rewards.reserved(), fee);
        assertEq(hookClaims(), 0);
    }

    function test_claimThatRevertsLeavesTheHooksFeesUntouched() public {
        vm.warp(2_000 * 1 days);
        seedBalanced(1_000_000 ether);
        address holder = address(0xA11CE);
        token.transfer(holder, 100_000_000 ether);
        token.transfer(address(manager), token.balanceOf(address(this)));
        uint256 ended = rewards.currentEpoch();
        buy(-5_000 ether);
        vm.warp((ended + 1) * 1 days);
        buy(-5_000 ether);
        uint256 current = rewards.currentEpoch();
        uint256 pendingEnded = hook.pendingFeesOf(ended);
        uint256 pendingCurrent = hook.pendingFeesOf(current);
        uint256 claims = hookClaims();
        assertGt(pendingEnded, 0);
        assertGt(pendingCurrent, 0);
        uint256[] memory list = new uint256[](2);
        list[0] = ended;
        list[1] = current; // still running: the whole claim must revert, harvest included
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.EpochNotEnded.selector, current));
        rewards.claim(holder, list);
        assertEq(hook.pendingFeesOf(ended), pendingEnded);
        assertEq(hook.pendingFeesOf(current), pendingCurrent);
        assertEq(hookClaims(), claims, "no claim was burned");
        assertEq(imd.balanceOf(address(rewards)), 0);
        // The ended epoch alone pays the holder its weighted share of the day's fees, harvested by the claim
        // (the buyer of the first swap held $DEEZ all day too and shares the pot).
        uint256[] memory endedOnly = new uint256[](1);
        endedOnly[0] = ended;
        uint256 share = pendingEnded * rewards.weightOf(holder, ended) / rewards.eligibleSupplyAt(ended);
        assertGt(share, pendingEnded / 2);
        vm.prank(holder);
        assertEq(rewards.claim(holder, endedOnly), share);
        assertEq(hook.pendingFeesOf(ended), 0);
        assertEq(hook.pendingFeesOf(current), pendingCurrent, "the running epoch's fees stay with the hook");
        assertEq(hookClaims(), claims - pendingEnded);
    }

    function test_lockSpendsAlmostEverythingAndKeepsItLocked() public {
        seedBalanced(1_000_000 ether);
        DeezLiquidityLock lock = hook.liquidityLock();
        token.transfer(address(lock), 1_000 ether);
        imd.mint(address(lock), 1_000 ether);
        lock.lock();
        // Only the 1 ppm shave (and the unmatched side, if any) can be left; whatever remains is never returned.
        assertLe(token.balanceOf(address(lock)), 1 ether);
        assertLe(imd.balanceOf(address(lock)), 1 ether);
        assertGt(lock.totalLocked0() + lock.totalLocked1(), 1_998 ether);
    }
}

contract DeezHookFailurePathsToken0Test is DeezHookFailurePaths {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract DeezHookFailurePathsToken1Test is DeezHookFailurePaths {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
