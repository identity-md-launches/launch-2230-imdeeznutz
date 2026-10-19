// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {DeezLiquidityLock} from "src/DeezLiquidityLock.sol";
import {DeezBase} from "./DeezBase.t.sol";
import {Swapper} from "./mocks/Swapper.sol";

/// @notice Exercises real v4 positions. Ghost principal uses v4's amount deltas, and ghost fees use the
/// manager's fee growth, so the lock's display counters and events are not their own accounting oracle.
contract DeezLockHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    DeezLiquidityLock public immutable lock;
    Swapper public immutable swapper;
    Swapper public immutable outsider;
    IERC20 public immutable currency0;
    IERC20 public immutable currency1;
    PoolKey private key;
    address[3] public donors;

    struct Range {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    Range[] public ranges;
    mapping(bytes32 => uint256) private indexPlusOne;
    uint256 public donated0;
    uint256 public donated1;
    uint256 public principal0;
    uint256 public principal1;
    uint256 public realizedFees0;
    uint256 public realizedFees1;
    uint256 public successfulLocks;
    uint256 public successfulSwaps;
    uint256 public feeReturnCalls;

    constructor(
        IPoolManager manager_,
        DeezLiquidityLock lock_,
        Swapper swapper_,
        PoolKey memory key_,
        address[3] memory donors_
    ) {
        manager = manager_;
        lock = lock_;
        swapper = swapper_;
        outsider = new Swapper(manager_);
        key = key_;
        currency0 = IERC20(Currency.unwrap(key_.currency0));
        currency1 = IERC20(Currency.unwrap(key_.currency1));
        donors = donors_;
    }

    function donate(uint256 donorSeed, uint256 amountSeed, bool side0) public {
        address donor = donors[donorSeed % 3];
        IERC20 currency = side0 ? currency0 : currency1;
        uint256 balance = currency.balanceOf(donor);
        uint256 cap = balance < 50_000 ether ? balance : 50_000 ether;
        uint256 amount = bound(amountSeed, 0, cap);
        vm.prank(donor);
        assertTrue(currency.transfer(address(lock), amount));
        if (side0) donated0 += amount;
        else donated1 += amount;
    }

    function _range(DeezLiquidityLock.Mode mode, int24 tick) private view returns (int24 lower, int24 upper) {
        lower = TickMath.minUsableTick(key.tickSpacing);
        upper = TickMath.maxUsableTick(key.tickSpacing);
        bool only0 = mode == DeezLiquidityLock.Mode.Token0Only
            || (mode == DeezLiquidityLock.Mode.Auto && currency1.balanceOf(address(lock)) == 0);
        bool only1 = mode == DeezLiquidityLock.Mode.Token1Only
            || (mode == DeezLiquidityLock.Mode.Auto && currency0.balanceOf(address(lock)) == 0);
        // Mathematical floor, including negative ticks; bounded swaps keep us far from the end ticks.
        int24 floor = tick >= 0 ? tick / key.tickSpacing : (tick + 1) / key.tickSpacing - 1;
        if (only0) lower = (floor + 1) * key.tickSpacing;
        else if (only1) upper = floor * key.tickSpacing;
    }

    function _fees(int24 lower, int24 upper) private view returns (uint256 fee0, uint256 fee1) {
        (uint128 liquidity, uint256 last0, uint256 last1) =
            manager.getPositionInfo(key.toId(), address(lock), lower, upper, bytes32(0));
        if (liquidity == 0) return (0, 0);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthInside(key.toId(), lower, upper);
        unchecked {
            fee0 = FullMath.mulDiv(liquidity, growth0 - last0, 1 << 128);
            fee1 = FullMath.mulDiv(liquidity, growth1 - last1, 1 << 128);
        }
    }

    function _principal(uint160 price, int24 lower, int24 upper, uint128 liquidity)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        if (price <= a) return (SqrtPriceMath.getAmount0Delta(a, b, liquidity, true), 0);
        if (price >= b) return (0, SqrtPriceMath.getAmount1Delta(a, b, liquidity, true));
        return (
            SqrtPriceMath.getAmount0Delta(price, b, liquidity, true),
            SqrtPriceMath.getAmount1Delta(a, price, liquidity, true)
        );
    }

    function add(uint256 modeSeed, uint256 callerSeed, bool exactTick) public {
        DeezLiquidityLock.Mode mode = DeezLiquidityLock.Mode(modeSeed % 4);
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        (int24 lower, int24 upper) = _range(mode, tick);
        (uint256 fee0, uint256 fee1) = _fees(lower, upper);
        uint256 before0 = currency0.balanceOf(address(lock));
        uint256 before1 = currency1.balanceOf(address(lock));
        vm.prank(donors[callerSeed % 3]);
        try lock.lockAs(mode, exactTick ? tick : TickMath.MIN_TICK, exactTick ? tick : TickMath.MAX_TICK) returns (
            uint128 minted
        ) {
            assertGt(minted, 0, "successful lock has no liquidity");
            (uint256 amount0, uint256 amount1) = _principal(price, lower, upper, minted);
            assertEq(currency0.balanceOf(address(lock)) + amount0, before0 + fee0, "currency0 settlement");
            assertEq(currency1.balanceOf(address(lock)) + amount1, before1 + fee1, "currency1 settlement");
            principal0 += amount0;
            principal1 += amount1;
            realizedFees0 += fee0;
            realizedFees1 += fee1;
            if (fee0 > amount0 || fee1 > amount1) ++feeReturnCalls;
            ++successfulLocks;
            bytes32 id = keccak256(abi.encode(lower, upper));
            uint256 index = indexPlusOne[id];
            if (index == 0) {
                ranges.push(Range(lower, upper, minted));
                indexPlusOne[id] = ranges.length;
            } else {
                ranges[index - 1].liquidity += minted;
            }
        } catch (bytes memory reason) {
            // Empty balances, a missing full-range side, or sub-liquidity dust may produce no position.
            // Unexpected settlement, arithmetic and PoolManager errors are test failures.
            assertEq(
                reason, abi.encodeWithSelector(DeezLiquidityLock.NothingToLock.selector), "unexpected lock failure"
            );
            assertEq(currency0.balanceOf(address(lock)), before0);
            assertEq(currency1.balanceOf(address(lock)), before1);
        }
    }

    function swap(uint256 amountSeed, bool zeroForOne) public {
        uint256 amount = bound(amountSeed, 1 ether, 10_000 ether);
        swapper.swap(key, zeroForOne, -int256(amount));
        ++successfulSwaps;
    }

    function rejectStaleTick(uint256 callerSeed, bool above) external {
        // Fund first so the tick check, rather than the empty-balance check, is reached.
        donate(callerSeed, 1 ether, true);
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 boundTick = above ? tick + 1 : tick - 1;
        uint256 before0 = currency0.balanceOf(address(lock));
        uint256 before1 = currency1.balanceOf(address(lock));
        vm.prank(donors[callerSeed % 3]);
        vm.expectRevert(abi.encodeWithSelector(DeezLiquidityLock.TickOutOfBounds.selector, tick, boundTick, boundTick));
        lock.lockAs(DeezLiquidityLock.Mode.Auto, boundTick, boundTick);
        assertEq(currency0.balanceOf(address(lock)), before0);
        assertEq(currency1.balanceOf(address(lock)), before1);
    }

    function rejectForeignCallback(uint256 callerSeed) external {
        vm.prank(donors[callerSeed % 3]);
        vm.expectRevert(DeezLiquidityLock.NotPoolManager.selector);
        lock.unlockCallback(abi.encode(key, int24(-60), int24(60), uint128(1)));
    }

    function rejectForeignRemoval(uint256 rangeSeed) external {
        Range memory r = ranges[rangeSeed % ranges.length];
        // The attacker router owns no positions. It cannot name the lock as owner in modifyLiquidity,
        // even when it supplies exactly the lock's ticks and position salt.
        vm.expectRevert();
        outsider.addLiquidity(key, r.lower, r.upper, -int256(uint256(r.liquidity)));
    }

    function checkAccounting() external view {
        assertEq(lock.totalLocked0(), principal0, "displayed currency0 principal differs from v4");
        assertEq(lock.totalLocked1(), principal1, "displayed currency1 principal differs from v4");
        assertEq(currency0.balanceOf(address(lock)) + principal0, donated0 + realizedFees0, "currency0 conservation");
        assertEq(currency1.balanceOf(address(lock)) + principal1, donated1 + realizedFees1, "currency1 conservation");
        for (uint256 i; i < ranges.length; ++i) {
            Range memory r = ranges[i];
            (uint128 actual,,) = manager.getPositionInfo(key.toId(), address(lock), r.lower, r.upper, bytes32(0));
            assertEq(actual, r.liquidity, "locked position lost liquidity");
            assertEq(lock.lockedLiquidity(keccak256(abi.encode(r.lower, r.upper))), actual, "range ledger mismatch");
        }
    }
}

abstract contract DeezLockInvariantBase is DeezBase {
    DeezLockHandler internal handler;

    function setUp() public override {
        super.setUp();
        seedBalanced(1_000_000 ether);
        address[3] memory donors = [makeAddr("lock-alice"), makeAddr("lock-bob"), makeAddr("lock-carol")];
        for (uint256 i; i < 3; ++i) {
            token.transfer(donors[i], 10_000_000 ether);
            imd.mint(donors[i], 10_000_000 ether);
        }
        handler = new DeezLockHandler(IPoolManager(address(manager)), hook.liquidityLock(), swapper, key, donors);
        handler.donate(0, 1_000 ether, true);
        handler.donate(0, 1_000 ether, false);
        handler.add(uint256(DeezLiquidityLock.Mode.FullRange), 0, true);
        handler.donate(1, 1_000 ether, true);
        handler.add(uint256(DeezLiquidityLock.Mode.Token0Only), 1, true);
        handler.donate(2, 1_000 ether, false);
        handler.add(uint256(DeezLiquidityLock.Mode.Token1Only), 2, true);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.add.selector;
        selectors[2] = handler.swap.selector;
        selectors[3] = handler.rejectStaleTick.selector;
        selectors[4] = handler.rejectForeignCallback.selector;
        selectors[5] = handler.rejectForeignRemoval.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_positionsArePermanentAndPrincipalAndFeesAreConserved() public view {
        handler.checkAccounting();
    }

    function test_feeCreditsCanExceedTopUpWithoutEscapingTheLock() public {
        handler.swap(10_000 ether, true);
        handler.swap(10_000 ether, false);
        handler.donate(0, 1e12, true);
        handler.donate(0, 1e12, false);
        handler.add(uint256(DeezLiquidityLock.Mode.FullRange), 1, true);
        assertGt(handler.feeReturnCalls(), 0, "exercise a positive settlement delta");
        assertEq(handler.successfulSwaps(), 2);
        assertEq(handler.successfulLocks(), 4);
        handler.checkAccounting();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract DeezLockInvariantToken0Test is DeezLockInvariantBase {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract DeezLockInvariantToken1Test is DeezLockInvariantBase {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
