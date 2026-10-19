// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {DeezLaunch} from "../src/DeezLaunch.sol";
import {DeezToken} from "../src/DeezToken.sol";
import {DeezHook} from "../src/DeezHook.sol";
import {DeezRewards} from "../src/DeezRewards.sol";
import {DeezLiquidityLock} from "../src/DeezLiquidityLock.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

/// @notice Stands in for the launch factory: deploys the four application contracts in one call, as the
/// factory's `launchContracts` does, with the manifest's argument order (launcher first, the others naming it).
contract FactoryStandIn {
    function deployAll(address requester, IPoolManager poolManager, address imd)
        external
        returns (DeezLaunch launcher, DeezToken token, DeezRewards rewards, DeezLiquidityLock lock)
    {
        launcher = new DeezLaunch(requester, poolManager, imd);
        token = new DeezToken(address(launcher));
        rewards = new DeezRewards(address(token), imd, address(poolManager), address(launcher));
        lock = new DeezLiquidityLock(poolManager, address(rewards));
    }
}

/// @notice A token that mimics everything `DeezLaunch._check` reads, to show the checks still refuse it.
contract ImpostorToken is MockERC20 {
    address public launcher;

    constructor(address launcher_, address holder) MockERC20("Fake", "FAKE", 0) {
        launcher = launcher_;
        _mint(holder, 1_000_000_000 ether);
    }
}

/// @notice The launch transaction end to end, on both currency orders: hook mined onto its flags, pool opened at
/// the opening price, 980,000,000 + 10,000,000 $DEEZ locked, 10,000,000 $DEEZ paid, and the pool trading after.
abstract contract DeezLaunchTests is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    address internal constant REQUESTER = address(0xB045);

    PoolManager internal manager;
    MockERC20 internal imd;
    FactoryStandIn internal factory;
    DeezLaunch internal launcher;
    DeezToken internal token;
    DeezRewards internal rewards;
    DeezLiquidityLock internal lock;
    bool internal tokenIsCurrency0;

    function wantTokenIsCurrency0() internal pure virtual returns (bool);

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        factory = new FactoryStandIn();
        // Pick a mock pair token on the wanted side of the launch token: the token address follows from the
        // factory's nonce, so deploy stand-in factories until the order matches.
        for (uint256 i = 0; i < 64; i++) {
            imd = new MockERC20("IMD", "IMD", 0);
            address predictedToken = vm.computeCreateAddress(address(factory), 2);
            if ((predictedToken < address(imd)) == wantTokenIsCurrency0()) break;
        }
        (launcher, token, rewards, lock) = factory.deployAll(REQUESTER, IPoolManager(address(manager)), address(imd));
        tokenIsCurrency0 = address(token) < address(imd);
        require(tokenIsCurrency0 == wantTokenIsCurrency0(), "could not find a pair token on the wanted side");
    }

    /// @dev Mines the salt the requester would mine off chain, with the launcher's own prediction.
    function mineSalt() internal view returns (bytes32) {
        for (uint256 i = 0; i < 300_000; i++) {
            address predicted = launcher.hookAddress(bytes32(i), address(token), address(rewards), address(lock));
            if (HookFlags.matches(predicted, FLAGS)) return bytes32(i);
        }
        revert("no salt found");
    }

    function doLaunch() internal returns (DeezHook hook) {
        bytes32 salt = mineSalt();
        vm.prank(REQUESTER);
        hook = launcher.launch(address(token), address(rewards), address(lock), salt);
    }

    function poolKey(DeezHook hook) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(token)));
        return PoolKey(c0, c1, launcher.POOL_FEE(), launcher.TICK_SPACING(), IHooks(address(hook)));
    }

    // ------------------------------------------------------------------ before launch

    function test_factoryDeploymentLeavesEverythingUnlaunched() public view {
        assertEq(token.balanceOf(address(launcher)), token.TOTAL_SUPPLY(), "the whole supply waits in the launcher");
        assertEq(token.launcher(), address(launcher));
        assertEq(rewards.launcher(), address(launcher));
        assertEq(rewards.hook(), address(0));
        assertEq(address(lock.hook()), address(0));
        assertEq(address(lock.rewards()), address(rewards));
        assertFalse(launcher.launched());
        assertEq(address(launcher.hook()), address(0));
        assertEq(launcher.requester(), REQUESTER);
    }

    function test_nothingIsOwned() public {
        address[4] memory contracts = [address(launcher), address(token), address(rewards), address(lock)];
        for (uint256 i = 0; i < 4; i++) {
            (bool ok,) = contracts[i].call(abi.encodeWithSignature("owner()"));
            assertFalse(ok, "a launch contract exposes an owner");
        }
    }

    function test_lockAndClaimRefuseBeforeTheHookIsSet() public {
        vm.expectRevert(DeezLiquidityLock.HookNotSet.selector);
        lock.lock();
        uint256[] memory epochs = new uint256[](1);
        vm.prank(REQUESTER);
        vm.expectRevert(DeezRewards.HookNotSet.selector);
        rewards.claim(REQUESTER, epochs);
        assertEq(rewards.claimable(REQUESTER, 0), 0);
    }

    function test_setHookIsTheLaunchersAlone() public {
        vm.expectRevert(DeezRewards.NotLauncher.selector);
        rewards.setHook(address(0xBEEF));
        vm.prank(REQUESTER);
        vm.expectRevert(DeezRewards.NotLauncher.selector);
        rewards.setHook(address(0xBEEF));
        vm.prank(address(launcher));
        vm.expectRevert(DeezRewards.ZeroAddress.selector);
        rewards.setHook(address(0));
        // A hook that names another distributor is refused even by the launcher.
        DeezRewards other = new DeezRewards(address(token), address(imd), address(manager), address(this));
        bytes memory code = launcher.hookInitCode(address(token), address(other), address(lock));
        bytes32 foreignSalt;
        for (uint256 i = 0; i < 300_000; i++) {
            if (HookFlags.matches(vm.computeCreate2Address(bytes32(i), keccak256(code), address(this)), FLAGS)) {
                foreignSalt = bytes32(i);
                break;
            }
        }
        DeezHook foreign = new DeezHook{salt: foreignSalt}(
            IPoolManager(address(manager)), address(token), address(imd), address(other), address(lock)
        );
        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.HookNotOurs.selector, address(foreign)));
        rewards.setHook(address(foreign));
    }

    // ------------------------------------------------------------------ the launch

    function test_launchDeploysWiresOpensLocksAndPays() public {
        bytes32 salt = mineSalt();
        address predicted = launcher.hookAddress(salt, address(token), address(rewards), address(lock));
        vm.prank(REQUESTER);
        DeezHook hook = launcher.launch(address(token), address(rewards), address(lock), salt);

        // Deployed where predicted, carrying exactly the permission bits.
        assertEq(address(hook), predicted);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertTrue(launcher.launched());
        assertEq(address(launcher.hook()), address(hook));
        assertEq(address(launcher.token()), address(token));
        assertEq(address(launcher.rewards()), address(rewards));
        assertEq(address(launcher.liquidityLock()), address(lock));

        // Wired.
        assertEq(rewards.hook(), address(hook));
        assertEq(address(lock.hook()), address(hook));
        assertEq(address(hook.rewards()), address(rewards));
        assertEq(address(hook.liquidityLock()), address(lock));
        assertEq(hook.tokenIsCurrency0(), tokenIsCurrency0);

        // Pool open at the opening price, 2,500 $IMD for the whole supply.
        PoolKey memory key = poolKey(hook);
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(PoolId.unwrap(launcher.poolId()), PoolId.unwrap(key.toId()));
        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(sqrtPriceX96, launcher.openingSqrtPriceX96(tokenIsCurrency0));
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        // currency1 per currency0, scaled by 1e18: 2.5e-6 $IMD per $DEEZ, or 400,000 $DEEZ per $IMD.
        uint256 price1e18 = (priceX192 >> 96) * 1e18 >> 96;
        if (tokenIsCurrency0) assertApproxEqRel(price1e18, 2_500 ether * 1e18 / 1_000_000_000 ether, 1e12);
        else assertApproxEqRel(price1e18, 400_000 ether, 1e12);

        // 980,000,000 + 10,000,000 $DEEZ locked as single-sided liquidity, nothing left anywhere else.
        uint256 lockedDeez = tokenIsCurrency0 ? lock.totalLocked0() : lock.totalLocked1();
        uint256 lockedImd = tokenIsCurrency0 ? lock.totalLocked1() : lock.totalLocked0();
        uint256 sent = launcher.POOL_SHARE() + launcher.LOCKED_REQUESTER_SHARE();
        assertEq(sent, 990_000_000 ether);
        // The lock shaves one part in a million off the liquidity so the PoolManager's round-up never exceeds
        // what it holds; the few tokens that leaves stay in the lock, where the next `lock()` folds them in.
        assertGe(lockedDeez, sent - sent / 1_000_000, "at least 990,000,000 $DEEZ less the 1 ppm shave is locked");
        assertLe(lockedDeez, sent);
        assertEq(lockedImd, 0);
        assertEq(token.balanceOf(address(manager)), lockedDeez, "the locked $DEEZ sits in the PoolManager");
        assertEq(token.balanceOf(address(lock)), sent - lockedDeez, "the shave waits in the lock");
        assertLe(token.balanceOf(address(lock)), 1_000 ether);
        assertEq(token.balanceOf(address(launcher)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (int24(launcher.TICK_SPACING()) * (tick / launcher.TICK_SPACING() + 1), TickMath.maxUsableTick(60))
            : (TickMath.minUsableTick(60), int24(launcher.TICK_SPACING()) * (tick / launcher.TICK_SPACING()));
        if (tokenIsCurrency0 && tick < 0 && tick % 60 != 0) lower -= 60;
        if (!tokenIsCurrency0 && tick < 0 && tick % 60 != 0) upper -= 60;
        (uint128 liquidity,,) =
            IPoolManager(address(manager)).getPositionInfo(key.toId(), address(lock), lower, upper, bytes32(0));
        assertGt(liquidity, 0, "the lock owns the position");
        assertEq(lock.lockedLiquidity(keccak256(abi.encode(lower, upper))), liquidity);

        // The requester got the other 10,000,000 $DEEZ.
        assertEq(token.balanceOf(REQUESTER), 10_000_000 ether);
        assertEq(launcher.PAID_REQUESTER_SHARE() + launcher.LOCKED_REQUESTER_SHARE(), launcher.REQUESTER_SHARE());
        assertEq(launcher.REQUESTER_SHARE(), token.TOTAL_SUPPLY() / 50, "2% of the supply");
    }

    function test_launchEmitsTheLaunchFacts() public {
        bytes32 salt = mineSalt();
        address predicted = launcher.hookAddress(salt, address(token), address(rewards), address(lock));
        vm.expectEmit(true, true, false, false, address(launcher));
        emit DeezLaunch.Launched(address(token), predicted, address(rewards), address(lock), PoolId.wrap(0), 0, 0);
        vm.expectEmit(true, false, false, true, address(launcher));
        emit DeezLaunch.RequesterPaid(REQUESTER, 10_000_000 ether);
        vm.prank(REQUESTER);
        launcher.launch(address(token), address(rewards), address(lock), salt);
    }

    function test_poolTradesAfterLaunchAndTheHookTakesItsFee() public {
        DeezHook hook = doLaunch();
        PoolKey memory key = poolKey(hook);
        Swapper swapper = new Swapper(IPoolManager(address(manager)));
        imd.mint(address(swapper), 1_000 ether);
        // Buy $DEEZ with exactly 100 $IMD: 2% of it is the hook's fee, the rest buys from the locked depth.
        BalanceDelta delta = swapper.swap(key, !tokenIsCurrency0, -100 ether);
        int128 deezOut = tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        assertGt(deezOut, 0, "the buyer received $DEEZ");
        assertEq(token.balanceOf(address(swapper)), uint256(uint128(deezOut)));
        assertEq(hook.pendingFees(), 2 ether);
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(imd)).toId()), 2 ether);
        // The buyer can sell back; the pool now holds $IMD to pay with.
        delta = swapper.swap(key, tokenIsCurrency0, -int256(uint256(uint128(deezOut)) / 2));
        int128 imdOut = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
        assertGt(imdOut, 0);
        assertGt(hook.pendingFees(), 2 ether);
        // Anyone harvests into the distributor.
        uint256 harvested = hook.harvest();
        assertEq(harvested, hook.totalHarvested());
        assertEq(imd.balanceOf(address(rewards)), harvested);
    }

    function test_launchDayFeesGoToTheHoldersOfTheLaunchDay() public {
        // The factory transaction was at `setUp`; the requester launches at noon of the next UTC day, so the
        // launcher held the whole supply for half the launch day. Its holding earns nothing and dilutes nobody:
        // the holders of the rest of the day can claim the whole launch-day pot.
        uint256 epoch = block.timestamp / 1 days + 1;
        vm.warp(epoch * 1 days + 12 hours);
        DeezHook hook = doLaunch();
        PoolKey memory key = poolKey(hook);
        assertTrue(rewards.isExcluded(address(launcher)));
        assertEq(token.balanceOf(address(launcher)), 0);

        Swapper buyer = new Swapper(IPoolManager(address(manager)));
        imd.mint(address(buyer), 100 ether);
        buyer.swap(key, !tokenIsCurrency0, -100 ether);
        assertEq(hook.pendingFeesOf(epoch), 2 ether);

        vm.warp((epoch + 1) * 1 days + 1);
        hook.harvest();
        (uint128 pot,,,) = rewards.pots(epoch);
        assertEq(pot, 2 ether);
        assertGt(rewards.weightOf(address(launcher), epoch), rewards.eligibleSupplyAt(epoch), "it held most of the day");
        assertEq(rewards.claimable(address(launcher), epoch), 0, "the launcher is owed nothing");
        uint256 live = rewards.claimable(REQUESTER, epoch) + rewards.claimable(address(buyer), epoch)
            + rewards.claimable(address(lock), epoch);
        assertGe(live, uint256(pot) * 99 / 100, "the launch-day pot belongs to the launch-day holders");

        // The requester's 10,000,000 $DEEZ, held for the second half of the day, claims its share; the
        // launcher cannot claim at all.
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epoch;
        vm.prank(REQUESTER);
        uint256 paid = rewards.claim(REQUESTER, epochs);
        assertGt(paid, 0);
        assertEq(imd.balanceOf(REQUESTER), paid);
        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, address(launcher)));
        rewards.claim(address(launcher), epochs);
    }

    function test_launchedLiquidityCannotBeRemovedByAnyone() public {
        DeezHook hook = doLaunch();
        PoolKey memory key = poolKey(hook);
        (, int24 tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        // The lock has no function that removes liquidity, and the PoolManager only lets the position's owner (the
        // lock) modify it. The requester cannot act as the lock, and nobody can drive its callback directly.
        vm.prank(REQUESTER);
        vm.expectRevert(DeezLiquidityLock.NotPoolManager.selector);
        lock.unlockCallback(abi.encode(key, tick, tick, uint128(1)));
        Swapper outsider = new Swapper(IPoolManager(address(manager)));
        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (int24(launcher.TICK_SPACING()) * (tick / 60 + 1), TickMath.maxUsableTick(60))
            : (TickMath.minUsableTick(60), int24(launcher.TICK_SPACING()) * (tick / 60));
        if (tokenIsCurrency0 && tick < 0 && tick % 60 != 0) lower -= 60;
        if (!tokenIsCurrency0 && tick < 0 && tick % 60 != 0) upper -= 60;
        // An outsider removing from the same range only touches its own (empty) position: the PoolManager
        // refuses, and the lock's liquidity is untouched.
        uint128 before = lock.lockedLiquidity(keccak256(abi.encode(lower, upper)));
        assertGt(before, 0);
        vm.expectRevert();
        outsider.addLiquidity(key, lower, upper, -int256(uint256(before)));
        assertEq(lock.lockedLiquidity(keccak256(abi.encode(lower, upper))), before);
        assertGe(token.balanceOf(address(manager)), 989_999_000 ether);
    }

    // ------------------------------------------------------------------ refusals

    function test_launchRefusesEveryoneButTheRequester() public {
        bytes32 salt = mineSalt();
        vm.expectRevert(DeezLaunch.NotRequester.selector);
        launcher.launch(address(token), address(rewards), address(lock), salt);
        vm.prank(address(factory));
        vm.expectRevert(DeezLaunch.NotRequester.selector);
        launcher.launch(address(token), address(rewards), address(lock), salt);
        assertFalse(launcher.launched());
        assertEq(token.balanceOf(address(launcher)), token.TOTAL_SUPPLY());
    }

    function test_launchRunsOnce() public {
        doLaunch();
        bytes32 salt = mineSalt();
        vm.prank(REQUESTER);
        vm.expectRevert(DeezLaunch.AlreadyLaunched.selector);
        launcher.launch(address(token), address(rewards), address(lock), salt);
    }

    function test_launchRefusesASaltWithoutTheFlags() public {
        bytes32 salt = mineSalt();
        bytes32 wrong = bytes32(uint256(salt) + 1);
        address predicted = launcher.hookAddress(wrong, address(token), address(rewards), address(lock));
        assertFalse(HookFlags.matches(predicted, FLAGS));
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        launcher.launch(address(token), address(rewards), address(lock), wrong);
        assertFalse(launcher.launched(), "a reverted launch leaves nothing behind");
        assertEq(rewards.hook(), address(0));
    }

    function test_launchRefusesContractsThatAreNotItsOwn() public {
        bytes32 salt = mineSalt();
        // A token minted to the launcher that names it, but is not the factory's DeezToken: its distributor
        // does not match, and a distributor built on it is not the one the factory deployed.
        ImpostorToken fake = new ImpostorToken(address(launcher), address(launcher));
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(DeezLaunch.WrongRewards.selector, address(rewards)));
        launcher.launch(address(fake), address(rewards), address(lock), salt);

        // A distributor for another launcher.
        DeezRewards foreign = new DeezRewards(address(token), address(imd), address(manager), address(this));
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(DeezLaunch.WrongRewards.selector, address(foreign)));
        launcher.launch(address(token), address(foreign), address(lock), salt);

        // A lock on another distributor.
        DeezLiquidityLock otherLock = new DeezLiquidityLock(IPoolManager(address(manager)), address(foreign));
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(DeezLaunch.WrongLiquidityLock.selector, address(otherLock)));
        launcher.launch(address(token), address(rewards), address(otherLock), salt);

        // A token deployed for another launcher.
        DeezToken otherToken = new DeezToken(address(this));
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(DeezLaunch.WrongToken.selector, address(otherToken)));
        launcher.launch(address(otherToken), address(rewards), address(lock), salt);

        // Zero addresses and the pair currency itself.
        vm.prank(REQUESTER);
        vm.expectRevert(DeezLaunch.ZeroAddress.selector);
        launcher.launch(address(0), address(rewards), address(lock), salt);
        vm.prank(REQUESTER);
        vm.expectRevert(DeezLaunch.SameCurrency.selector);
        launcher.launch(address(imd), address(rewards), address(lock), salt);

        assertFalse(launcher.launched());
        assertEq(token.balanceOf(address(launcher)), token.TOTAL_SUPPLY());
    }

    function test_launchRefusesWhenTheSupplyIsNotHere() public {
        // A token that names the launcher but whose supply sits elsewhere.
        ImpostorToken drained = new ImpostorToken(address(launcher), address(this));
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(DeezLaunch.SupplyNotHere.selector, 0));
        launcher.launch(address(drained), address(rewards), address(lock), bytes32(0));
        // A launcher deployed alone cannot launch a token minted for another one.
        DeezLaunch lonely = new DeezLaunch(REQUESTER, IPoolManager(address(manager)), address(imd));
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(DeezLaunch.WrongToken.selector, address(token)));
        lonely.launch(address(token), address(rewards), address(lock), bytes32(0));
    }

    function test_constructorRefusesZeroAddresses() public {
        vm.expectRevert(DeezLaunch.ZeroAddress.selector);
        new DeezLaunch(address(0), IPoolManager(address(manager)), address(imd));
        vm.expectRevert(DeezLaunch.ZeroAddress.selector);
        new DeezLaunch(REQUESTER, IPoolManager(address(0)), address(imd));
        vm.expectRevert(DeezLaunch.ZeroAddress.selector);
        new DeezLaunch(REQUESTER, IPoolManager(address(manager)), address(0));
        vm.expectRevert(DeezToken.ZeroAddress.selector);
        new DeezToken(address(0));
        vm.expectRevert(DeezLiquidityLock.ZeroAddress.selector);
        new DeezLiquidityLock(IPoolManager(address(manager)), address(0));
    }

    function test_openingPriceIsTheSameValuationOnBothSides() public view {
        uint160 as0 = launcher.openingSqrtPriceX96(true);
        uint160 as1 = launcher.openingSqrtPriceX96(false);
        // sqrt(p) * sqrt(1/p) = 1, i.e. the two Q96 roots multiply to 2^192 (within the integer root's rounding).
        assertApproxEqRel(uint256(as0) * uint256(as1), 1 << 192, 1e9);
        assertGt(as0, TickMath.MIN_SQRT_PRICE);
        assertLt(as1, TickMath.MAX_SQRT_PRICE);
    }
}

contract DeezLaunchToken0Test is DeezLaunchTests {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract DeezLaunchToken1Test is DeezLaunchTests {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
