// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DeezLaunch} from "src/DeezLaunch.sol";
import {DeezToken} from "src/DeezToken.sol";
import {DeezHook} from "src/DeezHook.sol";
import {DeezRewards} from "src/DeezRewards.sol";
import {DeezLiquidityLock} from "src/DeezLiquidityLock.sol";
import {HookFlags} from "src/HookFlags.sol";
import {FactoryStandIn} from "./DeezLaunch.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

/// @notice A third party building a complete set of contracts that name an existing launcher.
contract LookAlikeBuilder {
    function build(DeezLaunch launcher, IPoolManager manager, address imd)
        external
        returns (DeezToken token, DeezRewards rewards, DeezLiquidityLock lock)
    {
        token = new DeezToken(address(launcher));
        rewards = new DeezRewards(address(token), imd, address(manager), address(launcher));
        lock = new DeezLiquidityLock(manager, address(rewards));
    }
}

/// @notice The launcher holds the whole supply from the factory transaction until `launch`. These tests launch at
/// a random second of the launch day and check that the launcher's holding neither earns nor dilutes: the day's
/// pot is split over the holders that can claim, and the launcher cannot claim at all.
contract DeezLauncherExclusionTest is Test {
    uint160 internal constant FLAGS = 0x20cc;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant T0 = 1_700_006_400; // 00:00:00 UTC of epoch 19,676
    address internal constant REQUESTER = address(0xB045);

    PoolManager internal manager;
    MockERC20 internal imd;
    DeezLaunch internal launcher;
    DeezToken internal token;
    DeezRewards internal rewards;
    DeezLiquidityLock internal lock;
    bytes32 internal salt;

    function setUp() public {
        vm.warp(T0);
        manager = new PoolManager(address(this));
        imd = new MockERC20("IMD", "IMD", 0);
        FactoryStandIn factory = new FactoryStandIn();
        (launcher, token, rewards, lock) = factory.deployAll(REQUESTER, IPoolManager(address(manager)), address(imd));
        salt = mine(address(token), address(rewards), address(lock));
    }

    function mine(address token_, address rewards_, address lock_) internal view returns (bytes32) {
        bytes32 codeHash = keccak256(launcher.hookInitCode(token_, rewards_, lock_));
        for (uint256 i; i < 300_000; ++i) {
            if (HookFlags.matches(vm.computeCreate2Address(bytes32(i), codeHash, address(launcher)), FLAGS)) {
                return bytes32(i);
            }
        }
        revert("no salt found");
    }

    function key(DeezHook hook) internal view returns (PoolKey memory) {
        bool tokenIsCurrency0 = address(token) < address(imd);
        (Currency c0, Currency c1) = tokenIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(token)));
        return PoolKey(c0, c1, launcher.POOL_FEE(), launcher.TICK_SPACING(), IHooks(address(hook)));
    }

    function one(uint256 epoch) internal pure returns (uint256[] memory epochs) {
        epochs = new uint256[](1);
        epochs[0] = epoch;
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_launchDayPotIgnoresLauncherHolding(uint256 offsetSeed, uint256 buySeed, uint256 returnSeed)
        public
    {
        uint256 epoch = T0 / DAY + 1;
        // The factory transaction was the day before; the launch lands at any second of the launch day.
        uint256 offset = bound(offsetSeed, 0, DAY - 1);
        uint256 buy = bound(buySeed, 1 ether, 1_000 ether);
        vm.warp(epoch * DAY + offset);
        vm.prank(REQUESTER);
        DeezHook hook = launcher.launch(address(token), address(rewards), address(lock), salt);
        assertEq(token.balanceOf(address(launcher)), 0);

        Swapper buyer = new Swapper(IPoolManager(address(manager)));
        imd.mint(address(buyer), buy);
        buyer.swap(key(hook), address(token) > address(imd), -int256(buy));
        uint256 bought = token.balanceOf(address(buyer));
        assertGt(bought, 0);
        assertGt(hook.pendingFeesOf(epoch), 0, "the launch-day buy paid a fee");
        // Some of it is sent to the launcher, where nothing can ever move it again; it must not dilute either.
        uint256 returned = bound(returnSeed, 0, bought);
        vm.prank(address(buyer));
        token.transfer(address(launcher), returned);

        vm.warp((epoch + 1) * DAY + 1);
        hook.harvest();
        (uint128 pot,,,) = rewards.pots(epoch);
        assertGt(pot, 0);

        uint256 eligible = rewards.eligibleSupplyAt(epoch);
        uint256 launcherWeight = rewards.weightOf(address(launcher), epoch);
        assertApproxEqAbs(launcherWeight, token.TOTAL_SUPPLY() * offset / DAY + returned * (DAY - offset) / DAY, 2);
        assertApproxEqAbs(
            eligible,
            rewards.weightOf(REQUESTER, epoch) + rewards.weightOf(address(buyer), epoch)
                + rewards.weightOf(address(lock), epoch),
            4,
            "eligible supply is exactly the holders that are not excluded"
        );
        assertEq(rewards.claimable(address(launcher), epoch), 0);

        uint256 lockShare = rewards.claimable(address(lock), epoch);
        uint256 requesterShare = rewards.claimable(REQUESTER, epoch);
        uint256 buyerShare = rewards.claimable(address(buyer), epoch);
        assertLe(requesterShare + buyerShare + lockShare, pot, "never more than the pot");
        assertGe(requesterShare + buyerShare + lockShare + 4, pot, "the launcher's holding takes no part");

        vm.prank(REQUESTER);
        assertEq(rewards.claim(REQUESTER, one(epoch)), requesterShare);
        if (buyerShare > 0) {
            vm.prank(address(buyer));
            assertEq(rewards.claim(address(buyer), one(epoch)), buyerShare);
        }
        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(DeezRewards.Excluded.selector, address(launcher)));
        rewards.claim(address(launcher), one(epoch));
        assertEq(imd.balanceOf(address(rewards)), rewards.reserved(), "reward custody matches what is owed");
    }

    function test_launchInTheLastSecondOfTheDayStillPaysTheWholePot() public {
        uint256 epoch = T0 / DAY + 1;
        vm.warp((epoch + 1) * DAY - 1);
        vm.prank(REQUESTER);
        DeezHook hook = launcher.launch(address(token), address(rewards), address(lock), salt);
        Swapper buyer = new Swapper(IPoolManager(address(manager)));
        imd.mint(address(buyer), 50 ether);
        buyer.swap(key(hook), address(token) > address(imd), -50 ether);
        vm.warp((epoch + 1) * DAY);
        hook.harvest();
        (uint128 pot,,,) = rewards.pots(epoch);
        assertGt(pot, 0);
        // The launcher held 999,999 / 1,000,000 of the supply-seconds of the day, and it is still excluded.
        assertGt(rewards.weightOf(address(launcher), epoch), 999 * rewards.eligibleSupplyAt(epoch));
        vm.prank(REQUESTER);
        uint256 paid = rewards.claim(REQUESTER, one(epoch));
        vm.prank(address(buyer));
        paid += rewards.claim(address(buyer), one(epoch));
        assertLe(paid, pot);
        assertGe(paid + rewards.claimable(address(lock), epoch) + 4, pot);
    }

    function test_noLaunchMeansNoPotAndNoClaimForAnyone() public {
        // Before launch the launcher holds everything, no hook exists, and nothing can be claimed or credited.
        vm.warp(T0 + 3 * DAY);
        assertEq(rewards.claimable(address(launcher), T0 / DAY), 0);
        assertEq(rewards.eligibleSupplyAt(T0 / DAY), 0, "the launcher's whole-day holding is not eligible");
        vm.prank(REQUESTER);
        vm.expectRevert(DeezRewards.HookNotSet.selector);
        rewards.claim(REQUESTER, one(T0 / DAY));
        vm.expectRevert(DeezRewards.NotHook.selector);
        rewards.credit(T0 / DAY, 0);
    }

    /// The launcher can only check that the contracts it is given are consistent with it, as its notice states:
    /// anyone can build a complete set naming it, and the requester can launch with that set. The factory's token
    /// then stays in the launcher forever. This test pins the published cross-check (compare `token()`,
    /// `rewards()` and `liquidityLock()` with the factory record) rather than blessing the outcome; see the info
    /// finding in `.imd-findings.json`.
    function test_lookAlikeSetPassesTheConsistencyChecksSoPublishersMustCrossCheck() public {
        LookAlikeBuilder builder = new LookAlikeBuilder();
        (DeezToken fakeToken, DeezRewards fakeRewards, DeezLiquidityLock fakeLock) =
            builder.build(launcher, IPoolManager(address(manager)), address(imd));
        assertEq(fakeToken.balanceOf(address(launcher)), fakeToken.TOTAL_SUPPLY());
        bytes32 fakeSalt = mine(address(fakeToken), address(fakeRewards), address(fakeLock));

        // A stranger cannot use it.
        vm.prank(address(builder));
        vm.expectRevert(DeezLaunch.NotRequester.selector);
        launcher.launch(address(fakeToken), address(fakeRewards), address(fakeLock), fakeSalt);
        // A mixed set (the real token with look-alike rewards) is refused.
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(DeezLaunch.WrongRewards.selector, address(fakeRewards)));
        launcher.launch(address(token), address(fakeRewards), address(lock), salt);
        vm.prank(REQUESTER);
        vm.expectRevert(abi.encodeWithSelector(DeezLaunch.WrongLiquidityLock.selector, address(fakeLock)));
        launcher.launch(address(token), address(rewards), address(fakeLock), salt);

        vm.prank(REQUESTER);
        launcher.launch(address(fakeToken), address(fakeRewards), address(fakeLock), fakeSalt);
        // What a publisher reads after launch differs from the factory's record, which is how it is caught.
        assertTrue(address(launcher.token()) != address(token));
        assertTrue(address(launcher.rewards()) != address(rewards));
        assertTrue(address(launcher.liquidityLock()) != address(lock));
        assertEq(token.balanceOf(address(launcher)), token.TOTAL_SUPPLY(), "the factory token never left");
        vm.prank(REQUESTER);
        vm.expectRevert(DeezLaunch.AlreadyLaunched.selector);
        launcher.launch(address(token), address(rewards), address(lock), salt);
    }
}
