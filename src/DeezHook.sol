// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {DeezRewards} from "./DeezRewards.sol";
import {DeezLiquidityLock} from "./DeezLiquidityLock.sol";

/// @title DEEZ flywheel hook
/// @notice Uniswap v4 hook for the $DEEZ/$IMD pool. Takes exactly 2% of every buy and every sell, always on the
/// $IMD side of the trade, and hands it to `DeezRewards`, which pays it to $DEEZ holders pro rata.
///
/// Fee mechanics (FEE_BPS = 200 of BPS = 10_000):
///   - Buy, exact input ($IMD specified):  2% of the $IMD the trader pays is diverted before the swap.
///   - Buy, exact output ($DEEZ specified): after the swap the trader pays 2/98 on top of what the pool took,
///     so the fee is 2% of everything the trader pays.
///   - Sell, exact input ($DEEZ specified):  2% of the $IMD the pool pays out is diverted after the swap.
///   - Sell, exact output ($IMD specified):  the pool pays out 2/98 more than asked and the hook keeps that,
///     so the fee is 2% of everything the pool paid out and the trader receives exactly what it asked for.
/// On the two $IMD-specified cases the fee is taken from the requested amount before the swap, so a swap the
/// pool cannot fill in full (price limit reached, or no $IMD left to pay out) reverts with `PartialFill`
/// rather than charging more than 2% of what actually traded.
/// Each fee is minted to the hook as an ERC-6909 claim on the PoolManager inside the swap, so it needs no
/// balance in the PoolManager (a launch pool is seeded with $DEEZ only) and can never make a swap revert
/// because a recipient refused it. Fees are recorded against the reward epoch they were traded in; anyone may
/// call `harvest()` to burn the claims, move the $IMD into `DeezRewards` and credit each epoch's own pot, so
/// nobody can choose which day's holders a fee goes to by timing the harvest. `DeezRewards.claim` calls
/// `harvestEpochs` for the epochs it pays, so a claim never misses fees of the day that were still unharvested.
///
/// No owner, no settable parameter, no pause: the hook has no admin surface. It has no liquidity callbacks.
/// `DeezLaunch` deploys it (CREATE2, salt mined off chain for the permission bits), opens the pool and locks
/// the launch liquidity in one transaction.
contract DeezHook is IHooks, IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Hook fee on every swap, in basis points of the $IMD side.
    uint256 public constant FEE_BPS = 200;
    uint256 public constant BPS = 10_000;

    IPoolManager public immutable poolManager;
    /// @notice The launch token ($DEEZ).
    Currency public immutable token;
    /// @notice The pair currency ($IMD) the fee is taken in and rewards are paid in.
    Currency public immutable pairedCurrency;
    /// @notice The holder reward distributor of this launch (deployed by the factory, wired here by `DeezLaunch`).
    DeezRewards public immutable rewards;
    /// @notice Permanent liquidity lock for the pool (deployed by the factory); see `DeezLiquidityLock`.
    DeezLiquidityLock public immutable liquidityLock;
    /// @dev Whether `token` sorts as currency0 of the pool.
    bool public immutable tokenIsCurrency0;

    /// @notice Id of the one pool this hook serves, zero until initialized.
    PoolId public poolId;
    /// @notice Whether the launch pool has been initialized on this hook.
    bool public initialized;
    /// @dev The launch pool's key, recorded at initialization.
    PoolKey private _poolKey;
    /// @notice $IMD taken as fees and not yet harvested (held as an ERC-6909 claim on the PoolManager).
    uint256 public pendingFees;
    /// @notice The part of `pendingFees` traded in each reward epoch; harvesting credits it to that epoch's pot.
    mapping(uint256 epoch => uint256 amount) public pendingFeesOf;
    /// @notice $IMD moved into `rewards` over the hook's lifetime.
    uint256 public totalHarvested;

    event FeeTaken(bool indexed buy, uint256 indexed epoch, uint256 amount);
    /// @param amount Fees moved into `DeezRewards`; `accrued` is stray $IMD the distributor found at the same time.
    event Harvested(uint256 amount, uint256 accrued);

    error NotPoolManager();
    error HookNotImplemented();
    error AlreadyInitialized();
    error WrongPool();
    error ZeroAddress();
    error SameCurrency();
    error UnlockMismatch(uint256 expected, uint256 actual);
    /// @notice The pool filled less than the swap asked for, so the fee taken up front would exceed 2%.
    error PartialFill(int256 expectedPairedDelta, int256 actualPairedDelta);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Deployed by `DeezLaunch` with CREATE2 and a salt mined so the address carries `getHookPermissions`;
    /// the constructor makes no external call.
    /// @param poolManager_ The chain's Uniswap v4 PoolManager.
    /// @param token_ The launch token ($DEEZ).
    /// @param pairedCurrency_ The pair token the pool quotes in and rewards are paid in ($IMD).
    /// @param rewards_ The `DeezRewards` that receives the fees.
    /// @param liquidityLock_ The `DeezLiquidityLock` of the pool.
    constructor(
        IPoolManager poolManager_,
        address token_,
        address pairedCurrency_,
        address rewards_,
        address liquidityLock_
    ) {
        if (
            address(poolManager_) == address(0) || token_ == address(0) || pairedCurrency_ == address(0)
                || rewards_ == address(0) || liquidityLock_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (token_ == pairedCurrency_) revert SameCurrency();
        poolManager = poolManager_;
        token = Currency.wrap(token_);
        pairedCurrency = Currency.wrap(pairedCurrency_);
        tokenIsCurrency0 = token_ < pairedCurrency_;
        rewards = DeezRewards(rewards_);
        liquidityLock = DeezLiquidityLock(liquidityLock_);
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @notice The callbacks this hook implements; the deployed address must carry exactly these bits.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------- callbacks

    /// @inheritdoc IHooks
    /// @dev Accepts exactly one pool: the launch token against the pair currency, at any fee or spacing the
    /// factory opens it with. Refuses every pool after the first and every pool with other currencies.
    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (initialized) revert AlreadyInitialized();
        (Currency c0, Currency c1) = _sortedCurrencies();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(c0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(c1)
        ) {
            revert WrongPool();
        }
        initialized = true;
        poolId = key.toId();
        _poolKey = key;
        return IHooks.beforeInitialize.selector;
    }

    /// @notice The launch pool's key (all zero until initialized).
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @inheritdoc IHooks
    /// @dev When the specified currency is $IMD (exact-input buy, exact-output sell) the fee is known now and
    /// is returned as a positive specified delta the hook receives.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        uint256 fee = _specifiedFee(params);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev When the unspecified currency is $IMD (exact-output buy, exact-input sell) the fee is known only now.
    /// When $IMD was the specified currency, the fee `beforeSwap` already took assumed the pool would fill the
    /// whole request; a partial fill (the trader's price limit reached, or the pool out of $IMD on an exact-output
    /// sell) would make that fee more than 2% of what actually traded, so such a swap reverts instead.
    /// The total fee of the swap (both halves) is minted to the hook as an ERC-6909 claim here and recorded
    /// against the reward epoch the trade happens in.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkPool(key);
        uint256 specifiedFee = _specifiedFee(params);
        if (specifiedFee > 0) _requireFullFill(params, delta, specifiedFee);
        uint256 unspecifiedFee = _unspecifiedFee(params, delta);
        uint256 total = specifiedFee + unspecifiedFee;
        if (total > 0) {
            poolManager.mint(address(this), pairedCurrency.toId(), total);
            uint256 epoch = rewards.currentEpoch();
            pendingFees += total;
            pendingFeesOf[epoch] += total;
            emit FeeTaken(_isBuy(params), epoch, total);
        }
        return (IHooks.afterSwap.selector, unspecifiedFee.toInt128());
    }

    /// @notice Harvest the fees of the current and the previous reward epoch: burn the hook's $IMD claims, move
    /// the $IMD into `DeezRewards` and credit each epoch's pot with the fees traded in that epoch.
    /// @dev Permissionless. If the pair token ever refuses the transfer, swaps keep working and the claims wait.
    /// Fees of older epochs (`pendingFeesOf`) are harvested with `harvestEpochs`.
    function harvest() external returns (uint256 amount) {
        uint256 epoch = rewards.currentEpoch();
        uint256[] memory epochs = new uint256[](epoch == 0 ? 1 : 2);
        epochs[0] = epoch;
        if (epoch != 0) epochs[1] = epoch - 1;
        return _harvest(epochs);
    }

    /// @notice Harvest the fees traded in `epochs`, each credited to its own pot. Anyone may call this;
    /// `DeezRewards.claim` does, for the epochs it pays.
    function harvestEpochs(uint256[] calldata epochs) external returns (uint256 amount) {
        return _harvest(epochs);
    }

    function _harvest(uint256[] memory epochs) internal returns (uint256 amount) {
        uint256[] memory amounts = new uint256[](epochs.length);
        for (uint256 i = 0; i < epochs.length; i++) {
            amounts[i] = pendingFeesOf[epochs[i]];
            pendingFeesOf[epochs[i]] = 0;
            amount += amounts[i];
        }
        if (amount == 0) return 0;
        pendingFees -= amount;
        totalHarvested += amount;
        // Stray donations go to the current epoch before the fees are credited to theirs.
        uint256 accrued = rewards.accrue();
        uint256 moved = abi.decode(poolManager.unlock(abi.encode(amount)), (uint256));
        if (moved != amount) revert UnlockMismatch(amount, moved);
        for (uint256 i = 0; i < epochs.length; i++) {
            if (amounts[i] > 0) rewards.credit(epochs[i], amounts[i]);
        }
        emit Harvested(amount, accrued);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), pairedCurrency.toId(), amount);
        poolManager.take(pairedCurrency, address(rewards), amount);
        return abi.encode(amount);
    }

    /// @dev The fee on an $IMD-specified swap was computed in `beforeSwap` from the requested amount, so the pool
    /// must have traded exactly the rest: `in - fee` on an exact-input buy, `out + fee` on an exact-output sell.
    function _requireFullFill(SwapParams calldata params, BalanceDelta delta, uint256 fee) internal view {
        int128 paired = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
        // Exact input (negative): the pool received `in - fee`. Exact output (positive): it paid `out + fee`.
        int256 expected = params.amountSpecified + int256(fee);
        if (int256(paired) != expected) revert PartialFill(expected, paired);
    }

    // ------------------------------------------------------------ fee math

    /// @notice Fee on a swap whose specified amount is in $IMD; zero when $DEEZ is specified.
    function _specifiedFee(SwapParams calldata params) internal view returns (uint256) {
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIsCurrency0 == tokenIsCurrency0) return 0;
        if (params.amountSpecified < 0) {
            // Exact-input buy: 2% of the $IMD paid in.
            return uint256(-params.amountSpecified) * FEE_BPS / BPS;
        }
        // Exact-output sell: the pool pays out 2/98 more than asked, and that extra is the 2% of the gross.
        return uint256(params.amountSpecified) * FEE_BPS / (BPS - FEE_BPS);
    }

    /// @notice Fee on a swap whose unspecified amount is in $IMD; zero when $IMD is specified.
    function _unspecifiedFee(SwapParams calldata params, BalanceDelta delta) internal view returns (uint256) {
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        if (specifiedIsCurrency0 != tokenIsCurrency0) return 0;
        int128 paired = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
        if (paired > 0) {
            // Exact-input sell: 2% of the $IMD the trader would receive.
            return uint256(uint128(paired)) * FEE_BPS / BPS;
        }
        if (paired < 0) {
            // Exact-output buy: the trader pays 2/98 on top of what the pool charged.
            return uint256(uint128(-paired)) * FEE_BPS / (BPS - FEE_BPS);
        }
        return 0;
    }

    /// @notice A swap is a buy when $DEEZ comes out: currency0 -> currency1 when $IMD is currency0.
    function _isBuy(SwapParams calldata params) internal view returns (bool) {
        return params.zeroForOne != tokenIsCurrency0;
    }

    function _sortedCurrencies() internal view returns (Currency c0, Currency c1) {
        return tokenIsCurrency0 ? (token, pairedCurrency) : (pairedCurrency, token);
    }

    function _checkPool(PoolKey calldata key) internal view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    // ------------------------------------------- callbacks this hook does not declare

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
