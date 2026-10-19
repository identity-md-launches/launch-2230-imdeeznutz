// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeezBase} from "./DeezBase.t.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {DeezHook} from "../src/DeezHook.sol";
import {DeezRewards} from "../src/DeezRewards.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

abstract contract DeezHookTests is DeezBase {
    uint256 constant FEE_BPS = 200;
    uint256 constant BPS = 10_000;

    // ----------------------------------------------------------- deployment

    function test_permissionsMatchTheAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
    }

    function test_constructorWiresTheDistributor() public view {
        assertEq(address(rewards.token()), address(token));
        assertEq(address(rewards.rewardToken()), address(imd));
        assertEq(rewards.poolManager(), address(manager));
        assertEq(rewards.hook(), address(hook));
        assertEq(Currency.unwrap(hook.token()), address(token));
        assertEq(Currency.unwrap(hook.pairedCurrency()), address(imd));
        assertEq(hook.tokenIsCurrency0(), tokenIsCurrency0);
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
    }

    function test_constructorRefusesZeroAndSameAddresses() public {
        IPoolManager pm = IPoolManager(address(manager));
        address r = address(rewards);
        address l = address(hook.liquidityLock());
        vm.expectRevert(DeezHook.ZeroAddress.selector);
        new DeezHook(pm, address(0), address(imd), r, l);
        vm.expectRevert(DeezHook.ZeroAddress.selector);
        new DeezHook(pm, address(token), address(0), r, l);
        vm.expectRevert(DeezHook.ZeroAddress.selector);
        new DeezHook(pm, address(token), address(imd), address(0), l);
        vm.expectRevert(DeezHook.ZeroAddress.selector);
        new DeezHook(pm, address(token), address(imd), r, address(0));
        vm.expectRevert(DeezHook.ZeroAddress.selector);
        new DeezHook(IPoolManager(address(0)), address(token), address(imd), r, l);
        vm.expectRevert(DeezHook.SameCurrency.selector);
        new DeezHook(pm, address(token), address(token), r, l);
    }

    function test_hookHasNoOwner() public {
        (bool ok,) = address(hook).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the hook exposes an owner");
        (ok,) = address(rewards).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the distributor exposes an owner");
    }

    // ------------------------------------------------------- initialization

    function test_refusesASecondPool() public {
        PoolKey memory other = key;
        other.fee = 3_000;
        vm.prank(FACTORY);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_refusesAPoolWithOtherCurrencies() public {
        DeezHook fresh = DeezHook(deployHook(manager, address(token), address(imd)));
        MockERC20 other = new MockERC20("X", "X", 0);
        (Currency c0, Currency c1) = address(token) < address(other)
            ? (Currency.wrap(address(token)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(token)));
        PoolKey memory wrong = PoolKey(c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(fresh)));
        vm.expectRevert();
        manager.initialize(wrong, SQRT_PRICE_1_1);
        assertFalse(fresh.initialized());
    }

    function test_initializesFromAnyCallerOnTheLaunchPoolOnce() public {
        DeezHook fresh = DeezHook(deployHook(manager, address(token), address(imd)));
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        vm.prank(address(0xBEEF));
        manager.initialize(k, SQRT_PRICE_1_1);
        assertTrue(fresh.initialized());
    }

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        vm.expectRevert(DeezHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(DeezHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        vm.expectRevert(DeezHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), BalanceDelta.wrap(0), "");
        vm.expectRevert(DeezHook.NotPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(DeezHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, -1, bytes32(0)), "");
        vm.expectRevert(DeezHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    // ---------------------------------------------------------------- fees

    function test_buyExactInputTakesTwoPercentOfTheImdPaid() public {
        seedBalanced(1_000_000 ether);
        uint256 amountIn = 1_000 ether;
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 deezBefore = token.balanceOf(address(swapper));
        buy(-int256(amountIn));
        assertEq(imdBefore - imd.balanceOf(address(swapper)), amountIn, "trader pays exactly the input");
        assertGt(token.balanceOf(address(swapper)), deezBefore, "trader received DEEZ");
        uint256 fee = amountIn * FEE_BPS / BPS;
        assertEq(hook.pendingFees(), fee, "fee is 2% of the input");
        assertEq(hookClaims(), fee, "fee held as an ERC-6909 claim");
    }

    function test_buyExactOutputTakesTwoPercentOfTheImdPaid() public {
        seedBalanced(1_000_000 ether);
        uint256 amountOut = 1_000 ether;
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 deezBefore = token.balanceOf(address(swapper));
        buy(int256(amountOut));
        assertEq(token.balanceOf(address(swapper)) - deezBefore, amountOut, "trader receives exactly the output");
        uint256 paid = imdBefore - imd.balanceOf(address(swapper));
        uint256 fee = hook.pendingFees();
        assertEq(fee, (paid - fee) * FEE_BPS / (BPS - FEE_BPS), "fee is 2/98 of what the pool took");
        assertApproxEqAbs(fee * BPS, paid * FEE_BPS, BPS, "fee is 2% of everything the trader paid");
        assertEq(hookClaims(), fee);
    }

    function test_sellExactInputTakesTwoPercentOfTheImdReceived() public {
        seedBalanced(1_000_000 ether);
        uint256 amountIn = 1_000 ether;
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 deezBefore = token.balanceOf(address(swapper));
        sell(-int256(amountIn));
        assertEq(deezBefore - token.balanceOf(address(swapper)), amountIn, "trader pays exactly the input");
        uint256 received = imd.balanceOf(address(swapper)) - imdBefore;
        uint256 fee = hook.pendingFees();
        assertEq(fee, (received + fee) * FEE_BPS / BPS, "fee is 2% of the gross output");
        assertEq(hookClaims(), fee);
    }

    function test_sellExactOutputTakesTwoPercentOfTheImdReceived() public {
        seedBalanced(1_000_000 ether);
        uint256 amountOut = 1_000 ether;
        uint256 imdBefore = imd.balanceOf(address(swapper));
        sell(int256(amountOut));
        assertEq(imd.balanceOf(address(swapper)) - imdBefore, amountOut, "trader receives exactly the output");
        uint256 fee = hook.pendingFees();
        assertEq(fee, amountOut * FEE_BPS / (BPS - FEE_BPS), "fee is 2/98 of the net output");
        assertApproxEqAbs(fee * BPS, (amountOut + fee) * FEE_BPS, BPS, "fee is 2% of the gross output");
        assertEq(hookClaims(), fee);
    }

    function testFuzz_buyExactInputFeeIsExact(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1e6, 1_000_000 ether));
        seedBalanced(10_000_000 ether);
        buy(-int256(uint256(amountIn)));
        assertEq(hook.pendingFees(), uint256(amountIn) * FEE_BPS / BPS);
        assertEq(hookClaims(), hook.pendingFees());
    }

    function testFuzz_sellExactInputFeeIsExact(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1e6, 1_000_000 ether));
        seedBalanced(10_000_000 ether);
        uint256 before = imd.balanceOf(address(swapper));
        sell(-int256(uint256(amountIn)));
        uint256 received = imd.balanceOf(address(swapper)) - before;
        uint256 fee = hook.pendingFees();
        assertEq(fee, (received + fee) * FEE_BPS / BPS);
    }

    function test_feesAccumulateAcrossSwaps() public {
        seedBalanced(1_000_000 ether);
        buy(-1_000 ether);
        uint256 after1 = hook.pendingFees();
        sell(-500 ether);
        assertGt(hook.pendingFees(), after1);
        assertEq(hookClaims(), hook.pendingFees());
    }

    function test_buyOnAFreshManagerSeededWithTokensOnly() public {
        // The launch pool holds only $DEEZ: the PoolManager has no $IMD to transfer when the fee is due, so the
        // fee must be a claim, not a transfer.
        seedTokenOnly(1_000_000 ether);
        assertEq(imd.balanceOf(address(manager)), 0);
        imd.mint(address(swapper), 10_000 ether);
        uint256 deezBefore = token.balanceOf(address(swapper));
        buy(-1_000 ether);
        assertGt(token.balanceOf(address(swapper)), deezBefore);
        assertEq(hook.pendingFees(), 1_000 ether * FEE_BPS / BPS);
        assertEq(hookClaims(), hook.pendingFees());
        // And the claim is backed: harvesting moves real $IMD out.
        hook.harvest();
        assertEq(imd.balanceOf(address(rewards)), 1_000 ether * FEE_BPS / BPS);
    }

    function test_buyExactOutputOnAFreshManagerSeededWithTokensOnly() public {
        seedTokenOnly(1_000_000 ether);
        imd.mint(address(swapper), 10_000 ether);
        uint256 imdBefore = imd.balanceOf(address(swapper));
        buy(100 ether);
        uint256 paid = imdBefore - imd.balanceOf(address(swapper));
        uint256 fee = hook.pendingFees();
        assertEq(fee, (paid - fee) * FEE_BPS / (BPS - FEE_BPS));
        assertEq(hookClaims(), fee);
    }

    // ------------------------------------------------------- partial fills

    function test_exactOutputSellBeyondThePoolsImdReverts() public {
        // The launch pool holds $DEEZ only: an exact-output sell of $IMD cannot be filled at all. Before the fix
        // the trader paid 2/98 of the request in $IMD for nothing; now the swap reverts.
        seedTokenOnly(1_000_000 ether);
        imd.mint(address(swapper), 10_000 ether);
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 deezBefore = token.balanceOf(address(swapper));
        vm.expectRevert(); // PartialFill, wrapped by the PoolManager's hook call
        sell(int256(1_000 ether));
        assertEq(imd.balanceOf(address(swapper)), imdBefore);
        assertEq(token.balanceOf(address(swapper)), deezBefore);
        assertEq(hook.pendingFees(), 0);
    }

    function test_exactOutputSellThatFillsOnlyPartOfTheRequestReverts() public {
        // A balanced pool with less $IMD than asked: the pool would pay out what it has and the hook's up-front
        // fee would be on the full request. Refused.
        seedBalanced(1_000 ether); // tiny liquidity: about 1000 $IMD at most
        vm.expectRevert();
        sell(int256(5_000 ether));
        assertEq(hook.pendingFees(), 0);
    }

    function test_exactInputBuyStoppedByThePriceLimitReverts() public {
        seedTokenOnly(1_000_000 ether);
        imd.mint(address(swapper), 10_000 ether);
        int24 limitTick = tokenIsCurrency0 ? int24(TICK_SPACING + 5) : int24(-TICK_SPACING - 5);
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        uint256 imdBefore = imd.balanceOf(address(swapper));
        vm.expectRevert();
        swapper.swapWithLimit(key, !tokenIsCurrency0, -int256(1_000 ether), limit);
        assertEq(imd.balanceOf(address(swapper)), imdBefore, "nothing charged");
        assertEq(hook.pendingFees(), 0);
        // The same buy with a limit the pool can reach fills in full and pays exactly 2%.
        uint160 wide = tokenIsCurrency0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        swapper.swapWithLimit(key, !tokenIsCurrency0, -int256(1_000 ether), wide);
        assertEq(imdBefore - imd.balanceOf(address(swapper)), 1_000 ether);
        assertEq(hook.pendingFees(), 1_000 ether * FEE_BPS / BPS);
    }

    function test_exactOutputSellStoppedByThePriceLimitReverts() public {
        seedBalanced(1_000_000 ether);
        int24 limitTick = tokenIsCurrency0 ? int24(-5) : int24(5);
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        vm.expectRevert();
        swapper.swapWithLimit(key, tokenIsCurrency0, int256(1_000 ether), limit);
        assertEq(hook.pendingFees(), 0);
    }

    function test_deezSpecifiedPartialFillsAreChargedOnWhatActuallyTraded() public {
        // When $DEEZ is specified the fee is read from the realised $IMD delta, so a partial fill is simply a
        // smaller trade with a 2% fee on it.
        seedBalanced(1_000_000 ether);
        int24 limitTick = tokenIsCurrency0 ? int24(-5) : int24(5);
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        uint256 imdBefore = imd.balanceOf(address(swapper));
        swapper.swapWithLimit(key, tokenIsCurrency0, -int256(100_000 ether), limit); // exact-input sell
        uint256 received = imd.balanceOf(address(swapper)) - imdBefore;
        uint256 fee = hook.pendingFees();
        assertGt(received, 0);
        assertEq(fee, (received + fee) * FEE_BPS / BPS, "2% of the gross output actually paid");
    }

    // ------------------------------------------------------------- harvest

    function test_feesAreRecordedAgainstTheEpochTheyWereTradedIn() public {
        seedBalanced(1_000_000 ether);
        vm.warp(1_000 * 1 days + 100);
        buy(-1_000 ether);
        uint256 first = hook.pendingFees();
        vm.warp(1_001 * 1 days + 100);
        sell(-500 ether);
        uint256 second = hook.pendingFees() - first;
        assertEq(hook.pendingFeesOf(1_000), first);
        assertEq(hook.pendingFeesOf(1_001), second);
        hook.harvest(); // current and previous epoch
        assertEq(hook.pendingFees(), 0);
        (uint128 pot1000,,,) = rewards.pots(1_000);
        (uint128 pot1001,,,) = rewards.pots(1_001);
        assertEq(pot1000, first, "fees traded in epoch 1000 belong to epoch 1000, whenever harvested");
        assertEq(pot1001, second);
        assertEq(rewards.reserved(), first + second);
    }

    function test_oldEpochsAreHarvestedByNumber() public {
        seedBalanced(1_000_000 ether);
        vm.warp(1_000 * 1 days);
        buy(-1_000 ether);
        uint256 fees = hook.pendingFees();
        vm.warp(1_010 * 1 days);
        assertEq(hook.harvest(), 0, "harvest() only covers the current and previous epoch");
        assertEq(hook.pendingFeesOf(1_000), fees);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 1_000;
        vm.prank(address(0xCAFE));
        assertEq(hook.harvestEpochs(epochs), fees);
        (uint128 pot,,,) = rewards.pots(1_000);
        assertEq(pot, fees);
        assertEq(hook.pendingFees(), 0);
        assertEq(hookClaims(), 0);
        assertEq(hook.harvestEpochs(epochs), 0, "nothing left for that epoch");
    }

    function test_harvestMovesFeesToTheDistributorAndCreditsTheEpoch() public {
        seedBalanced(1_000_000 ether);
        buy(-1_000 ether);
        sell(-200 ether);
        uint256 fees = hook.pendingFees();
        vm.prank(address(0xCAFE)); // anyone
        uint256 harvested = hook.harvest();
        assertEq(harvested, fees);
        assertEq(hook.pendingFees(), 0);
        assertEq(hookClaims(), 0);
        assertEq(hook.totalHarvested(), fees);
        assertEq(imd.balanceOf(address(rewards)), fees);
        (uint128 total,,,) = rewards.pots(rewards.currentEpoch());
        assertEq(total, fees, "the current epoch's pot was credited");
        assertEq(rewards.reserved(), fees);
    }

    function test_harvestWithNothingPendingIsANoop() public {
        assertEq(hook.harvest(), 0);
        assertEq(imd.balanceOf(address(rewards)), 0);
    }

    function test_feeDeltasSumToZeroForTheHook() public {
        seedBalanced(1_000_000 ether);
        buy(-1_000 ether);
        buy(500 ether);
        sell(-700 ether);
        sell(300 ether);
        // Every swap settled: the manager holds exactly the tokens it accounts for, and the hook's claims are
        // fully backed by $IMD the manager holds beyond the pool's own reserves.
        hook.harvest();
        assertEq(imd.balanceOf(address(rewards)), hook.totalHarvested());
        assertEq(hookClaims(), 0);
    }

    // ------------------------------------------------- factory fee collect

    function test_zeroLiquidityChangeCollectsWithoutHookInterference() public {
        seedBalanced(1_000_000 ether);
        buy(-1_000 ether);
        sell(-1_000 ether);
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 deezBefore = token.balanceOf(address(swapper));
        BalanceDelta collected =
            swapper.addLiquidity(key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 0);
        assertGe(collected.amount0(), 0, "collect never pays");
        assertGe(collected.amount1(), 0, "collect never pays");
        assertGt(
            imd.balanceOf(address(swapper)) + token.balanceOf(address(swapper)),
            imdBefore + deezBefore,
            "LP fees collected"
        );
    }
}

contract DeezHookToken0Test is DeezHookTests {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract DeezHookToken1Test is DeezHookTests {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
