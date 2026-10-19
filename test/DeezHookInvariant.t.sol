// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeezBase} from "./DeezBase.t.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {DeezToken} from "../src/DeezToken.sol";
import {DeezHook} from "../src/DeezHook.sol";
import {DeezRewards} from "../src/DeezRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";

/// @notice Random buys and sells of both kinds, harvests, donations and time on a live pool. Every swap checks its
/// own fee against 2% of the gross $IMD that changed hands; the invariants check that every fee is accounted for.
contract HookHandler is Test {
    uint256 internal constant FEE_BPS = 200;
    uint256 internal constant BPS = 10_000;

    PoolManager public manager;
    DeezToken public token;
    MockERC20 public imd;
    DeezHook public hook;
    DeezRewards public rewards;
    Swapper public swapper;
    bool public tokenIsCurrency0;
    PoolKey internal key;

    uint256 public ghostFees;
    uint256 public ghostDonated;
    uint256 public swaps;
    /// @dev Set when one swap's fee is off 2% of its gross $IMD by more than one wei.
    bool public feeOff;

    constructor(
        PoolManager manager_,
        DeezToken token_,
        MockERC20 imd_,
        DeezHook hook_,
        Swapper swapper_,
        PoolKey memory key_,
        bool tokenIsCurrency0_
    ) {
        manager = manager_;
        token = token_;
        imd = imd_;
        hook = hook_;
        rewards = hook_.rewards();
        swapper = swapper_;
        key = key_;
        tokenIsCurrency0 = tokenIsCurrency0_;
    }

    function _swap(bool isBuy, int256 amountSpecified) internal {
        uint256 imdBefore = imd.balanceOf(address(swapper));
        uint256 pendingBefore = hook.pendingFees();
        bool zeroForOne = isBuy ? !tokenIsCurrency0 : tokenIsCurrency0;
        try swapper.swap(key, zeroForOne, amountSpecified) {
            uint256 fee = hook.pendingFees() - pendingBefore;
            uint256 imdAfter = imd.balanceOf(address(swapper));
            // Gross $IMD of the trade: what the buyer paid, or what the seller got plus the fee.
            uint256 gross = isBuy ? imdBefore - imdAfter : imdAfter - imdBefore + fee;
            uint256 expected = gross * FEE_BPS / BPS;
            if (fee > expected + 1 || fee + 1 < expected) feeOff = true;
            ghostFees += fee;
            swaps++;
        } catch {}
    }

    function buyExactIn(uint256 amount) external {
        _swap(true, -int256(bound(amount, 1, 50_000 ether)));
    }

    function buyExactOut(uint256 amount) external {
        _swap(true, int256(bound(amount, 1, 50_000 ether)));
    }

    function sellExactIn(uint256 amount) external {
        _swap(false, -int256(bound(amount, 1, 50_000 ether)));
    }

    function sellExactOut(uint256 amount) external {
        _swap(false, int256(bound(amount, 1, 50_000 ether)));
    }

    function harvest() external {
        hook.harvest();
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1_000 ether);
        imd.mint(address(rewards), amount);
        ghostDonated += amount;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }
}

abstract contract DeezHookInvariantBase is DeezBase {
    HookHandler handler;

    function setUp() public override {
        super.setUp();
        seedBalanced(10_000_000 ether);
        handler = new HookHandler(manager, token, imd, hook, swapper, key, tokenIsCurrency0);
        targetContract(address(handler));
    }

    function invariant_everyFeeIsTwoPercentOfTheGrossImd() public view {
        assertFalse(handler.feeOff());
    }

    function invariant_pendingFeesAreExactlyTheHookClaims() public view {
        assertEq(hookClaims(), hook.pendingFees());
    }

    function invariant_everyFeeIsPendingOrHarvested() public view {
        assertEq(hook.pendingFees() + hook.totalHarvested(), handler.ghostFees());
    }

    function invariant_harvestedImdSitsInTheDistributor() public view {
        assertEq(imd.balanceOf(address(rewards)), hook.totalHarvested() + handler.ghostDonated());
        assertGe(imd.balanceOf(address(rewards)), rewards.reserved());
    }

    function invariant_claimsAreBackedByTheManager() public view {
        assertGe(imd.balanceOf(address(manager)), hookClaims());
    }

    function invariant_hookAndDistributorHoldNoDeez() public view {
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(rewards)), 0);
        assertEq(token.totalSupply(), 1e27);
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 40
contract DeezHookInvariantToken0Test is DeezHookInvariantBase {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 40
contract DeezHookInvariantToken1Test is DeezHookInvariantBase {
    function wantTokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
