// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {DeezLaunch} from "src/DeezLaunch.sol";
import {DeezToken} from "src/DeezToken.sol";
import {DeezRewards} from "src/DeezRewards.sol";
import {DeezLiquidityLock} from "src/DeezLiquidityLock.sol";
import {HookFlags} from "src/HookFlags.sol";
import {FactoryStandIn} from "./DeezLaunch.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Custody and authorization properties for the existing launch state machine. These do not
/// replace the reported requirement that deployment itself must complete the lock allocation.
contract DeezLaunchLifecycleHandler is Test {
    DeezLaunch public immutable launcher;
    DeezToken public immutable token;
    DeezRewards public immutable rewards;
    DeezLiquidityLock public immutable liquidityLock;
    bytes32 private immutable goodSalt;
    bytes32 private immutable badSalt;
    address public immutable predictedHook;
    address[3] public actors;
    uint256[3] public walletLedger;
    uint256 public successfulLaunches;
    uint256 public rejectedLaunches;
    uint256 public transfers;

    constructor(
        DeezLaunch launcher_,
        DeezToken token_,
        DeezRewards rewards_,
        DeezLiquidityLock lock_,
        bytes32 good_,
        bytes32 bad_,
        address[3] memory actors_
    ) {
        launcher = launcher_;
        token = token_;
        rewards = rewards_;
        liquidityLock = lock_;
        goodSalt = good_;
        badSalt = bad_;
        actors = actors_;
        predictedHook = launcher_.hookAddress(good_, address(token_), address(rewards_), address(lock_));
    }

    function attempt(uint256 callerSeed, uint256 inputSeed) public {
        address caller = actors[callerSeed % 3];
        uint256 shape = inputSeed % 6;
        address tokenArg = shape == 2 ? address(0) : shape == 5 ? launcher.pairedCurrency() : address(token);
        address rewardsArg = shape == 3 ? address(0) : address(rewards);
        address lockArg = shape == 4 ? address(0) : address(liquidityLock);
        bytes32 salt = shape == 1 ? badSalt : goodSalt;
        bytes memory expectedError;
        if (caller != actors[0]) {
            expectedError = abi.encodeWithSelector(DeezLaunch.NotRequester.selector);
        } else if (successfulLaunches > 0) {
            expectedError = abi.encodeWithSelector(DeezLaunch.AlreadyLaunched.selector);
        } else if (shape >= 2 && shape <= 4) {
            expectedError = abi.encodeWithSelector(DeezLaunch.ZeroAddress.selector);
        } else if (shape == 5) {
            expectedError = abi.encodeWithSelector(DeezLaunch.SameCurrency.selector);
        } else if (shape == 1) {
            expectedError = abi.encodeWithSelector(
                Hooks.HookAddressNotValid.selector,
                launcher.hookAddress(salt, address(token), address(rewards), address(liquidityLock))
            );
        }
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(launcher).call(abi.encodeCall(DeezLaunch.launch, (tokenArg, rewardsArg, lockArg, salt)));
        if (expectedError.length > 0) {
            assertFalse(ok, "invalid launch succeeded");
            assertEq(data, expectedError, "wrong rejection path");
            ++rejectedLaunches;
        } else {
            assertTrue(ok, "valid requester launch failed");
            assertEq(abi.decode(data, (address)), predictedHook);
            ++successfulLaunches;
            walletLedger[0] += 10_000_000 ether;
        }
    }

    function launchAsRequester() external {
        attempt(0, 0);
    }

    function movePayout(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % 3;
        uint256 to = toSeed % 3;
        uint256 amount = bound(amountSeed, 0, walletLedger[from]);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        walletLedger[from] -= amount;
        walletLedger[to] += amount;
        ++transfers;
    }

    function checkCustodyAndOneShotState() external view {
        uint256 held = token.balanceOf(address(launcher)) + token.balanceOf(address(liquidityLock))
            + token.balanceOf(address(launcher.poolManager()));
        for (uint256 i; i < 3; ++i) {
            assertEq(token.balanceOf(actors[i]), walletLedger[i], "unexpected requester allocation");
            held += walletLedger[i];
        }
        assertEq(held, token.TOTAL_SUPPLY(), "launch custody does not conserve supply");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertLe(successfulLaunches, 1, "launch succeeded twice");
        assertEq(launcher.launched(), successfulLaunches == 1);
        if (successfulLaunches == 0) return;
        assertEq(address(launcher.hook()), predictedHook);
        assertEq(rewards.hook(), predictedHook);
        assertEq(address(liquidityLock.hook()), predictedHook);
        assertEq(token.balanceOf(address(launcher)), 0);
        uint256 locked = token.balanceOf(address(liquidityLock)) + token.balanceOf(address(launcher.poolManager()));
        assertEq(locked, 990_000_000 ether, "requester or repeat caller reclaimed locked allocation");
        assertEq(walletLedger[0] + walletLedger[1] + walletLedger[2], 10_000_000 ether);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
contract DeezLaunchLifecycleInvariantTest is Test {
    DeezLaunchLifecycleHandler private handler;

    function setUp() public {
        vm.warp(1_700_000_009);
        PoolManager manager = new PoolManager(address(this));
        MockERC20 imd = new MockERC20("IMD", "IMD", 0);
        address[3] memory actors =
            [makeAddr("lifecycle-requester"), makeAddr("lifecycle-alice"), makeAddr("lifecycle-bob")];
        FactoryStandIn factory = new FactoryStandIn();
        (DeezLaunch launcher, DeezToken token, DeezRewards rewards, DeezLiquidityLock lock) =
            factory.deployAll(actors[0], manager, address(imd));
        bytes32 codeHash = keccak256(launcher.hookInitCode(address(token), address(rewards), address(lock)));
        bytes32 good;
        bytes32 bad;
        bool found;
        for (uint256 i; i < 300_000; ++i) {
            address candidate = vm.computeCreate2Address(bytes32(i), codeHash, address(launcher));
            if (HookFlags.matches(candidate, 0x20cc)) {
                good = bytes32(i);
                found = true;
                break;
            }
            bad = bytes32(i);
        }
        assertTrue(found, "salt search exhausted");
        // Independently establish the invalid salt, including the rare valid-zero-salt case.
        while (HookFlags.matches(vm.computeCreate2Address(bad, codeHash, address(launcher)), 0x20cc)) {
            bad = bytes32(uint256(bad) + 1);
        }
        handler = new DeezLaunchLifecycleHandler(launcher, token, rewards, lock, good, bad, actors);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.attempt.selector;
        selectors[1] = handler.launchAsRequester.selector;
        selectors[2] = handler.movePayout.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_custodyIsConservedAndOnlyOneRequesterLaunchCanSucceed() public view {
        handler.checkCustodyAndOneShotState();
    }

    function test_failedAttemptsThenSuccessThenReplay() public {
        handler.attempt(0, 1);
        handler.attempt(2, 0);
        handler.attempt(0, 2);
        handler.launchAsRequester();
        handler.movePayout(0, 1, 10_000_000 ether);
        handler.launchAsRequester();
        assertEq(handler.successfulLaunches(), 1);
        assertEq(handler.rejectedLaunches(), 4);
        assertEq(handler.transfers(), 1);
        handler.checkCustodyAndOneShotState();
    }
}
