// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {DeezToken} from "../src/DeezToken.sol";
import {DeezHook} from "../src/DeezHook.sol";
import {DeezRewards} from "../src/DeezRewards.sol";
import {DeezLiquidityLock} from "../src/DeezLiquidityLock.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

/// @notice Shared fixture: a fresh PoolManager, the launch token, a mock $IMD, the hook mined onto its flags, and
/// the launch pool opened from a stand-in factory address. `wantTokenIsCurrency0` picks the currency order so
/// every path is exercised with $DEEZ on both sides of the key.
abstract contract DeezBase is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    address internal constant FACTORY = address(0xFAC7);

    PoolManager internal manager;
    DeezToken internal token;
    MockERC20 internal imd;
    DeezHook internal hook;
    DeezRewards internal rewards;
    Swapper internal swapper;
    PoolKey internal key;
    bool internal tokenIsCurrency0;

    function wantTokenIsCurrency0() internal pure virtual returns (bool);

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        token = new DeezToken(address(this));
        // Pick a mock pair token on the wanted side of the launch token.
        for (uint256 i = 0; i < 64; i++) {
            imd = new MockERC20("IMD", "IMD", 0);
            if ((address(token) < address(imd)) == wantTokenIsCurrency0()) break;
        }
        tokenIsCurrency0 = address(token) < address(imd);
        require(tokenIsCurrency0 == wantTokenIsCurrency0(), "could not find a pair token on the wanted side");

        hook = DeezHook(deployHook(manager, address(token), address(imd)));
        rewards = hook.rewards();

        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(token)));
        key = PoolKey({
            currency0: c0, currency1: c1, fee: POOL_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });

        vm.prank(FACTORY);
        manager.initialize(key, SQRT_PRICE_1_1);

        swapper = new Swapper(manager);
    }

    /// @dev Deploys a fresh distributor and lock for the hook (this test is their launcher), mines a CREATE2 salt
    /// from this test until the hook lands on an address carrying `FLAGS`, deploys it and records it in the
    /// distributor, as `DeezLaunch` does.
    function deployHook(PoolManager manager_, address token_, address paired_) internal returns (address) {
        DeezRewards rewards_ = new DeezRewards(token_, paired_, address(manager_), address(this));
        DeezLiquidityLock lock_ = new DeezLiquidityLock(IPoolManager(address(manager_)), address(rewards_));
        bytes memory creationCode = bytes.concat(
            type(DeezHook).creationCode,
            abi.encode(IPoolManager(address(manager_)), token_, paired_, address(rewards_), address(lock_))
        );
        bytes32 salt = mineSalt(address(this), creationCode);
        DeezHook hook_ = new DeezHook{salt: salt}(
            IPoolManager(address(manager_)), token_, paired_, address(rewards_), address(lock_)
        );
        rewards_.setHook(address(hook_));
        return address(hook_);
    }

    /// @dev The first salt under which `deployer` creates `creationCode` at an address carrying `FLAGS`.
    function mineSalt(address deployer, bytes memory creationCode) internal view returns (bytes32) {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 300_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, FLAGS) || predicted.code.length != 0) continue;
            return bytes32(i);
        }
        revert("no salt found");
    }

    /// @dev Seeds a balanced full-range position so both directions trade.
    function seedBalanced(uint256 liquidity) internal {
        token.transfer(address(swapper), 100_000_000 ether);
        imd.mint(address(swapper), 100_000_000 ether);
        swapper.addLiquidity(
            key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), int256(liquidity)
        );
    }

    /// @dev Seeds $DEEZ only, in the range just above the opening price, as the launch factory does: nothing but
    /// the launch token sits in the PoolManager afterwards.
    function seedTokenOnly(uint256 liquidity) internal {
        token.transfer(address(swapper), 100_000_000 ether);
        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (int24(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING))
            : (TickMath.minUsableTick(TICK_SPACING), -TICK_SPACING);
        swapper.addLiquidity(key, lower, upper, int256(liquidity));
    }

    /// @dev Buy $DEEZ with $IMD. Negative amount: exact $IMD in; positive: exact $DEEZ out.
    function buy(int256 amountSpecified) internal returns (BalanceDelta) {
        return swapper.swap(key, !tokenIsCurrency0, amountSpecified);
    }

    /// @dev Sell $DEEZ for $IMD. Negative amount: exact $DEEZ in; positive: exact $IMD out.
    function sell(int256 amountSpecified) internal returns (BalanceDelta) {
        return swapper.swap(key, tokenIsCurrency0, amountSpecified);
    }

    function imdId() internal view returns (uint256) {
        return Currency.wrap(address(imd)).toId();
    }

    function hookClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), imdId());
    }
}
