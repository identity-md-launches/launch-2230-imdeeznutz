// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DeezToken} from "src/DeezToken.sol";

/// @notice A balance ledger and exact token-seconds oracle, independent of the token's checkpoints.
contract DeezHistoryHandler is Test {
    DeezToken public immutable token;
    address[4] public actors;
    uint256[4] public balances;
    uint256[4] public areas;
    uint256[4] public writes;
    uint256[4][4] public allowances;
    uint256 public lastTime;
    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public rejectedTransfers;

    struct Observation {
        uint256 time;
        uint256[4] balance;
        uint256[4] area;
        uint256[4] roundingBudget;
    }

    Observation[] private observations;

    constructor(DeezToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        lastTime = block.timestamp;
        for (uint256 i; i < 4; ++i) {
            balances[i] = token_.balanceOf(actors_[i]);
            writes[i] = 1;
        }
    }

    function _sync() private {
        for (uint256 i; i < 4; ++i) {
            areas[i] += balances[i] * (block.timestamp - lastTime);
        }
        lastTime = block.timestamp;
    }

    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        if (seed % 5 == 0) return maximum;
        if (seed % 5 == 1) return maximum == 0 ? 0 : 1;
        return seed % (maximum + 1);
    }

    function _move(uint256 from, uint256 to, uint256 amount) private {
        balances[from] -= amount;
        balances[to] += amount;
        ++writes[from];
        ++writes[to];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        _sync();
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = _amount(amountSeed, balances[from]);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        _move(from, to, amount);
        ++transfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool unlimited) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 amount = unlimited ? type(uint256).max : _amount(amountSeed, token.TOTAL_SUPPLY());
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        allowances[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        _sync();
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 to = toSeed % 4;
        uint256 allowed = allowances[owner][spender];
        uint256 amount = _amount(amountSeed, allowed < balances[owner] ? allowed : balances[owner]);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[owner], actors[to], amount));
        if (allowed != type(uint256).max) allowances[owner][spender] -= amount;
        _move(owner, to, amount);
        ++delegatedTransfers;
    }

    function rejectOverdraft(uint256 ownerSeed, uint256 toSeed) external {
        uint256 owner = ownerSeed % 4;
        uint256 to = toSeed % 4;
        uint256 count = token.numCheckpoints(actors[owner]);
        uint256 cumulative = token.getCumulativeBalanceOf(actors[owner], block.timestamp);
        vm.prank(actors[owner]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, actors[owner], balances[owner], balances[owner] + 1
            )
        );
        token.transfer(actors[to], balances[owner] + 1);
        assertEq(token.numCheckpoints(actors[owner]), count, "revert wrote a checkpoint");
        assertEq(token.getCumulativeBalanceOf(actors[owner], block.timestamp), cumulative);
        ++rejectedTransfers;
    }

    function elapse(uint256 secondsSeed) external {
        _sync();
        observations.push(Observation(lastTime, balances, areas, writes));
        vm.warp(block.timestamp + bound(secondsSeed, 1, 3 days));
        _sync();
    }

    function observationCount() external view returns (uint256) {
        return observations.length;
    }

    function checkObservation(uint256 seed) external view {
        if (observations.length == 0) return;
        Observation storage o = observations[seed % observations.length];
        for (uint256 i; i < 4; ++i) {
            assertEq(token.getPastBalanceOf(actors[i], o.time), o.balance[i], "past balance changed");
            _checkIntegral(token.getCumulativeBalanceOf(actors[i], o.time), o.area[i], o.roundingBudget[i]);
        }
    }

    function _checkIntegral(uint256 actual, uint256 exactArea, uint256 roundingBudget) private pure {
        uint256 exactFloor = exactArea / 1 days;
        assertLe(actual, exactFloor, "history creates token-time");
        // Each checkpoint segment truncates less than one wei-day. This is an absolute, per-write bound,
        // not a relative tolerance that could hide a materially wrong holding time.
        assertLe(exactFloor - actual, roundingBudget, "history loses more than rounding dust");
    }

    function checkCurrentState() external view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(actors[i]), balances[i], "ledger mismatch");
            sum += balances[i];
            _checkIntegral(
                token.getCumulativeBalanceOf(actors[i], block.timestamp),
                areas[i] + balances[i] * (block.timestamp - lastTime),
                writes[i]
            );
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), allowances[i][j], "allowance mismatch");
            }
            uint256 count = token.numCheckpoints(actors[i]);
            (uint48 time, uint256 balance,) = token.checkpointAt(actors[i], uint32(count - 1));
            assertLe(time, block.timestamp);
            assertEq(balance, balances[i], "latest checkpoint is stale");
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum);
        assertEq(token.balanceOf(address(0)), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract DeezTokenHistoryInvariantTest is Test {
    DeezToken private token;
    DeezHistoryHandler private handler;

    function setUp() public {
        vm.warp(1_700_000_007);
        token = new DeezToken(address(this));
        address[4] memory actors =
            [makeAddr("history-alice"), makeAddr("history-bob"), makeAddr("history-carol"), makeAddr("history-dan")];
        for (uint256 i; i < 4; ++i) {
            token.transfer(actors[i], token.TOTAL_SUPPLY() / 4);
        }
        handler = new DeezHistoryHandler(token, actors);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverdraft.selector;
        selectors[4] = handler.elapse.selector;
        selectors[5] = handler.checkObservation.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_balancesAllowancesAndTokenTimeMatchIndependentLedger() public view {
        handler.checkCurrentState();
    }

    function invariant_closedHistoryRemainsImmutable() public view {
        handler.checkObservation(0);
        handler.checkObservation(handler.observationCount() / 2);
        uint256 n = handler.observationCount();
        if (n > 0) handler.checkObservation(n - 1);
    }

    function test_handlerExercisesApprovalsFullTransfersAndHistory() public {
        handler.elapse(7);
        handler.approve(0, 1, 0, true);
        handler.transferFrom(0, 1, 2, 0);
        handler.transfer(2, 2, 0); // self-transfer of the full balance
        handler.rejectOverdraft(0, 3);
        handler.elapse(1 days + 1);
        handler.transfer(2, 3, 1); // one wei
        handler.approve(3, 0, 1, false);
        handler.transferFrom(3, 0, 1, 1);
        assertEq(handler.transfers(), 2);
        assertEq(handler.delegatedTransfers(), 2);
        assertEq(handler.rejectedTransfers(), 1);
        invariant_balancesAllowancesAndTokenTimeMatchIndependentLedger();
        invariant_closedHistoryRemainsImmutable();
    }
}
