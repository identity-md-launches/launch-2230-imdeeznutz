// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IMDeezNutz ($DEEZ)
/// @notice Fixed-supply ERC-20 for the IMDeezNutz launch: 1,000,000,000 tokens at 18 decimals, minted once to
/// `DeezLaunch`, the launcher that opens the pool, locks the liquidity and pays the requester in one transaction.
/// No owner, no mint, no burn function, no pause, no blocklist, no transfer tax and no upgrade path: every
/// transfer moves exactly what it was asked to move.
/// @dev The only addition to a plain ERC-20 is a per-account balance history keyed by block timestamp. Each
/// checkpoint records the balance from that second on and the balance integrated over time up to it, so the
/// rewards distributor can read both the balance held at any past second (`getPastBalanceOf`) and the average
/// balance held over any past period (`getCumulativeBalanceOf`). Rewards weighted by the average balance over a
/// whole epoch cannot be sniped by a wallet that holds for one block across the epoch boundary. A checkpoint is
/// one storage slot per side of a transfer; nothing else changes.
contract DeezToken is ERC20 {
    /// @dev One slot: when the checkpoint was written, the balance held from that second on, and the balance
    /// integrated over every second before it, in `CUMULATIVE_UNIT`s (token-days).
    struct Checkpoint {
        uint40 timestamp;
        uint96 balance;
        uint120 cumulative;
    }

    /// @notice The whole supply, minted once in the constructor.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    /// @notice Unit of the cumulative balance: one token held for one day is one token-day (`1e18` wei-days).
    uint256 public constant CUMULATIVE_UNIT = 1 days;

    /// @notice The second the supply was minted; nothing was held before it.
    uint48 public immutable mintedAt;
    /// @notice The launcher (`DeezLaunch`) the whole supply was minted to.
    address public immutable launcher;

    /// @notice A balance was requested for a timepoint that is not final yet.
    error FutureLookup(uint48 timepoint, uint48 clock);
    error ZeroAddress();

    mapping(address account => Checkpoint[]) private _history;

    /// @param launcher_ The `DeezLaunch` contract that receives the supply and distributes it at launch.
    constructor(address launcher_) ERC20("IMDeezNutz", "DEEZ") {
        if (launcher_ == address(0)) revert ZeroAddress();
        launcher = launcher_;
        mintedAt = uint48(block.timestamp);
        _mint(launcher_, TOTAL_SUPPLY);
    }

    /// @notice The clock the balance history is keyed by (EIP-6372): block timestamps.
    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice EIP-6372 clock description.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    /// @notice The balance `account` held at the end of second `timepoint`.
    /// @dev Reverts while `timepoint` is the current second or later, because that balance can still change.
    function getPastBalanceOf(address account, uint256 timepoint) external view returns (uint256) {
        uint48 now_ = clock();
        if (timepoint >= now_) revert FutureLookup(uint48(timepoint), now_);
        (bool found, Checkpoint memory c) = _lookup(account, timepoint);
        return found ? c.balance : 0;
    }

    /// @notice The balance of `account` integrated over every second before `timepoint`, in wei-days
    /// (`balance * seconds / 1 days`). The average balance over `[from, to)` is
    /// `getCumulativeBalanceOf(account, to) - getCumulativeBalanceOf(account, from)` when `to - from` is one day.
    /// @dev Reverts while `timepoint` is later than the current second: the seconds before `block.timestamp` are
    /// final, the current one is not.
    function getCumulativeBalanceOf(address account, uint256 timepoint) external view returns (uint256) {
        uint48 now_ = clock();
        if (timepoint > now_) revert FutureLookup(uint48(timepoint), now_);
        (bool found, Checkpoint memory c) = _lookup(account, timepoint);
        if (!found) return 0;
        return uint256(c.cumulative) + uint256(c.balance) * (timepoint - c.timestamp) / CUMULATIVE_UNIT;
    }

    /// @notice The total supply integrated over every second before `timepoint`, in wei-days; the supply is
    /// constant, so this is `TOTAL_SUPPLY * (timepoint - mintedAt) / 1 days`.
    function getCumulativeTotalSupply(uint256 timepoint) external view returns (uint256) {
        uint48 now_ = clock();
        if (timepoint > now_) revert FutureLookup(uint48(timepoint), now_);
        if (timepoint <= mintedAt) return 0;
        return TOTAL_SUPPLY * (timepoint - mintedAt) / CUMULATIVE_UNIT;
    }

    /// @notice Number of checkpoints recorded for `account`.
    function numCheckpoints(address account) external view returns (uint256) {
        return _history[account].length;
    }

    /// @notice The `pos`-th checkpoint of `account`: when it was written, the balance since, and the cumulative
    /// balance (wei-days) up to that second.
    function checkpointAt(address account, uint32 pos)
        external
        view
        returns (uint48 timepoint, uint256 balance, uint256 cumulative)
    {
        Checkpoint memory c = _history[account][pos];
        return (c.timestamp, c.balance, c.cumulative);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0)) _checkpoint(from);
        if (to != address(0)) _checkpoint(to);
    }

    /// @dev Record `account`'s balance as of now. Within one second only the balance changes; a new second
    /// closes the previous checkpoint's segment into the cumulative total.
    function _checkpoint(address account) private {
        uint40 now_ = uint40(block.timestamp);
        uint96 balance = uint96(balanceOf(account));
        uint256 length = _history[account].length;
        if (length == 0) {
            _history[account].push(Checkpoint({timestamp: now_, balance: balance, cumulative: 0}));
            return;
        }
        Checkpoint memory last = _history[account][length - 1];
        // Timestamps never decrease, so "not earlier than now" is "written this same second".
        if (last.timestamp >= now_) {
            _history[account][length - 1].balance = balance;
            return;
        }
        uint256 cumulative =
            uint256(last.cumulative) + uint256(last.balance) * (now_ - last.timestamp) / CUMULATIVE_UNIT;
        _history[account].push(Checkpoint({timestamp: now_, balance: balance, cumulative: uint120(cumulative)}));
    }

    /// @dev The last checkpoint written at or before `timepoint`, by binary search.
    function _lookup(address account, uint256 timepoint) private view returns (bool found, Checkpoint memory c) {
        uint256 low = 0;
        uint256 high = _history[account].length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_history[account][mid].timestamp <= timepoint) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low == 0) return (false, c);
        return (true, _history[account][low - 1]);
    }
}
