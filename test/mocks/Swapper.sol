// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Minimal test router: swaps and adds liquidity, paying from its own balances.
contract Swapper is IUnlockCallback {
    IPoolManager public immutable manager;

    uint8 private constant SWAP = 1;
    uint8 private constant LIQUIDITY = 2;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Swap on `key`; negative `amountSpecified` is exact input, positive exact output.
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        bytes memory out = manager.unlock(abi.encode(SWAP, key, SwapParams(zeroForOne, amountSpecified, limit)));
        return abi.decode(out, (BalanceDelta));
    }

    /// @notice Swap with a caller-chosen price limit, as routers do for slippage protection.
    function swapWithLimit(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        external
        returns (BalanceDelta)
    {
        bytes memory out = manager.unlock(abi.encode(SWAP, key, SwapParams(zeroForOne, amountSpecified, limit)));
        return abi.decode(out, (BalanceDelta));
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity)
        external
        returns (BalanceDelta)
    {
        bytes memory out = manager.unlock(abi.encode(LIQUIDITY, key, tickLower, tickUpper, liquidity));
        return abi.decode(out, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        uint8 kind = abi.decode(data, (uint8));
        PoolKey memory key;
        BalanceDelta delta;
        if (kind == SWAP) {
            SwapParams memory params;
            (, key, params) = abi.decode(data, (uint8, PoolKey, SwapParams));
            delta = manager.swap(key, params, "");
        } else {
            int24 lower;
            int24 upper;
            int256 liquidity;
            (, key, lower, upper, liquidity) = abi.decode(data, (uint8, PoolKey, int24, int24, int256));
            (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}
