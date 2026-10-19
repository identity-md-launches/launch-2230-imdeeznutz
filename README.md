# IMDeezNutz ($DEEZ) — Uniswap v4 hook launch on Ethereum, locked at launch

Relaunch of IMDeezNutz ($DEEZ, 1,000,000,000 tokens, 18 decimals) paired with $IMD on Uniswap v4, as an
`evm_contracts` launch on Ethereum mainnet (chain id 1). The token, hook, holder rewards and liquidity lock keep
the logic of the previous launch (`identity-md-launches/launch-2225-imdeeznutz`). What changed:

- **The requester's 2% is split in the launch transaction.** 10,000,000 $DEEZ (`LOCKED_REQUESTER_SHARE`) are sent
  to `DeezLiquidityLock` and locked as permanent liquidity in the same transaction that deploys the hook and
  opens the pool; the other 10,000,000 $DEEZ (`PAID_REQUESTER_SHARE`) go to the requester wallet.
- **A launcher contract (`DeezLaunch`) does the launch**, because this launch mode deploys application contracts
  only (no token, pool or swarm share from the factory) and a Uniswap v4 hook cannot be deployed by the factory
  (its address must carry the permission bits, which needs a mined CREATE2 salt). The factory deploys the four
  contracts below; `DeezLaunch.launch` then deploys the hook, opens the pool, seeds and locks the liquidity and
  pays the requester, all in one transaction.
- **The 98% that the previous launch's factory held as its own position is now permanent locked liquidity**
  (`POOL_SHARE`, 980,000,000 $DEEZ), owned by `DeezLiquidityLock`, which has no owner and no remove function.
- Every finding of the static analysis that rejected the previous attempt is designed out (see "Static analysis").

## Contracts the factory deploys (in this order)

| # | Solidity name       | Constructor arguments (manifest)                                                                     |
|---|---------------------|------------------------------------------------------------------------------------------------------|
| 0 | `DeezLaunch`        | `requester_` = `$owner`; `poolManager_` = `0x000000000004444c5dc75cB358380D2e3dE08A90`; `pairedCurrency_` = `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| 1 | `DeezToken`         | `launcher_` = `$contract:DeezLaunch`                                                                 |
| 2 | `DeezRewards`       | `token_` = `$contract:DeezToken`; `rewardToken_` = `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`; `poolManager_` = `0x000000000004444c5dc75cB358380D2e3dE08A90`; `launcher_` = `$contract:DeezLaunch` |
| 3 | `DeezLiquidityLock` | `poolManager_` = `0x000000000004444c5dc75cB358380D2e3dE08A90`; `rewards_` = `$contract:DeezRewards`  |

- `0x000000000004444c5dc75cB358380D2e3dE08A90` is Uniswap v4's `PoolManager` on Ethereum mainnet (checked to
  have code and an owner on 2026-10-19 through a public RPC). `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` is
  $IMD (symbol `IMD`, 18 decimals, read the same way). Both are well-known public contracts and are passed as
  constructor arguments; no constructor calls them.
- `$owner` is the requester, `0xb04548fac7e1505c7c0179d2af59f76c3018d003`: the only caller of
  `DeezLaunch.launch` and the recipient of `PAID_REQUESTER_SHARE`. Nothing has an owner, `Ownable` or an admin
  function; `requester` is a recipient and a one-time trigger, not an administrator.
- All constructors are nonpayable, take 1 to 4 static arguments, make no external call and need no address to
  have code. The whole supply is minted to `DeezLaunch` by `DeezToken`'s constructor. Runtime sizes (solc
  0.8.26, via-IR, 44,444,444 runs): `DeezLaunch` 17.4 KB (it embeds the hook's creation code), `DeezLiquidityLock`
  9.8 KB, `DeezHook` 8.8 KB, `DeezRewards` 7.8 KB, `DeezToken` 5.1 KB; all under EIP-170. No `DELEGATECALL`,
  `CALLCODE` or `SELFDESTRUCT`; every library function is `internal`.
- `DeezHook` is **not** in the manifest: `DeezLaunch` deploys it with CREATE2.

`launch.json` is written by the manifest step, not here.

## The launch transaction (`DeezLaunch.launch`)

```
launch(address token, address rewards, address liquidityLock, bytes32 hookSalt) → DeezHook
```

Caller: the requester only. Once. Steps, in order:

1. Checks the three addresses are the contracts deployed for this launcher: `token.launcher()`,
   `rewards.launcher()` equal the launcher; `rewards.token()`, `rewards.rewardToken()`, `rewards.poolManager()`
   match; `rewards.hook()` is still zero; `liquidityLock.poolManager()` and `liquidityLock.rewards()` match; and
   the launcher holds the whole 1,000,000,000 $DEEZ. A wrong or impostor address reverts
   (`WrongToken`, `WrongRewards`, `WrongLiquidityLock`, `SupplyNotHere`).
2. Deploys `DeezHook(poolManager, token, IMD, rewards, liquidityLock)` with CREATE2 and `hookSalt`. The hook's
   constructor validates that its address carries exactly `beforeInitialize | beforeSwap | afterSwap |
   beforeSwapReturnDelta | afterSwapReturnDelta` (`0x20CC`), so a wrong salt reverts the whole launch
   (`Hooks.HookAddressNotValid`) and leaves nothing behind.
3. `rewards.setHook(hook)` (launcher only, once, and the hook must name this distributor). The lock reads the
   hook from the distributor.
4. `poolManager.initialize(PoolKey(sorted {DEEZ, IMD}, fee 12500, tickSpacing 60, hook), openingSqrtPriceX96)`.
   The opening price values the whole supply at `OPENING_MARKET_CAP_IMD` = 2,500 $IMD, i.e. 0.0000025 $IMD per
   $DEEZ, computed for whichever side $DEEZ sorts on (`openingSqrtPriceX96(bool tokenIsCurrency0)`).
5. Transfers `POOL_SHARE` (980,000,000 $DEEZ) to the lock and calls `lockAs(Token0Only|Token1Only, tick, tick)`:
   a single-sided $DEEZ position from the first tick above the opening price to the top of the range. The tick
   bound equals the tick just initialized, so nothing can move the price first.
6. Transfers `LOCKED_REQUESTER_SHARE` (10,000,000 $DEEZ) to the lock and locks it the same way, in the same
   range (the lock's `lockedLiquidity[range]` adds up; `RequesterShareLocked` is emitted).
7. Transfers `PAID_REQUESTER_SHARE` (10,000,000 $DEEZ) to the requester (`RequesterPaid`).

Events: `Launched(token, hook, rewards, liquidityLock, poolId, sqrtPriceX96, tick)`, `PoolSeeded(amount,
liquidity)`, `RequesterShareLocked(amount, liquidity)`, `RequesterPaid(requester, amount)`. After the
transaction `launcher.hook()`, `launcher.poolId()` and `launcher.launched()` are set and the launcher holds no
$DEEZ. The lock shaves one part in a million off each position so the PoolManager's round-up can never exceed
what it holds; the few hundred $DEEZ that leaves stay in the lock and the next `lock()` (anyone) folds them in.

### Mining the hook salt

`hookSalt` is mined off chain after the factory transaction, because the hook's address depends on the launcher,
token, rewards and lock addresses:

```
forge script script/MineHookSalt.s.sol --rpc-url $RPC \
  --sig "mine(address,address,address,address)" $LAUNCHER $TOKEN $REWARDS $LOCK
```

It loops over `DeezLaunch.hookAddress(salt, token, rewards, liquidityLock)` until the low 14 bits equal `0x20CC`
(about 16,384 tries on average) and prints the salt and the hook address. The same can be done with `cast call`
on `hookAddress`. Nothing is broadcast.

## After launch (operational responsibilities)

| Who            | What                                                                                                     |
|----------------|----------------------------------------------------------------------------------------------------------|
| Requester      | Mine `hookSalt` (above), then send `DeezLaunch.launch(token, rewards, liquidityLock, hookSalt)` from `0xb04548fac7e1505c7c0179d2af59f76c3018d003`. Gas: roughly 3.5M (hook deployment, pool initialization, two liquidity adds). Until this is sent, nothing trades and the supply sits in the launcher. |
| Requester      | Publish the addresses: fill `site/deez.config.js` with the factory's record (`token`, `launcher`, `rewards`, `liquidityLock`, `deployTx`) and the launch transaction's results (`hook` = `DeezLaunch.hook()`, `poolId` = `DeezLaunch.poolId()`, `launchTx`). Never invent an address: a blank field shows "announced at launch". |
| Anyone         | `DeezHook.harvest()` moves the fees of the current and previous day into `DeezRewards`; `DeezRewards.claim` does it for the epochs it pays, so this is a convenience, not a duty. |
| Holders        | `DeezRewards.claim(account, epochs)` from the account itself, within 90 epochs; `recycle(epoch)` (anyone) folds what was never claimed into the current pot afterwards. |
| Anyone         | Send $DEEZ and/or $IMD to `DeezLiquidityLock` and call `lock()` or `lockAs(...)` to add permanent liquidity. There is no way back out. |
| Deployer / IMD | Nothing: no key, role or setting of this launch belongs to IMD. Explorer verification of the five contracts is an open item for whoever publishes (`forge verify-contract`, solc 0.8.26, via-IR, 44,444,444 runs, `bytecode_hash = none`). |

There is no owner-settable value: every outside contract (PoolManager, $IMD) is a constructor argument with a
mainnet value given above, and every number is a constant.

## How it works

### The token (`DeezToken`)

Fixed-supply OpenZeppelin ERC-20 (`IMDeezNutz`, `DEEZ`, 18 decimals). The constructor takes the launcher's
address and mints the whole supply to it. No owner, mint, burn, pause, blocklist or proxy. Its only addition is a
timestamp checkpoint per balance change that also keeps a cumulative balance (token-days), read by
`getPastBalanceOf`, `getCumulativeBalanceOf` and `getCumulativeTotalSupply`, so rewards can be weighted by the
balance actually held over an epoch.

### The hook (`DeezHook`)

Takes exactly `FEE_BPS` = 200 (2.00%) of the $IMD side of every buy and sell, exact-input and exact-output alike,
never from $DEEZ; an $IMD-specified swap the pool fills only partly reverts with `PartialFill`. The fee is minted
to the hook as an ERC-6909 claim inside the swap and recorded against the daily epoch it was traded in.
`harvest()` / `harvestEpochs(epochs)` (anyone) burn the claims, move the $IMD into `DeezRewards` and credit each
epoch's own pot. `beforeInitialize` accepts only the first pool whose currencies are {DEEZ, IMD}, from any
initializer, at any fee tier and spacing. The constructor now takes the distributor and the lock as arguments
instead of deploying them, so the hook's init code is 9.9 KB and fits inside the launcher.

### The distributor (`DeezRewards`)

Epochs are UTC days. `weightOf(account, epoch)` is the account's average balance over the epoch;
`eligibleSupplyAt(epoch)` is the average supply minus the PoolManager, `0x…dEaD`, the hook and the distributor
itself; `claimable = (pot + hook.pendingFeesOf(epoch)) × weight / eligibleSupply − paidOf`. `claim(account,
epochs)` is callable only by the account itself, harvests the listed epochs through the hook first, and reverts
when the batch pays nothing. `recycle(epoch)` folds what was not claimed within `CLAIM_WINDOW` = 90 epochs into
the current pot. New: `hook` is storage set once by the launcher through `setHook` (emits `HookSet`); before
that `claim` reverts with `HookNotSet`, `claimable` returns 0 and nobody can `credit`.

### The liquidity lock (`DeezLiquidityLock`)

Anyone may send $DEEZ and/or $IMD and call `lock()` or `lockAs(mode, minTick, maxTick)` to mint a permanent
position in the launch pool: no owner, no remove, no fee collection; LP fees compound into the pool. The lock
takes the distributor as a constructor argument and reads the hook from it (`hook()`); it reverts with
`HookNotSet` before the launch and `PoolNotInitialized` before the pool exists. Topping up a range that already
earned LP fees takes the fee credit back into the lock (`FeesReturned`) instead of leaving a positive delta
unsettled, and `settle()`'s return is checked against what was paid (`SettleMismatch`).

## Decisions the brief left open (named constants)

| Constant                                   | Value                 | Why                                                                                   |
|--------------------------------------------|-----------------------|---------------------------------------------------------------------------------------|
| `DeezLaunch.LOCKED_REQUESTER_SHARE`        | 10,000,000 $DEEZ      | The brief's "at least 10,000,000": exactly that, so the requester keeps the other half. |
| `DeezLaunch.PAID_REQUESTER_SHARE`          | 10,000,000 $DEEZ      | The remainder of the 2%.                                                              |
| `DeezLaunch.POOL_SHARE`                    | 980,000,000 $DEEZ     | Everything that is not the requester's 2%, as permanent single-sided liquidity.       |
| `DeezLaunch.OPENING_MARKET_CAP_IMD`        | 2,500 $IMD            | The previous launch's opening valuation.                                              |
| `DeezLaunch.POOL_FEE` / `TICK_SPACING`     | 12500 (1.25%) / 60    | The previous launch's pool parameters.                                                |
| `DeezHook.FEE_BPS`                         | 200 (2%)              | Unchanged from the previous launch.                                                   |
| `DeezRewards.EPOCH_LENGTH` / `CLAIM_WINDOW`| 1 day / 90 epochs     | Unchanged.                                                                            |

The previous launch's 10% swarm share and Merkle distributor do not exist in this launch mode; the brief did not
ask for them, so that supply is part of `POOL_SHARE`. If the requester wants a different split, these constants
are the only place to change.

## Static analysis (why the previous attempt failed, and what is different)

| Finding                                   | Where it was                       | Design here                                                                                             |
|-------------------------------------------|------------------------------------|---------------------------------------------------------------------------------------------------------|
| `encode-packed-collision` (high)          | `DeezLaunch.launch`                | Hook init code is built with `bytes.concat(creationCode, abi.encode(args))`; the one `abi.encodePacked` left (CREATE2 preimage) has only fixed-size words. |
| `uninitialized-state` (high)              | `DeezToken._history`               | The mapping is written through `_history[account].push(...)` directly, never through a storage pointer. |
| `divide-before-multiply` (medium)         | `DeezLiquidityLock._floorToSpacing`| `tick - remainder` with a non-negative remainder; no division followed by multiplication.               |
| `incorrect-equality` (medium)             | `lockAs`, `_checkpoint`            | Balances are tested with `> 0` flags, the checkpoint with `last.timestamp >= now_`.                     |
| `unused-return` (medium, ×8)              | lock, hook, rewards, launcher      | Every external return is consumed: `settle()` checked (`SettleMismatch`), `unlock()` decoded and checked (`UnlockMismatch`), `modifyLiquidity`'s fees accrued folded into the amounts, `accrue()` and `harvestEpochs()` reported in events, `initialize()`'s tick used as the lock bound, `lockAs()`'s liquidity emitted. |
| `calls-loop`, `timestamp`, `reentrancy-*` (low) | hook, rewards, token         | Inherent to a per-epoch, time-weighted distributor; unchanged and documented. `claim` is `nonReentrant`, the hook and lock accept callbacks from the PoolManager only, and every state change precedes the external call that could observe it where the order can be chosen. |

## Security notes and trust assumptions

- **No admin.** No contract has an owner, pause, upgrade, mint or sweep. `requester` can trigger the launch once
  and receives 10,000,000 $DEEZ; it cannot change any parameter, and the launch's effects are fixed in code.
- **Launch is requester-gated by design.** The three application addresses cannot be verified on chain beyond
  the checks in `_check` (an impostor can mimic view functions), so the one party who can read them from the
  factory's record passes them. A fully permissionless `launch` would let a griefer launch an impostor set.
- **The hook's constructor makes no external call**; `Hooks.validateHookPermissions` is pure. A wrong salt
  reverts the whole launch transaction.
- **Price limits.** The pool opens at the computed price with $DEEZ-only depth above it, so the first trade is a
  buy; nothing in the hook or lock reads block values for randomness or value.
- **Rounding.** The lock's 1 ppm shave leaves a few hundred $DEEZ of the 990,000,000 in the lock (not in the
  requester's hands); anyone's later `lock()` folds them into the position.
- **Tests are not an audit.** Work holding other people's funds needs an independent adversarial review before
  release; this assignment ran `forge build`, `forge test` (187 tests, fuzz and invariant suites, seed
  `0x29334e60…`) and `forge fmt --check`. Slither was not available on this machine; the table above records
  how each reported pattern was removed.

## Tests

`test/DeezLaunch.t.sol` (both currency orders): the factory stand-in deploys the four contracts in one call; the
launch deploys the hook where `hookAddress` predicted, with the flags; wires the distributor and lock; opens the
pool at 2,500 $IMD for the supply (checked on both sides); locks 990,000,000 $DEEZ less the 1 ppm shave as a
position the lock owns; pays the requester 10,000,000; emits the launch facts; trades afterwards with the 2% fee
taken and harvested. Refusals: not the requester, a second launch, a salt without the flags (nothing left
behind), impostor token/distributor/lock, a distributor for another launcher, zero addresses and the pair
currency, supply not in the launcher, `setHook` by anyone but the launcher or with a foreign hook, `lock`/`claim`
before the hook is set, removing the locked liquidity from outside.

The previous launch's suites are kept and adapted to the new wiring: `DeezToken` (checkpoints, cumulative
balances, fuzz), `DeezHook` (fee on all four swap shapes, partial fills, epochs, harvest, callbacks),
`DeezRewards` (shares, repeat claims, windows, recycling, fuzz), `DeezLiquidityLock` (both sides, full range,
tick bounds), `DeezFlywheel` (end to end), failure paths, and the hook and rewards invariant suites.

```
forge build && forge test && forge fmt --check
```

## Revision history

- Launch 2225 (univ4_hook kind): token, hook, rewards, lock; the factory held the pool position and the
  requester was to lock 10,000,000 $DEEZ by hand after launch.
- This launch (evm_contracts kind): `DeezLaunch` added; the 10,000,000 $DEEZ are locked in the launch
  transaction; the 98% is permanent locked liquidity; the hook takes its distributor and lock as arguments; the
  distributor's hook is set once by the launcher; static-analysis findings designed out.
