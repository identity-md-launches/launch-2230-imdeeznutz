// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DeezToken} from "src/DeezToken.sol";
import {DeezRewards} from "src/DeezRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";

/// @notice A controllably failing external dependency. It does not alter the DEEZ implementation.
contract RefusingRewardToken is MockERC20 {
    uint256 public mode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    error TransferRefused();

    constructor() MockERC20("Test IMD", "IMD", 0) {}

    function setMode(uint256 mode_) external {
        mode = mode_;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == 1) return false;
        if (mode == 2) revert TransferRefused();
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
        return super.transfer(to, amount);
    }
}

contract DeezRewardsTransferFailuresTest is Test {
    uint256 private constant EPOCH = 100;
    DeezToken private token;
    DeezRewards private rewards;
    RefusingRewardToken private imd;
    MockHook private hook;
    address private alice;

    function setUp() public {
        vm.warp(EPOCH * 1 days);
        alice = makeAddr("claim-alice");
        token = new DeezToken(alice);
        imd = new RefusingRewardToken();
        rewards = new DeezRewards(address(token), address(imd), makeAddr("claim-pool-manager"), address(this));
        hook = new MockHook();
        hook.init(imd, rewards);
        rewards.setHook(address(hook));
        hook.setPending(EPOCH, 100 ether);
        imd.mint(address(rewards), 25 ether); // unaccrued donation in addition to pending fees
        vm.warp((EPOCH + 1) * 1 days);
    }

    function _epochs() private pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = EPOCH;
    }

    function _assertRevertedState() private view {
        assertEq(rewards.reserved(), 0);
        assertEq(rewards.paidOf(EPOCH, alice), 0);
        (uint128 total, uint128 claimed, uint256 supply, bool closed) = rewards.pots(EPOCH);
        assertEq(total, 0);
        assertEq(claimed, 0);
        assertEq(supply, 0, "failed payout must roll back finalization");
        assertFalse(closed);
        (total, claimed,,) = rewards.pots(EPOCH + 1);
        assertEq(total, 0, "failed payout must roll back donation accrual");
        assertEq(claimed, 0);
        assertEq(imd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(address(rewards)), 25 ether);
        assertEq(imd.totalSupply(), 25 ether, "harvest's funding must also roll back");
        assertEq(hook.pendingFeesOf(EPOCH), 100 ether);
        assertEq(hook.harvestCalls(), 0);
    }

    function _retry() private {
        imd.setMode(0);
        vm.prank(alice);
        assertEq(rewards.claim(alice, _epochs()), 100 ether);
        assertEq(imd.balanceOf(alice), 100 ether);
        assertEq(imd.balanceOf(address(rewards)), 25 ether);
        assertEq(rewards.reserved(), 25 ether);
        assertEq(rewards.paidOf(EPOCH, alice), 100 ether);
        assertEq(hook.pendingFeesOf(EPOCH), 0);
        assertEq(hook.harvestCalls(), 1);
        (uint128 total, uint128 claimed,,) = rewards.pots(EPOCH);
        assertEq(total, 100 ether);
        assertEq(claimed, 100 ether);
        (total, claimed,,) = rewards.pots(EPOCH + 1);
        assertEq(total, 25 ether);
        assertEq(claimed, 0);
    }

    function test_falseReturningPayoutRollsBackHarvestAccrualAndClaim() public {
        imd.setMode(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        rewards.claim(alice, _epochs());
        _assertRevertedState();
        _retry();
    }

    function test_revertingPayoutRollsBackHarvestAccrualAndClaim() public {
        imd.setMode(2);
        vm.prank(alice);
        vm.expectRevert(RefusingRewardToken.TransferRefused.selector);
        rewards.claim(alice, _epochs());
        _assertRevertedState();
        _retry();
    }

    function test_payoutCallbackCannotReenterClaimAndOuterClaimCompletesOnce() public {
        imd.setCallback(address(rewards), abi.encodeCall(DeezRewards.claim, (alice, _epochs())));
        vm.prank(alice);
        assertEq(rewards.claim(alice, _epochs()), 100 ether);
        assertFalse(imd.callbackSucceeded());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(imd.balanceOf(alice), 100 ether);
        assertEq(rewards.paidOf(EPOCH, alice), 100 ether);
        assertEq(rewards.reserved(), 25 ether);
        assertEq(hook.harvestCalls(), 1);
    }
}
