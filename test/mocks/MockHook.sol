// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeezRewards} from "../../src/DeezRewards.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Stands in for `DeezHook` in the distributor's unit tests: holds "pending" fees per epoch that a test
/// sets, and delivers them to the distributor the way the real hook does when asked to harvest.
contract MockHook {
    MockERC20 public imd;
    DeezRewards public rewards;
    mapping(uint256 epoch => uint256 amount) public pendingFeesOf;
    uint256 public harvestCalls;

    function init(MockERC20 imd_, DeezRewards rewards_) external {
        imd = imd_;
        rewards = rewards_;
    }

    /// @dev A fee the test pretends was traded in `epoch` and not harvested yet.
    function setPending(uint256 epoch, uint256 amount) external {
        pendingFeesOf[epoch] = amount;
    }

    function harvestEpochs(uint256[] calldata epochs) external returns (uint256 amount) {
        harvestCalls++;
        for (uint256 i = 0; i < epochs.length; i++) {
            uint256 pending = pendingFeesOf[epochs[i]];
            if (pending == 0) continue;
            pendingFeesOf[epochs[i]] = 0;
            imd.mint(address(rewards), pending);
            rewards.credit(epochs[i], pending);
            amount += pending;
        }
    }
}
