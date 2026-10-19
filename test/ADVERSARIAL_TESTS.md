# Additional DEEZ test coverage

These tests exercise the existing contracts locally with the real v4 `PoolManager` and
test pair tokens. They require no fork, network, private key, environment mutation, or
additional dependency.

| File | Properties checked |
| --- | --- |
| `DeezLaunchRollback.t.sol` | In both currency orders, failures during pool initialization, the requester lock transfer, or the final payout revert hook creation, wiring, pool state, positions, balances, and checkpoints. The same salt can then be retried. Transfer and lock logs establish direct allocation routing and ordering within `launch()`. |
| `DeezLaunchLifecycleInvariant.t.sol` | Random authorized and unauthorized launch attempts, invalid inputs, retries, and payout transfers preserve total custody. Only the requester can launch, only once; the locked allocation cannot become a second payout. |
| `DeezLiquidityLockInvariant.t.sol` | Multiple donors, random swaps, explicit and automatic lock modes, tick-bound failures, foreign callbacks, and attempted foreign removals preserve permanent positions and currency accounting. Both currency orders run against real v4 state. |
| `DeezTokenHistoryInvariant.t.sol` | A separate balance/allowance ledger and exact token-seconds oracle check transfers, delegated transfers, approvals, overdrafts, time changes, and historical reads. Past observations remain immutable. |
| `DeezTokenHistoryEdges.t.sol` | Failed delegated transfers preserve allowances and histories; zero-address transfers cannot burn; zero/self transfers and a same-second full-supply round trip do not create holding time. Fuzzing checks binary search across 32 alternating checkpoints. |
| `DeezLauncherExclusion.t.sol` | Launches at a fuzzed second of the launch day (including the last one), with a fuzzed buy and a fuzzed amount sent back to the launcher. The launcher's holding is never eligible supply and never claimable, the day's pot goes to the holders who can claim, and reward custody equals `reserved`. Before launch there is no pot and nothing to claim. A third party can build a complete look-alike set: mixed sets are refused, and a full one is caught only by the publisher's address cross-check (info finding). |
| `DeezRewardsTransferFailures.t.sol` | False-returning and reverting payout tokens roll back harvest, donation accrual, finalization, and payment accounting. A retry succeeds. A payout callback cannot reenter `claim`. |

The existing rewards and hook invariant suites continue to cover reward reserves,
epoch pots, fee claims, harvesting, and proportional payments.

## Oracles and reachability

The new invariant suites set 256 runs and `fail-on-revert = true` inline. Token history
uses depth 80; the lock and launcher use depth 60. Only the listed handler selectors
are targeted. Deterministic sequence tests ensure that successful launches, successful
locks, positive fee-return settlements, approvals, and delegated transfers are reached.

The lock oracle reads position liquidity and fee growth from the PoolManager. It
computes deposited principal with v4's amount-delta library and checks independently:

```
lock cash + cumulative deposited principal = donations + realized LP fees
```

The token oracle integrates an independent balance ledger without truncating intermediate
segments. Its tolerance is at most one wei-day per checkpoint-producing write, not a
percentage of the balance. Historical balance queries require exact equality.

## Deployment finding

The current constructors leave the launch incomplete. The required allocation is locked
only by a later requester call to `DeezLaunch.launch`. The self-contained, locally failing
deployment proof is included in the root `.imd-findings.json` report. It deploys all four
applications in one helper call and checks for the required lock custody immediately
after that call. Actual custody is zero.

The revision that excludes the launcher from rewards does not change this. The finding is reported again,
with its proof, and two info findings are added: the look-alike set described above, and the
liquidity lock, which is not excluded and keeps about 10 $DEEZ of rounding dust after launch.
That dust earns a share of each pot that nobody can claim until `recycle`.

The passing suite tests the safety of the existing launch transition; it does not assert
that a separate transition fulfills deployment-time locking. The previous test that
endorsed an unlaunched deployment now checks constructor wiring only. Mainnet broadcasts,
published transaction hashes, and populated website configuration are not established by
these local tests.

## Reproduce

```sh
forge build
FOUNDRY_FUZZ_SEED=0x29334e60fc03fd5eb36a1b35e9f00e334fe34c90bbd80a896a4a68c9c68794d1 forge test
```

For an isolated local check, append `--out test/scratch/out --cache-path test/scratch/cache`.
The finding proof belongs in scratch when reproducing its expected failure; it is not a
passing regression test until the implementation is corrected.
