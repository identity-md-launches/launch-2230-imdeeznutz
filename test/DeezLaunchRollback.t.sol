// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {DeezLaunch} from "src/DeezLaunch.sol";
import {DeezToken} from "src/DeezToken.sol";
import {DeezRewards} from "src/DeezRewards.sol";
import {DeezLiquidityLock} from "src/DeezLiquidityLock.sol";
import {HookFlags} from "src/HookFlags.sol";
import {FactoryStandIn} from "./DeezLaunch.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice These test atomicity of the existing launch() call. Deployment-time locking is a separate
/// requirement, reported in .imd-findings.json; these tests do not claim that a later launch fixes it.
abstract contract DeezLaunchRollbackBase is Test {
    using StateLibrary for IPoolManager;

    address internal requester;
    DeezLaunch internal launcher;
    DeezToken internal token;
    DeezRewards internal rewards;
    DeezLiquidityLock internal liquidityLock;
    PoolManager internal manager;
    MockERC20 internal imd;
    bytes32 internal salt;
    address internal predictedHook;
    PoolKey internal key;

    error InitializationRejected();

    function wantToken0() internal pure virtual returns (bool);

    function setUp() public {
        vm.warp(1_700_000_003);
        requester = makeAddr("rollback-requester");
        manager = new PoolManager(address(this));
        FactoryStandIn factory = new FactoryStandIn();
        address predictedToken = vm.computeCreateAddress(address(factory), 2);
        for (uint256 i; i < 128; ++i) {
            imd = new MockERC20("IMD", "IMD", 0);
            if ((predictedToken < address(imd)) == wantToken0()) break;
        }
        (launcher, token, rewards, liquidityLock) = factory.deployAll(requester, manager, address(imd));
        assertEq(address(token) < address(imd), wantToken0());
        bytes32 codeHash = keccak256(launcher.hookInitCode(address(token), address(rewards), address(liquidityLock)));
        bool found;
        for (uint256 i; i < 300_000; ++i) {
            predictedHook = vm.computeCreate2Address(bytes32(i), codeHash, address(launcher));
            if (HookFlags.matches(predictedHook, 0x20cc)) {
                salt = bytes32(i);
                found = true;
                break;
            }
        }
        assertTrue(found, "salt search exhausted");
        (Currency c0, Currency c1) = wantToken0()
            ? (Currency.wrap(address(token)), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(address(token)));
        key = PoolKey(c0, c1, launcher.POOL_FEE(), launcher.TICK_SPACING(), IHooks(predictedHook));
    }

    function _launch() private {
        vm.prank(requester);
        launcher.launch(address(token), address(rewards), address(liquidityLock), salt);
    }

    function _assertRollback() private view {
        assertFalse(launcher.launched());
        assertEq(address(launcher.token()), address(0));
        assertEq(address(launcher.rewards()), address(0));
        assertEq(address(launcher.liquidityLock()), address(0));
        assertEq(address(launcher.hook()), address(0));
        assertEq(PoolId.unwrap(launcher.poolId()), bytes32(0));
        assertEq(rewards.hook(), address(0));
        assertEq(address(liquidityLock.hook()), address(0));
        assertEq(predictedHook.code.length, 0, "CREATE2 deployment survived a failed launch");
        assertEq(token.balanceOf(address(launcher)), token.TOTAL_SUPPLY());
        assertEq(token.balanceOf(requester), 0);
        assertEq(token.balanceOf(address(liquidityLock)), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.numCheckpoints(requester), 0);
        assertEq(token.numCheckpoints(address(liquidityLock)), 0);
        assertEq(liquidityLock.totalLocked0(), 0);
        assertEq(liquidityLock.totalLocked1(), 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, 0, "pool initialization survived a failed launch");
    }

    function _retrySameSalt() private {
        vm.clearMockedCalls();
        _launch();
        assertTrue(launcher.launched());
        assertEq(address(launcher.hook()), predictedHook);
        assertEq(token.balanceOf(requester), 10_000_000 ether);
        assertEq(token.balanceOf(address(launcher)), 0);
        assertGt(token.balanceOf(address(manager)), 989_999_000 ether);
    }

    function test_finalPayoutFailureRollsBackBothLiquidityAddsAndAllowsRetry() public {
        // Fail after the hook, pool, 98% seed and requester lock have already been created.
        vm.mockCall(
            address(token),
            abi.encodeCall(IERC20.transfer, (requester, launcher.PAID_REQUESTER_SHARE())),
            abi.encode(false)
        );
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        _launch();
        _assertRollback();
        _retrySameSalt();
    }

    function test_requesterLockTransferFailureRollsBackThePoolSeed() public {
        vm.mockCall(
            address(token),
            abi.encodeCall(IERC20.transfer, (address(liquidityLock), launcher.LOCKED_REQUESTER_SHARE())),
            abi.encode(false)
        );
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        _launch();
        _assertRollback();
        _retrySameSalt();
    }

    function test_poolInitializationFailureRollsBackHookDeploymentAndWiring() public {
        vm.mockCallRevert(
            address(manager),
            abi.encodeCall(IPoolManager.initialize, (key, launcher.openingSqrtPriceX96(wantToken0()))),
            abi.encodeWithSelector(InitializationRejected.selector)
        );
        vm.expectRevert(InitializationRejected.selector);
        _launch();
        _assertRollback();
        _retrySameSalt();
    }

    function test_requesterTransfersDirectlyToLockBeforeWalletPayoutWithinLaunchCall() public {
        vm.recordLogs();
        _launch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        bytes32 lockedTopic = keccak256("Locked(int24,int24,uint128,uint256,uint256)");
        uint256 transfers;
        uint256 locks;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter == address(liquidityLock) && entry.topics[0] == lockedTopic) {
                ++locks;
                assertEq(locks, transfers, "each lock follows its direct allocation transfer");
                (,, uint128 liquidity,,) = abi.decode(entry.data, (int24, int24, uint128, uint256, uint256));
                assertGt(liquidity, 0);
            }
            if (entry.emitter != address(token) || entry.topics[0] != transferTopic) continue;
            if (address(uint160(uint256(entry.topics[1]))) != address(launcher)) continue;
            address to = address(uint160(uint256(entry.topics[2])));
            uint256 amount = abi.decode(entry.data, (uint256));
            if (transfers == 0) {
                assertEq(to, address(liquidityLock));
                assertEq(amount, 980_000_000 ether);
            } else if (transfers == 1) {
                assertEq(locks, 1);
                assertEq(to, address(liquidityLock));
                assertGe(amount, 10_000_000 ether);
            } else {
                assertEq(transfers, 2, "unexpected extra launcher transfer");
                assertEq(locks, 2, "wallet paid before requester liquidity locked");
                assertEq(to, requester);
                assertEq(amount, 10_000_000 ether);
            }
            ++transfers;
        }
        assertEq(transfers, 3);
        assertEq(locks, 2);
    }
}

contract DeezLaunchRollbackToken0Test is DeezLaunchRollbackBase {
    function wantToken0() internal pure override returns (bool) {
        return true;
    }
}

contract DeezLaunchRollbackToken1Test is DeezLaunchRollbackBase {
    function wantToken0() internal pure override returns (bool) {
        return false;
    }
}
