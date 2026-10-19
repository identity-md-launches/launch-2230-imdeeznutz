// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeezToken} from "../src/DeezToken.sol";
import {DeezRewards} from "../src/DeezRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockHook} from "./mocks/MockHook.sol";

/// @notice Drives the distributor in random order: holders move $DEEZ (also into and out of the excluded pool),
/// $IMD arrives with and without `accrue`, the hook holds unharvested fees of past and current epochs (which a
/// claim harvests, or anyone does), time passes (sometimes past the claim window), holders claim, third
/// parties try to claim for them, epochs are finalized and recycled. Ghosts record what went in and what came out.
contract RewardsHandler is Test {
    uint256 internal constant EPOCH = 1 days;

    DeezToken public token;
    MockERC20 public imd;
    DeezRewards public rewards;
    MockHook public hook;
    address public poolManager;

    address[] public actors;
    /// @dev Every epoch that ever received $IMD (accrual or recycle), so the invariants can sum the pots.
    uint256[] public touchedEpochs;
    mapping(uint256 => bool) internal touched;

    uint256 public ghostMinted;
    uint256 public ghostPaid;
    mapping(address => uint256) public ghostPaidTo;
    uint256 public ghostClaims;
    uint256 public ghostRecycles;
    /// @dev Unharvested fees the hook still holds, per epoch, summed: minted to the distributor only on harvest.
    uint256 public ghostPending;
    /// @dev Set when a claim paid more than the claimant's balance share of the pot.
    bool public overpaid;
    /// @dev Set when a claim or recycle reopened an epoch that was already closed.
    bool public reopened;
    /// @dev Set when someone other than the account managed to claim its share.
    bool public claimedByOther;

    constructor(
        DeezToken token_,
        MockERC20 imd_,
        DeezRewards rewards_,
        MockHook hook_,
        address poolManager_,
        address[] memory actors_
    ) {
        token = token_;
        imd = imd_;
        rewards = rewards_;
        hook = hook_;
        poolManager = poolManager_;
        actors = actors_;
    }

    function touchedCount() external view returns (uint256) {
        return touchedEpochs.length;
    }

    function _touch(uint256 epoch) internal {
        if (!touched[epoch]) {
            touched[epoch] = true;
            touchedEpochs.push(epoch);
        }
    }

    /// @dev Actors plus the pool manager (excluded) and the burn address (excluded, receive only).
    function _holder(uint256 seed, bool canSend) internal view returns (address) {
        uint256 n = actors.length + (canSend ? 1 : 2);
        uint256 i = seed % n;
        if (i < actors.length) return actors[i];
        if (i == actors.length) return poolManager;
        return rewards.BURN_ADDRESS();
    }

    function _epoch(uint256 seed) internal view returns (uint256) {
        if (touchedEpochs.length == 0 || seed % 4 == 0) return rewards.currentEpoch() - (seed % 3);
        return touchedEpochs[seed % touchedEpochs.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _holder(fromSeed, true);
        address to = _holder(toSeed, false);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 0, balance);
        vm.prank(from);
        token.transfer(to, amount);
    }

    function fund(uint256 amount, bool doAccrue) external {
        amount = bound(amount, 0, 1e30);
        imd.mint(address(rewards), amount);
        ghostMinted += amount;
        if (doAccrue) {
            uint256 credited = rewards.accrue();
            if (credited > 0) _touch(rewards.currentEpoch());
        }
    }

    /// @dev A fee traded in `epoch` (past or current) that the hook has not harvested yet.
    function lateFee(uint256 epochSeed, uint256 amount) external {
        uint256 epoch = _epoch(epochSeed);
        amount = bound(amount, 0, 1e30);
        hook.setPending(epoch, hook.pendingFeesOf(epoch) + amount);
        ghostPending += amount;
        _touch(epoch);
    }

    /// @dev Anyone harvests the hook's pending fees of some epochs.
    function harvest(uint256 epochSeed) external {
        uint256[] memory list = new uint256[](1);
        list[0] = _epoch(epochSeed);
        uint256 pending = hook.pendingFeesOf(list[0]);
        hook.harvestEpochs(list);
        ghostPending -= pending;
        ghostMinted += pending;
        _touch(rewards.currentEpoch()); // a closed epoch's late fees are credited to the current one
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 3 days);
        vm.warp(block.timestamp + secs);
    }

    function warpPastClaimWindow(uint256 extra) external {
        extra = bound(extra, 0, 2 days);
        vm.warp(block.timestamp + (rewards.CLAIM_WINDOW() + 1) * EPOCH + extra);
    }

    function claim(uint256 actorSeed, uint256 epochSeed) external {
        address account = _holder(actorSeed, true);
        uint256 epoch = _epoch(epochSeed);
        uint256[] memory list = new uint256[](1);
        list[0] = epoch;

        (uint128 totalBefore, uint128 claimedBefore,, bool closedBefore) = rewards.pots(epoch);
        uint256 pending = hook.pendingFeesOf(epoch);
        bool ended = rewards.hasEnded(epoch);
        uint256 weight = ended ? rewards.weightOf(account, epoch) : 0;
        uint256 before = imd.balanceOf(account);
        uint256 paidBefore = rewards.paidOf(epoch, account);

        vm.prank(account);
        try rewards.claim(account, list) returns (uint256 paid) {
            if (closedBefore) reopened = true;
            // `claim` harvests the epoch's pending fees, then accrues un-accrued $IMD to the current epoch.
            ghostPending -= pending;
            ghostMinted += pending;
            _touch(rewards.currentEpoch());
            (uint128 totalAfter, uint128 claimedAfter, uint256 supply,) = rewards.pots(epoch);
            assertEq(totalAfter, uint256(totalBefore) + pending, "an ended pot grows only by its harvested fees");
            assertEq(claimedAfter - claimedBefore, paid, "pot claimed tracks the payout");
            assertEq(imd.balanceOf(account) - before, paid, "payout reaches the account");
            assertEq(rewards.paidOf(epoch, account) - paidBefore, paid, "paidOf tracks the payout");
            // Everything ever paid for the epoch <= pot * averageBalance / eligibleSupply.
            if (supply == 0 || (paidBefore + paid) * supply > uint256(totalAfter) * weight) overpaid = true;
            ghostPaid += paid;
            ghostPaidTo[account] += paid;
            ghostClaims++;
        } catch {}
    }

    /// @dev A third party tries to claim an account's share; it must never succeed.
    function claimFor(uint256 actorSeed, uint256 epochSeed, address caller) external {
        address account = _holder(actorSeed, true);
        if (caller == account) return;
        uint256[] memory list = new uint256[](1);
        list[0] = _epoch(epochSeed);
        vm.prank(caller);
        try rewards.claim(account, list) {
            claimedByOther = true;
        } catch {}
    }

    function finalize(uint256 epochSeed) external {
        try rewards.finalize(_epoch(epochSeed)) {} catch {}
    }

    function recycle(uint256 epochSeed) external {
        uint256 epoch = _epoch(epochSeed);
        (,,, bool closedBefore) = rewards.pots(epoch);
        try rewards.recycle(epoch) returns (uint256 amount) {
            if (closedBefore) reopened = true;
            ghostRecycles++;
            if (amount > 0) _touch(rewards.currentEpoch());
        } catch {}
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 60
contract DeezRewardsInvariantTest is Test {
    uint256 constant SUPPLY = 1e27;

    DeezToken token;
    MockERC20 imd;
    DeezRewards rewards;
    RewardsHandler handler;
    address poolManager = address(0x9001);
    MockHook mockHook;
    address[] actors;

    function setUp() public {
        vm.warp(100 days + 7);
        token = new DeezToken(address(this));
        imd = new MockERC20("IMD", "IMD", 0);
        mockHook = new MockHook();
        rewards = new DeezRewards(address(token), address(imd), poolManager, address(this));
        mockHook.init(imd, rewards);
        rewards.setHook(address(mockHook));

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(address(0xD00D));
        token.transfer(poolManager, 880_000_000 ether);
        token.transfer(actors[0], 100_000_000 ether);
        token.transfer(actors[1], 15_000_000 ether);
        token.transfer(actors[2], 5_000_000 ether);
        token.transfer(actors[3], token.balanceOf(address(this)));

        handler = new RewardsHandler(token, imd, rewards, mockHook, poolManager, actors);
        targetContract(address(handler));
    }

    /// @dev Sum over every pot still open of what it still owes.
    function _openOwed() internal view returns (uint256 owed) {
        uint256 n = handler.touchedCount();
        for (uint256 i = 0; i < n; i++) {
            (uint128 total, uint128 claimed,, bool closed) = rewards.pots(handler.touchedEpochs(i));
            if (!closed) owed += total - claimed;
        }
    }

    function invariant_holdsAtLeastWhatItReserved() public view {
        assertGe(imd.balanceOf(address(rewards)), rewards.reserved());
    }

    function invariant_reservedEqualsWhatOpenPotsOwe() public view {
        assertEq(rewards.reserved(), _openOwed());
    }

    function invariant_noPotPaysMoreThanItHolds() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i = 0; i < n; i++) {
            (uint128 total, uint128 claimed,,) = rewards.pots(handler.touchedEpochs(i));
            assertLe(claimed, total);
        }
    }

    function invariant_pendingFeesAreTrackedExactly() public view {
        uint256 n = handler.touchedCount();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            sum += mockHook.pendingFeesOf(handler.touchedEpochs(i));
        }
        assertEq(sum, handler.ghostPending());
    }

    function invariant_noHolderIsPaidMoreThanItsShareOfAnyPot() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 epoch = handler.touchedEpochs(i);
            (uint128 total, uint128 claimed, uint256 supply,) = rewards.pots(epoch);
            uint256 sum;
            for (uint256 j = 0; j < actors.length; j++) {
                uint256 paid = rewards.paidOf(epoch, actors[j]);
                if (paid == 0) continue;
                sum += paid;
                assertLe(paid, uint256(total) * rewards.weightOf(actors[j], epoch) / supply);
            }
            assertEq(sum, claimed, "a pot's payouts are exactly what its holders were paid");
        }
    }

    function invariant_imdIsConserved() public view {
        assertEq(imd.balanceOf(address(rewards)) + handler.ghostPaid(), handler.ghostMinted());
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += imd.balanceOf(actors[i]);
        }
        assertEq(sum, handler.ghostPaid(), "only eligible holders were ever paid");
        assertEq(imd.balanceOf(poolManager), 0, "the pool is never paid");
        assertEq(imd.balanceOf(rewards.BURN_ADDRESS()), 0, "the burn address is never paid");
    }

    function invariant_claimsNeverExceedTheBalanceShare() public view {
        assertFalse(handler.overpaid());
    }

    function invariant_onlyTheAccountClaimsItsShare() public view {
        assertFalse(handler.claimedByOther());
    }

    function invariant_closedEpochsNeverReopen() public view {
        assertFalse(handler.reopened());
    }

    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }
}
