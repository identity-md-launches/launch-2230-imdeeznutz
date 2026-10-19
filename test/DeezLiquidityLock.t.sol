// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeezBase} from "./DeezBase.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {DeezHook} from "../src/DeezHook.sol";
import {DeezLiquidityLock} from "../src/DeezLiquidityLock.sol";

abstract contract DeezLiquidityLockTests is DeezBase {
    using StateLibrary for IPoolManager;

    DeezLiquidityLock lock;

    function setUp() public override {
        super.setUp();
        lock = hook.liquidityLock();
    }

    function rangeLiquidity(int24 lower, int24 upper) internal view returns (uint128) {
        (uint128 liquidity,,) =
            IPoolManager(address(manager)).getPositionInfo(key.toId(), address(lock), lower, upper, bytes32(0));
        return liquidity;
    }

    function test_wiring() public {
        assertEq(address(lock.poolManager()), address(manager));
        assertEq(address(lock.hook()), address(hook));
        (bool ok,) = address(lock).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the lock has no owner");
    }

    function test_lockRefusesNothing() public {
        vm.expectRevert(DeezLiquidityLock.NothingToLock.selector);
        lock.lock();
    }

    function test_lockRefusesBeforeThePoolExists() public {
        DeezHook fresh = DeezHook(deployHook(manager, address(token), address(imd)));
        DeezLiquidityLock freshLock = fresh.liquidityLock();
        token.transfer(address(freshLock), 1 ether);
        vm.expectRevert(DeezLiquidityLock.PoolNotInitialized.selector);
        freshLock.lock();
    }

    function test_lockDeezOnlyBecomesLiquidityAboveThePrice() public {
        seedBalanced(1_000_000 ether);
        token.transfer(address(lock), 10_000_000 ether);
        uint128 liquidity = lock.lock();
        assertGt(liquidity, 0);
        assertLt(token.balanceOf(address(lock)), 10_000_000 ether / 100_000, "all but dust locked");
        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (int24(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), int24(0));
        assertEq(rangeLiquidity(lower, upper), liquidity);
        assertEq(
            tokenIsCurrency0 ? lock.totalLocked0() : lock.totalLocked1(),
            10_000_000 ether - token.balanceOf(address(lock))
        );
        assertEq(imd.balanceOf(address(lock)), 0);
        // Trading against it works: a buy now draws on the locked depth too.
        uint256 before = token.balanceOf(address(swapper));
        buy(-1_000 ether);
        assertGt(token.balanceOf(address(swapper)), before);
    }

    function test_lockImdOnlyBecomesABuyWallBelowThePrice() public {
        seedBalanced(1_000_000 ether);
        imd.mint(address(lock), 5_000 ether);
        uint128 liquidity = lock.lock();
        assertGt(liquidity, 0);
        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (TickMath.minUsableTick(TICK_SPACING), int24(0))
            : (int24(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING));
        assertEq(rangeLiquidity(lower, upper), liquidity);
        assertLt(imd.balanceOf(address(lock)), 5_000 ether / 100_000);
    }

    function test_lockBothBecomesFullRange() public {
        seedBalanced(1_000_000 ether);
        token.transfer(address(lock), 10_000 ether);
        imd.mint(address(lock), 10_000 ether);
        uint128 liquidity = lock.lock();
        assertEq(rangeLiquidity(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING)), liquidity);
        assertLt(token.balanceOf(address(lock)), 1 ether);
        assertLt(imd.balanceOf(address(lock)), 1 ether);
        // A second lock adds to the same position.
        token.transfer(address(lock), 1_000 ether);
        imd.mint(address(lock), 1_000 ether);
        uint128 more = lock.lock();
        assertEq(
            rangeLiquidity(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING)), liquidity + more
        );
    }

    function test_lockAsSingleSidedIgnoresDustOnTheOtherSide() public {
        // The griefing case from the review: 1 wei of the other token sent before the call. With an explicit
        // mode the whole 10,000,000 $DEEZ still becomes a single-sided position, and the dust stays behind.
        seedBalanced(1_000_000 ether);
        token.transfer(address(lock), 10_000_000 ether);
        imd.mint(address(lock), 1);
        DeezLiquidityLock.Mode mode =
            tokenIsCurrency0 ? DeezLiquidityLock.Mode.Token0Only : DeezLiquidityLock.Mode.Token1Only;
        uint128 liquidity = lock.lockAs(mode, -10, 10);
        assertGt(liquidity, 1);
        assertLt(token.balanceOf(address(lock)), 10_000_000 ether / 100_000, "all but dust locked");
        assertEq(imd.balanceOf(address(lock)), 1, "the other side was left alone");
        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (int24(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), int24(0));
        assertEq(rangeLiquidity(lower, upper), liquidity);
    }

    function test_lockAsRefusesAPriceOutsideTheCallersBounds() public {
        seedBalanced(1_000_000 ether);
        token.transfer(address(lock), 10_000_000 ether);
        sell(-5_000 ether); // moves the price away from tick 0
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertTrue(tick != 0);
        vm.expectRevert(abi.encodeWithSelector(DeezLiquidityLock.TickOutOfBounds.selector, tick, -10, 10));
        lock.lockAs(DeezLiquidityLock.Mode.Auto, -10, 10);
        assertEq(token.balanceOf(address(lock)), 10_000_000 ether, "nothing locked");
    }

    function test_lockAsFullRangeAndTheLeftoverSingleSided() public {
        seedBalanced(1_000_000 ether);
        token.transfer(address(lock), 10_000_000 ether);
        imd.mint(address(lock), 1_000 ether);
        uint128 full = lock.lockAs(DeezLiquidityLock.Mode.FullRange, TickMath.MIN_TICK, TickMath.MAX_TICK);
        assertEq(rangeLiquidity(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING)), full);
        assertLt(imd.balanceOf(address(lock)), 1 ether, "the scarcer side is used up");
        assertGt(token.balanceOf(address(lock)), 9_000_000 ether, "the rest of the DEEZ waits");
        DeezLiquidityLock.Mode mode =
            tokenIsCurrency0 ? DeezLiquidityLock.Mode.Token0Only : DeezLiquidityLock.Mode.Token1Only;
        uint128 single = lock.lockAs(mode, TickMath.MIN_TICK, TickMath.MAX_TICK);
        assertGt(single, 0);
        assertLt(token.balanceOf(address(lock)), 10_000_000 ether / 100_000, "then locked single-sided in one call");
    }

    function test_lockAsRefusesAnEmptySide() public {
        seedBalanced(1_000_000 ether);
        imd.mint(address(lock), 1_000 ether);
        DeezLiquidityLock.Mode deezOnly =
            tokenIsCurrency0 ? DeezLiquidityLock.Mode.Token0Only : DeezLiquidityLock.Mode.Token1Only;
        vm.expectRevert(DeezLiquidityLock.NothingToLock.selector);
        lock.lockAs(deezOnly, TickMath.MIN_TICK, TickMath.MAX_TICK);
    }

    function test_lockedLiquidityCannotBeRemoved() public {
        seedBalanced(1_000_000 ether);
        token.transfer(address(lock), 10_000 ether);
        imd.mint(address(lock), 10_000 ether);
        lock.lock();
        string[4] memory signatures = ["unlock()", "withdraw()", "removeLiquidity(uint128)", "collect()"];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(lock).call(abi.encodeWithSignature(signatures[i], uint128(1)));
            assertFalse(ok, signatures[i]);
        }
        vm.expectRevert(DeezLiquidityLock.NotPoolManager.selector);
        lock.unlockCallback("");
    }
}

contract DeezLiquidityLockToken0Test is DeezLiquidityLockTests {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract DeezLiquidityLockToken1Test is DeezLiquidityLockTests {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
