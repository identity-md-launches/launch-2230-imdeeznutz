// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice The slice of the hook the lock reads.
interface IDeezHookForLock {
    function poolKey() external view returns (PoolKey memory);
    function initialized() external view returns (bool);
}

/// @notice The slice of the distributor the lock reads: where the launcher recorded the hook.
interface IDeezRewardsForLock {
    function hook() external view returns (address);
}

/// @title Permanent liquidity lock for the $DEEZ/$IMD pool
/// @notice Anyone may send $DEEZ and/or $IMD here and call `lock()`: the balances become a liquidity position in
/// the launch pool that this contract owns and that nothing can ever withdraw. There is no owner, no remove
/// function and no way to collect the position's LP fees: they compound into the pool for every trader.
///
/// `DeezLaunch` uses it in the launch transaction: 980,000,000 $DEEZ (the pool share) and 10,000,000 $DEEZ of
/// the requester's 2% are transferred here and locked as single-sided positions just above the opening price.
/// Anyone may add more later. Both tokens: a full-range position. $DEEZ only: a position in the range just above
/// the current price (a permanent sell-side depth). $IMD only: a position just below the price (a permanent buy
/// wall).
contract DeezLiquidityLock is IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice How `lockAs` shapes the position.
    enum Mode {
        Auto,
        Token0Only,
        Token1Only,
        FullRange
    }

    IPoolManager public immutable poolManager;
    /// @notice The distributor; the hook is read from it because the launcher deploys the hook after this lock.
    IDeezRewardsForLock public immutable rewards;

    /// @notice Liquidity this contract has locked, by position range.
    mapping(bytes32 rangeId => uint128 liquidity) public lockedLiquidity;
    /// @notice Total $DEEZ and $IMD ever locked, for display.
    uint256 public totalLocked0;
    uint256 public totalLocked1;

    event Locked(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice LP fees the position had earned were credited back while topping it up; they stay here and the
    /// next `lock` folds them in.
    event FeesReturned(uint256 amount0, uint256 amount1);

    error NotPoolManager();
    error HookNotSet();
    error PoolNotInitialized();
    error NothingToLock();
    error ZeroAddress();
    error TickOutOfBounds(int24 tick, int24 minTick, int24 maxTick);
    error SettleMismatch(uint256 expected, uint256 actual);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_ The chain's Uniswap v4 PoolManager.
    /// @param rewards_ The `DeezRewards` of this launch; `rewards_.hook()` is the pool's hook once launched.
    constructor(IPoolManager poolManager_, address rewards_) {
        if (address(poolManager_) == address(0) || rewards_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        rewards = IDeezRewardsForLock(rewards_);
    }

    /// @notice The launch pool's hook, zero until `DeezLaunch` has launched.
    function hook() public view returns (IDeezHookForLock) {
        return IDeezHookForLock(rewards.hook());
    }

    /// @notice Turn every token this contract holds into locked liquidity in the launch pool, choosing the
    /// position from the balances: both tokens present, a full-range position; one token only, a single-sided
    /// position next to the current price. No tick bound.
    /// @dev Convenience form of `lockAs`. Because it decides from balances anyone can top up, a caller who wants
    /// a specific position should use `lockAs` with the mode spelled out and a tick bound, so that 1 wei of the
    /// other token or a price move in the same block cannot change what gets locked.
    /// @return liquidity The liquidity added.
    function lock() external returns (uint128 liquidity) {
        return lockAs(Mode.Auto, TickMath.MIN_TICK, TickMath.MAX_TICK);
    }

    /// @notice Lock the balance this contract holds as a position of the given shape. Anyone may call it.
    /// @param mode `Token0Only` / `Token1Only` lock only that token's balance, just above / at or below the
    /// current price, and leave the other balance for a later call; `FullRange` locks both in a full-range
    /// position (as much as the scarcer side funds); `Auto` picks one of these from the balances.
    /// @param minTick Lowest current pool tick the caller accepts; reverts with `TickOutOfBounds` below it.
    /// @param maxTick Highest current pool tick the caller accepts; reverts with `TickOutOfBounds` above it.
    /// @return liquidity The liquidity added.
    function lockAs(Mode mode, int24 minTick, int24 maxTick) public returns (uint128 liquidity) {
        IDeezHookForLock hook_ = hook();
        if (address(hook_) == address(0)) revert HookNotSet();
        if (!hook_.initialized()) revert PoolNotInitialized();
        PoolKey memory key = hook_.poolKey();
        uint256 balance0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        if (mode == Mode.Token0Only) balance1 = 0;
        if (mode == Mode.Token1Only) balance0 = 0;
        bool has0 = balance0 > 0;
        bool has1 = balance1 > 0;
        if (!has0 && !has1) revert NothingToLock();

        Slot0 slot0 = Slot0.wrap(poolManager.extsload(StateLibrary._getPoolStateSlot(key.toId())));
        uint160 sqrtPriceX96 = slot0.sqrtPriceX96();
        int24 tick = slot0.tick();
        if (tick < minTick || tick > maxTick) revert TickOutOfBounds(tick, minTick, maxTick);
        int24 spacing = key.tickSpacing;
        int24 tickLower = TickMath.minUsableTick(spacing);
        int24 tickUpper = TickMath.maxUsableTick(spacing);
        if (mode != Mode.FullRange && !has1) {
            // Token0 only: the whole position must sit above the current price.
            tickLower = _ceilToSpacing(tick + 1, spacing);
            if (tickLower >= tickUpper) tickLower = tickUpper - spacing;
        } else if (mode != Mode.FullRange && !has0) {
            // Token1 only: the whole position must sit at or below the current price.
            tickUpper = _floorToSpacing(tick, spacing);
            if (tickUpper <= tickLower) tickUpper = tickLower + spacing;
        }
        liquidity = _liquidityFor(sqrtPriceX96, tickLower, tickUpper, balance0, balance1);
        if (liquidity < 1) revert NothingToLock();

        bytes memory out = poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
        (uint256 amount0, uint256 amount1, uint256 returned0, uint256 returned1) =
            abi.decode(out, (uint256, uint256, uint256, uint256));
        lockedLiquidity[keccak256(abi.encode(tickLower, tickUpper))] += liquidity;
        totalLocked0 += amount0;
        totalLocked1 += amount1;
        emit Locked(tickLower, tickUpper, liquidity, amount0, amount1);
        if (returned0 + returned1 > 0) emit FeesReturned(returned0, returned1);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Adds the liquidity and settles what the position costs. Topping up a range that already earned LP
    /// fees credits those fees to the caller's delta; a net positive side is taken back here, so it is never
    /// left unsettled and simply waits for the next `lock`.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint128));
        (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        (uint256 amount0, uint256 returned0) = _settle(key.currency0, delta.amount0());
        (uint256 amount1, uint256 returned1) = _settle(key.currency1, delta.amount1());
        // The caller delta nets fees credited against the principal; what was actually locked is the principal:
        // paid + fees credited - fees taken back out.
        amount0 = amount0 + _positive(feesAccrued.amount0()) - returned0;
        amount1 = amount1 + _positive(feesAccrued.amount1()) - returned1;
        return abi.encode(amount0, amount1, returned0, returned1);
    }

    /// @dev Pay a negative delta to the PoolManager; take a positive one back into this contract.
    function _settle(Currency currency, int128 amount) private returns (uint256 paid, uint256 returned) {
        if (amount < 0) {
            paid = uint256(uint128(-amount));
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), paid);
            uint256 settled = poolManager.settle();
            if (settled != paid) revert SettleMismatch(paid, settled);
        } else if (amount > 0) {
            returned = uint256(uint128(amount));
            poolManager.take(currency, address(this), returned);
        }
    }

    function _positive(int128 amount) private pure returns (uint256) {
        return amount > 0 ? uint256(uint128(amount)) : 0;
    }

    /// @dev The largest liquidity both balances can fund in the range, shaved by one part in a million so the
    /// PoolManager's round-up on the amounts owed never exceeds what is held.
    function _liquidityFor(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 liquidity;
        if (sqrtPriceX96 <= sqrtA) {
            liquidity = _liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtPriceX96 < sqrtB) {
            uint256 l0 = _liquidityForAmount0(sqrtPriceX96, sqrtB, amount0);
            uint256 l1 = _liquidityForAmount1(sqrtA, sqrtPriceX96, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = _liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
        liquidity -= liquidity / 1_000_000;
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;
        return uint128(liquidity);
    }

    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint256) {
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        return FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA);
    }

    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint256) {
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA);
    }

    /// @dev Largest multiple of `spacing` at or below `tick`, by subtracting the (non-negative) remainder.
    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder < 0) remainder += spacing;
        return tick - remainder;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 floored = _floorToSpacing(tick, spacing);
        return floored == tick ? tick : floored + spacing;
    }
}
