// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {DeezToken} from "./DeezToken.sol";
import {DeezHook} from "./DeezHook.sol";
import {DeezRewards} from "./DeezRewards.sol";
import {DeezLiquidityLock} from "./DeezLiquidityLock.sol";

/// @title IMDeezNutz launcher
/// @notice Finishes the $DEEZ launch in one transaction once the factory has deployed this contract, `DeezToken`
/// (whose whole supply is minted here), `DeezRewards` and `DeezLiquidityLock`:
///   1. deploys `DeezHook` with CREATE2 and a salt mined off chain so its address carries the hook permissions;
///   2. records the hook in `DeezRewards` (the lock reads it from there);
///   3. opens the $DEEZ/$IMD pool on the Uniswap v4 PoolManager at the opening price
///      (`OPENING_MARKET_CAP_IMD` / `TOTAL_SUPPLY`, i.e. 2,500 $IMD for the whole supply);
///   4. sends `POOL_SHARE` (98%) to `DeezLiquidityLock` and locks it as single-sided $DEEZ liquidity just above
///      the opening price: the pool's permanent depth, owned by nobody;
///   5. sends `LOCKED_REQUESTER_SHARE` (10,000,000 $DEEZ of the requester's 2%) to the lock and locks it the
///      same way, in the same transaction;
///   6. transfers the rest of the 2% (10,000,000 $DEEZ) to the requester wallet.
/// Only the requester may call `launch`: the hook, pool, lock positions and payout are fixed by this contract,
/// so the requester chooses nothing but the moment and the mined salt. The contracts the requester passes are
/// checked to be consistent with this launcher (they all name it, they name each other, and the token's whole
/// supply sits here); a wrong or foreign address reverts. That is consistency, not provenance: a contract has no
/// way to tell the factory's `DeezToken` from a look-alike the requester deploys (its runtime embeds immutables,
/// so no code hash can be pinned here), so whoever publishes the launch must read `token()`, `rewards()` and
/// `liquidityLock()` from this contract after `launch` and compare them with the factory's record before
/// filling the site. No owner, no admin function, nothing to change after launch.
contract DeezLaunch {
    using SafeERC20 for IERC20;

    /// @notice The whole $DEEZ supply, as `DeezToken` mints it here.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    /// @notice The requester's 2% of the supply.
    uint256 public constant REQUESTER_SHARE = 20_000_000 ether;
    /// @notice The part of the requester's 2% locked in `DeezLiquidityLock` in the launch transaction.
    uint256 public constant LOCKED_REQUESTER_SHARE = 10_000_000 ether;
    /// @notice The rest of the 2%, transferred to the requester wallet.
    uint256 public constant PAID_REQUESTER_SHARE = REQUESTER_SHARE - LOCKED_REQUESTER_SHARE;
    /// @notice The 98% seeded as permanent single-sided liquidity.
    uint256 public constant POOL_SHARE = TOTAL_SUPPLY - REQUESTER_SHARE;
    /// @notice Opening valuation of the whole supply, in $IMD (18 decimals): the price the pool opens at.
    uint256 public constant OPENING_MARKET_CAP_IMD = 2_500 ether;
    /// @notice The pool's LP fee, in hundredths of a basis point (1.25%).
    uint24 public constant POOL_FEE = 12_500;
    /// @notice The pool's tick spacing.
    int24 public constant TICK_SPACING = 60;

    /// @notice The requester: the only caller of `launch`, and the recipient of `PAID_REQUESTER_SHARE`.
    address public immutable requester;
    /// @notice The chain's Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The pair currency ($IMD).
    address public immutable pairedCurrency;

    /// @notice Set by `launch`; all zero before it.
    DeezToken public token;
    DeezRewards public rewards;
    DeezLiquidityLock public liquidityLock;
    DeezHook public hook;
    PoolId public poolId;
    bool public launched;

    event Launched(
        address indexed token,
        address indexed hook,
        address rewards,
        address liquidityLock,
        PoolId poolId,
        uint160 sqrtPriceX96,
        int24 tick
    );
    event PoolSeeded(uint256 amount, uint128 liquidity);
    event RequesterShareLocked(uint256 amount, uint128 liquidity);
    event RequesterPaid(address indexed requester, uint256 amount);

    error ZeroAddress();
    error SameCurrency();
    error NotRequester();
    error AlreadyLaunched();
    error WrongToken(address token);
    error WrongRewards(address rewards);
    error WrongLiquidityLock(address liquidityLock);
    error SupplyNotHere(uint256 held);

    /// @param requester_ The requester wallet ("$owner" in the manifest).
    /// @param poolManager_ The Uniswap v4 PoolManager on the launch chain.
    /// @param pairedCurrency_ The pair token ($IMD).
    constructor(address requester_, IPoolManager poolManager_, address pairedCurrency_) {
        if (requester_ == address(0) || address(poolManager_) == address(0) || pairedCurrency_ == address(0)) {
            revert ZeroAddress();
        }
        requester = requester_;
        poolManager = poolManager_;
        pairedCurrency = pairedCurrency_;
    }

    /// @notice Launch: deploy the hook, open the pool, lock the liquidity, pay the requester. Once, requester only.
    /// @param token_ The `DeezToken` the factory deployed for this launcher.
    /// @param rewards_ The `DeezRewards` the factory deployed for this launcher.
    /// @param liquidityLock_ The `DeezLiquidityLock` the factory deployed for this launcher.
    /// @param hookSalt CREATE2 salt such that `hookAddress(hookSalt, ...)` carries the hook permission bits.
    /// @return hook_ The deployed hook.
    function launch(address token_, address rewards_, address liquidityLock_, bytes32 hookSalt)
        external
        returns (DeezHook hook_)
    {
        if (msg.sender != requester) revert NotRequester();
        if (launched) revert AlreadyLaunched();
        launched = true;
        _check(token_, rewards_, liquidityLock_);
        token = DeezToken(token_);
        rewards = DeezRewards(rewards_);
        liquidityLock = DeezLiquidityLock(liquidityLock_);

        hook_ = new DeezHook{salt: hookSalt}(poolManager, token_, pairedCurrency, rewards_, liquidityLock_);
        hook = hook_;
        rewards.setHook(address(hook_));

        bool tokenIsCurrency0 = token_ < pairedCurrency;
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(token_), Currency.wrap(pairedCurrency))
            : (Currency.wrap(pairedCurrency), Currency.wrap(token_));
        PoolKey memory key = PoolKey({
            currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook_))
        });
        uint160 sqrtPriceX96 = openingSqrtPriceX96(tokenIsCurrency0);
        int24 tick = poolManager.initialize(key, sqrtPriceX96);
        poolId = key.toId();
        emit Launched(token_, address(hook_), rewards_, liquidityLock_, poolId, sqrtPriceX96, tick);

        DeezLiquidityLock.Mode mode =
            tokenIsCurrency0 ? DeezLiquidityLock.Mode.Token0Only : DeezLiquidityLock.Mode.Token1Only;
        IERC20(token_).safeTransfer(liquidityLock_, POOL_SHARE);
        uint128 seeded = liquidityLock.lockAs(mode, tick, tick);
        emit PoolSeeded(POOL_SHARE, seeded);
        IERC20(token_).safeTransfer(liquidityLock_, LOCKED_REQUESTER_SHARE);
        uint128 locked = liquidityLock.lockAs(mode, tick, tick);
        emit RequesterShareLocked(LOCKED_REQUESTER_SHARE, locked);
        IERC20(token_).safeTransfer(requester, PAID_REQUESTER_SHARE);
        emit RequesterPaid(requester, PAID_REQUESTER_SHARE);
    }

    /// @notice The address `launch` deploys the hook at for `salt`; mine `salt` off chain until the low 14 bits
    /// equal the hook's permission flags (`HookFlags`: 0x20CC).
    function hookAddress(bytes32 salt, address token_, address rewards_, address liquidityLock_)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(hookInitCode(token_, rewards_, liquidityLock_));
        // Four fixed-size words: the CREATE2 preimage is 0xff ++ deployer ++ salt ++ init code hash.
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /// @notice The hook's CREATE2 init code for these addresses (creation code followed by the ABI-encoded
    /// constructor arguments).
    function hookInitCode(address token_, address rewards_, address liquidityLock_) public view returns (bytes memory) {
        return bytes.concat(
            type(DeezHook).creationCode, abi.encode(poolManager, token_, pairedCurrency, rewards_, liquidityLock_)
        );
    }

    /// @notice The opening sqrt price (Q64.96) for a pool valuing the whole supply at `OPENING_MARKET_CAP_IMD`:
    /// `sqrt(currency1 per currency0)`, so it depends on which side $DEEZ sorts on.
    function openingSqrtPriceX96(bool tokenIsCurrency0) public pure returns (uint160) {
        uint256 ratioX192 = tokenIsCurrency0
            ? FullMath.mulDiv(OPENING_MARKET_CAP_IMD, 1 << 192, TOTAL_SUPPLY)
            : FullMath.mulDiv(TOTAL_SUPPLY, 1 << 192, OPENING_MARKET_CAP_IMD);
        return uint160(Math.sqrt(ratioX192));
    }

    /// @dev The three contracts must be consistent with this launcher: each names it, the distributor is built on
    /// the same token, pair currency and PoolManager, the lock on the distributor, and the token's whole supply
    /// sits here. Only values the passed contracts report about themselves can be read, so a complete look-alike
    /// set built by the requester passes; see the contract notice for the publisher's cross-check.
    function _check(address token_, address rewards_, address liquidityLock_) private view {
        if (token_ == address(0) || rewards_ == address(0) || liquidityLock_ == address(0)) revert ZeroAddress();
        if (token_ == pairedCurrency) revert SameCurrency();
        if (DeezToken(token_).launcher() != address(this)) revert WrongToken(token_);
        uint256 held = IERC20(token_).balanceOf(address(this));
        if (held < TOTAL_SUPPLY) revert SupplyNotHere(held);
        DeezRewards r = DeezRewards(rewards_);
        if (
            r.launcher() != address(this) || address(r.token()) != token_ || address(r.rewardToken()) != pairedCurrency
                || r.poolManager() != address(poolManager) || r.hook() != address(0)
        ) {
            revert WrongRewards(rewards_);
        }
        DeezLiquidityLock l = DeezLiquidityLock(liquidityLock_);
        if (address(l.poolManager()) != address(poolManager) || address(l.rewards()) != rewards_) {
            revert WrongLiquidityLock(liquidityLock_);
        }
    }
}
