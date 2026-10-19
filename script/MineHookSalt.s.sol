// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DeezLaunch} from "../src/DeezLaunch.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Mines the CREATE2 salt `DeezLaunch.launch` needs: the first salt under which the launcher deploys
/// `DeezHook` at an address whose low 14 bits are the hook's permission flags. Pure computation, no broadcast.
///
/// Usage (fork read of the deployed launcher; nothing is sent):
///   forge script script/MineHookSalt.s.sol --rpc-url $RPC \
///     --sig "mine(address,address,address,address)" $LAUNCHER $TOKEN $REWARDS $LOCK
/// The salt it prints is the last argument of `DeezLaunch.launch(token, rewards, liquidityLock, hookSalt)`.
contract MineHookSalt is Script {
    uint160 internal constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    function mine(address launcher, address token, address rewards, address liquidityLock)
        external
        view
        returns (bytes32 salt, address hook)
    {
        (salt, hook) = mineFrom(DeezLaunch(launcher), token, rewards, liquidityLock, 0);
        console.log("hook salt:");
        console.logBytes32(salt);
        console.log("hook address:", hook);
    }

    /// @notice The first salt at or after `start` that lands the hook on its flags; callable from tests.
    function mineFrom(DeezLaunch launcher, address token, address rewards, address liquidityLock, uint256 start)
        public
        view
        returns (bytes32 salt, address hook)
    {
        for (uint256 i = start; i < start + 1_000_000; i++) {
            hook = launcher.hookAddress(bytes32(i), token, rewards, liquidityLock);
            if (HookFlags.matches(hook, FLAGS) && hook.code.length == 0) return (bytes32(i), hook);
        }
        revert("no salt found in 1,000,000 tries");
    }
}
