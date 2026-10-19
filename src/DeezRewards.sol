// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The slice of the launch token the distributor reads.
interface IDeezToken is IERC20 {
    function getCumulativeBalanceOf(address account, uint256 timepoint) external view returns (uint256);
    function getCumulativeTotalSupply(uint256 timepoint) external view returns (uint256);
}

/// @notice The slice of the fee hook the distributor calls: fees traded in an epoch and not yet delivered.
interface IDeezHarvester {
    function rewards() external view returns (address);
    function pendingFeesOf(uint256 epoch) external view returns (uint256);
    function harvestEpochs(uint256[] calldata epochs) external returns (uint256);
}

/// @title DEEZ holder rewards
/// @notice Pays every $DEEZ holder its share of the trading fees the hook collects, in $IMD, weighted strictly
/// by the average balance it held over each daily epoch. No owner, no admin, no top-N cutoff.
///
/// How the math works, per epoch `e` (a UTC day, `[e * EPOCH_LENGTH, (e + 1) * EPOCH_LENGTH)`):
///   - The hook records every fee against the epoch the trade happened in and, when anyone harvests, credits
///     it to `pots[e].total` through `credit`. $IMD sent here any other way is credited to the current epoch by
///     `accrue()`.
///   - `weightOf(account, e)` is the account's average $DEEZ balance over the epoch, from the token's own
///     balance history: a wallet that held 100 $DEEZ all day weighs 100; one that held 100 for the last block
///     weighs 100 / 7200.
///   - `eligibleSupplyAt(e)` = the average total supply over the epoch minus the average balances of the four
///     excluded addresses: the PoolManager (the pool's liquidity), the burn address, the hook and this contract.
///   - `claimable(account, e)` = `pots[e].total * weightOf(account, e) / eligibleSupplyAt(e)`, minus what the
///     account was already paid for `e`. A pot can still grow after a claim (fees traded late in the day are
///     only credited when harvested), so `claim` first harvests the epochs it pays through the hook, and a
///     later claim of the same epoch pays the difference against the grown pot instead of reverting. Every
///     holder thus ends up with exactly its share of every fee of the epoch, whenever it claims.
///   - Only the account itself may claim; the payout goes to the account. Nobody can push a share into a
///     contract that cannot spend it.
///   - A share not claimed within `CLAIM_WINDOW` epochs is recycled into the current epoch's pot, so nothing is
///     stranded by holders who never claim (abandoned wallets, contracts holding $DEEZ without a claim path).
///
/// Wiring: the hook's address carries its permission bits, so `DeezLaunch` deploys it with a mined salt after
/// this contract exists. The launcher therefore sets `hook` once, in the launch transaction, through `setHook`;
/// until then `claim` reverts with `HookNotSet` and nobody can `credit`.
contract DeezRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Pot {
        /// @dev $IMD credited to the epoch.
        uint128 total;
        /// @dev $IMD already paid out of it.
        uint128 claimed;
        /// @dev Average eligible supply over the epoch; 0 until finalized.
        uint256 eligibleSupply;
        /// @dev Whether the unclaimed remainder was recycled; no claims after that.
        bool closed;
    }

    /// @notice Length of one reward epoch. Equals the token's `CUMULATIVE_UNIT`, so an epoch weight is an
    /// average balance in wei.
    uint256 public constant EPOCH_LENGTH = 1 days;
    /// @notice Epochs a share stays claimable before `recycle` may fold it into the current pot.
    uint256 public constant CLAIM_WINDOW = 90;
    /// @notice The conventional burn address, excluded from rewards.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The launch token whose holders are paid.
    IDeezToken public immutable token;
    /// @notice The token rewards are paid in ($IMD, the pool's pair currency).
    IERC20 public immutable rewardToken;
    /// @notice The Uniswap v4 PoolManager: it holds the pool's $DEEZ, so it is excluded.
    address public immutable poolManager;
    /// @notice The `DeezLaunch` contract, the only caller of `setHook`.
    address public immutable launcher;

    /// @notice The fee hook that feeds this contract; excluded as well, and the only caller of `credit`.
    /// Zero until the launcher sets it.
    address public hook;
    /// @notice Reward token already assigned to pots (claimed or not); anything above it is new.
    uint256 public reserved;
    /// @notice Per-epoch accounting.
    mapping(uint256 epoch => Pot) public pots;
    /// @notice Reward token already paid to `account` for epoch `epoch`.
    mapping(uint256 epoch => mapping(address account => uint256 amount)) public paidOf;

    event HookSet(address indexed hook);
    event Accrued(uint256 indexed epoch, uint256 amount);
    event Finalized(uint256 indexed epoch, uint256 eligibleSupply);
    /// @notice What a claim pulled in before computing shares: fees harvested from the hook and stray $IMD accrued.
    event Credited(address indexed account, uint256 harvested, uint256 accrued);
    event Claimed(uint256 indexed epoch, address indexed account, uint256 amount);
    event Recycled(uint256 indexed epoch, uint256 indexed intoEpoch, uint256 amount);

    error ZeroAddress();
    error NotLauncher();
    error NotHook();
    error HookNotSet();
    error HookAlreadySet();
    error HookNotOurs(address hook);
    error NotAccount(address account);
    error Unfunded(uint256 amount, uint256 available);
    error EpochNotEnded(uint256 epoch);
    error EpochClosed(uint256 epoch);
    error Excluded(address account);
    error NothingToClaim();
    error ClaimWindowOpen(uint256 epoch);

    /// @param token_ The launch token ($DEEZ).
    /// @param rewardToken_ The pair currency rewards are paid in ($IMD).
    /// @param poolManager_ The chain's Uniswap v4 PoolManager.
    /// @param launcher_ The `DeezLaunch` contract that will deploy the hook and set it here.
    constructor(address token_, address rewardToken_, address poolManager_, address launcher_) {
        if (token_ == address(0) || rewardToken_ == address(0) || poolManager_ == address(0) || launcher_ == address(0))
        {
            revert ZeroAddress();
        }
        token = IDeezToken(token_);
        rewardToken = IERC20(rewardToken_);
        poolManager = poolManager_;
        launcher = launcher_;
    }

    /// @notice Record the fee hook, once. Only the launcher may call this, and only with a hook that names this
    /// contract as its distributor.
    function setHook(address hook_) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (hook != address(0)) revert HookAlreadySet();
        if (hook_ == address(0)) revert ZeroAddress();
        if (IDeezHarvester(hook_).rewards() != address(this)) revert HookNotOurs(hook_);
        hook = hook_;
        emit HookSet(hook_);
    }

    // ---------------------------------------------------------------- views

    /// @notice The epoch `block.timestamp` falls in.
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    /// @notice The last second of epoch `epoch`; its weights are final once this second has passed.
    function snapshotOf(uint256 epoch) public pure returns (uint256) {
        return (epoch + 1) * EPOCH_LENGTH - 1;
    }

    /// @notice Whether epoch `epoch` has ended, i.e. its average balances are final.
    function hasEnded(uint256 epoch) public view returns (bool) {
        return block.timestamp > snapshotOf(epoch);
    }

    /// @notice Addresses that hold $DEEZ but never earn: the pool, the burn address, the hook and this contract.
    function isExcluded(address account) public view returns (bool) {
        return account == poolManager || account == BURN_ADDRESS || account == hook || account == address(this)
            || account == address(0);
    }

    /// @notice The average $DEEZ balance `account` held over `epoch`, in wei (reverts until the epoch ended).
    function weightOf(address account, uint256 epoch) public view returns (uint256) {
        uint256 start = epoch * EPOCH_LENGTH;
        return
            token.getCumulativeBalanceOf(account, start + EPOCH_LENGTH) - token.getCumulativeBalanceOf(account, start);
    }

    /// @notice Average total supply minus the excluded averages over `epoch` (reverts until the epoch ended).
    function eligibleSupplyAt(uint256 epoch) public view returns (uint256) {
        uint256 start = epoch * EPOCH_LENGTH;
        uint256 total = token.getCumulativeTotalSupply(start + EPOCH_LENGTH) - token.getCumulativeTotalSupply(start);
        uint256 excluded = weightOf(poolManager, epoch) + weightOf(BURN_ADDRESS, epoch) + weightOf(hook, epoch)
            + weightOf(address(this), epoch);
        return total > excluded ? total - excluded : 0;
    }

    /// @notice What `account` can still claim for `epoch`: its share of the pot, counting the fees of the epoch
    /// the hook has not harvested yet (`claim` harvests them), minus what it was already paid for the epoch.
    /// Zero if the epoch has not ended, is closed, the account is excluded, or the hook is not set yet.
    function claimable(address account, uint256 epoch) public view returns (uint256) {
        if (hook == address(0) || !hasEnded(epoch) || isExcluded(account)) return 0;
        Pot storage pot = pots[epoch];
        if (pot.closed) return 0;
        uint256 total = pot.total + IDeezHarvester(hook).pendingFeesOf(epoch);
        if (total == 0) return 0;
        uint256 supply = pot.eligibleSupply == 0 ? eligibleSupplyAt(epoch) : pot.eligibleSupply;
        if (supply == 0) return 0;
        return _owed(total, pot.claimed, weightOf(account, epoch), supply, paidOf[epoch][account]);
    }

    /// @notice Sum of `claimable` over `epochs`.
    function claimableMany(address account, uint256[] calldata epochs) external view returns (uint256 total) {
        for (uint256 i = 0; i < epochs.length; i++) {
            total += claimable(account, epochs[i]);
        }
    }

    // ------------------------------------------------------------- mutations

    /// @notice Credit every reward token received since the last call to the current epoch's pot.
    /// @dev Permissionless: anyone may donate $IMD and call it. The hook's fees come in through `credit`.
    function accrue() public returns (uint256 amount) {
        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 reserved_ = reserved;
        if (balance <= reserved_) return 0;
        amount = balance - reserved_;
        uint256 epoch = currentEpoch();
        pots[epoch].total += uint128(amount);
        reserved = balance;
        emit Accrued(epoch, amount);
    }

    /// @notice Credit `amount` of reward token the hook has just transferred here to the pot of `epoch`, the
    /// epoch the fees were traded in. Only the hook may call this, and only for $IMD it actually delivered.
    /// @dev An epoch already recycled (closed) cannot take new money that nobody could claim: it goes to the
    /// current epoch instead.
    function credit(uint256 epoch, uint256 amount) external {
        if (msg.sender != hook) revert NotHook();
        uint256 available = rewardToken.balanceOf(address(this)) - reserved;
        if (amount > available) revert Unfunded(amount, available);
        if (pots[epoch].closed || epoch > currentEpoch()) epoch = currentEpoch();
        pots[epoch].total += uint128(amount);
        reserved += amount;
        emit Accrued(epoch, amount);
    }

    /// @notice Record the eligible supply of an ended epoch so later claims do not recompute it.
    function finalize(uint256 epoch) public returns (uint256 supply) {
        Pot storage pot = pots[epoch];
        if (pot.eligibleSupply != 0) return pot.eligibleSupply;
        if (!hasEnded(epoch)) revert EpochNotEnded(epoch);
        supply = eligibleSupplyAt(epoch);
        pot.eligibleSupply = supply;
        emit Finalized(epoch, supply);
    }

    /// @notice Pay `account` what it is still owed for each epoch in `epochs`. Only `account` itself may call
    /// this, so no third party can direct a share into a contract that cannot move it.
    /// @dev Harvests the listed epochs through the hook first, so fees traded late in a day and not yet
    /// harvested are credited to their pot before the share is computed, then accrues so a donation and a
    /// claim in the same block never miss each other. A repeat claim of an epoch pays only what was credited
    /// to it since the last one. Reverts when the whole batch pays nothing, so a stale or duplicate claim is
    /// visible instead of silently succeeding.
    function claim(address account, uint256[] calldata epochs) external nonReentrant returns (uint256 total) {
        if (msg.sender != account) revert NotAccount(account);
        if (isExcluded(account)) revert Excluded(account);
        address hook_ = hook;
        if (hook_ == address(0)) revert HookNotSet();
        uint256 harvested = IDeezHarvester(hook_).harvestEpochs(epochs);
        uint256 accrued = accrue();
        if (harvested + accrued > 0) emit Credited(account, harvested, accrued);
        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 epoch = epochs[i];
            Pot storage pot = pots[epoch];
            if (pot.closed) revert EpochClosed(epoch);
            uint256 supply = finalize(epoch);
            if (pot.total == 0 || supply == 0) continue;
            uint256 amount = _owed(pot.total, pot.claimed, weightOf(account, epoch), supply, paidOf[epoch][account]);
            if (amount == 0) continue;
            paidOf[epoch][account] += amount;
            pot.claimed += uint128(amount);
            total += amount;
            emit Claimed(epoch, account, amount);
        }
        if (total == 0) revert NothingToClaim();
        reserved -= total;
        rewardToken.safeTransfer(account, total);
    }

    /// @notice Fold what was never claimed for `epoch` into the current epoch, once `CLAIM_WINDOW` epochs passed.
    function recycle(uint256 epoch) external returns (uint256 amount) {
        Pot storage pot = pots[epoch];
        if (pot.closed) revert EpochClosed(epoch);
        if (currentEpoch() < epoch + CLAIM_WINDOW + 1) revert ClaimWindowOpen(epoch);
        pot.closed = true;
        amount = pot.total - pot.claimed;
        if (amount == 0) return 0;
        uint256 into = currentEpoch();
        pots[into].total += uint128(amount);
        emit Recycled(epoch, into, amount);
    }

    /// @dev `total * weight / supply` minus what was already paid, never more than what is left in the pot (the
    /// per-checkpoint rounding of the token's cumulative balances can put the sum of weights a few wei over
    /// the eligible supply). `total` only ever grows, so the share never falls below what was paid.
    function _owed(uint256 total, uint256 alreadyClaimed, uint256 weight, uint256 supply, uint256 alreadyPaid)
        private
        pure
        returns (uint256 amount)
    {
        uint256 share = total * weight / supply;
        if (share <= alreadyPaid) return 0;
        amount = share - alreadyPaid;
        uint256 left = total - alreadyClaimed;
        if (amount > left) amount = left;
    }
}
