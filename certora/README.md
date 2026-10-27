# BeHYPE — merged single-contract target for Certora Autoprover

The Autoprover takes a single contract and infers its dependencies. Analysed one at a time,
`StakingCore`, `WithdrawManager` and `BeHYPE` each see the other two as unknown (havoced)
external contracts. That loses the exchange-ratio denominator (`totalSupply`), the beHYPE escrow,
liquidity (`address(stakingCore).balance`) and the `hypeRequestedForWithdraw` bound. This folder
merges the three into one contract so those properties can be stated and proved.

The original `src/StakingCore.sol`, `src/WithdrawManager.sol`, `src/BeHYPE.sol` and
`src/lib/BucketLimiter.sol` have been removed; `BeHYPEProtocol` is now the protocol's only
implementation. The originals remain in git history at commit `8041e71`.

| File | Purpose |
|---|---|
| `BeHYPEProtocol.flat.sol` | **Upload this to the Autoprover.** Self-contained (no imports); exactly one concrete contract, `BeHYPEProtocol`. Compiles with solc 0.8.26 – 0.8.36, with and without via-IR. |
| `BeHYPEProtocol.sol` | Readable source of the merge (imports OZ from `lib/`). The flat file is generated from it. |
| `../test/*.t.sol` | The project's unit tests, ported to run against the merged contract. |

Regenerate the flat file after editing the source:

```sh
forge flatten certora/BeHYPEProtocol.sol -o certora/BeHYPEProtocol.flat.sol
```

## What is merged and what stays external

| Component | Treatment | Why |
|---|---|---|
| `StakingCore` | merged | Custodies HYPE; owns the exchange ratio |
| `WithdrawManager` | merged | Owns the liabilities (queue, `hypeRequestedForWithdraw`), escrows beHYPE |
| `BeHYPE` (ERC20Permit) | merged | `totalSupply` is the ratio denominator; escrow balance |
| `BucketLimiter` (was `src/lib/BucketLimiter.sol`) | inlined | The original `canConsume`/`consumable` are `external` (a separately linked library). They are now `internal`; the code is otherwise verbatim. |
| `RoleRegistry` | **external** (`IRoleRegistry` subset) | Pure access control on Solady `EnumerableRoles`. Verify it as its own Autoprover job. |
| `L1Read` (HyperCore precompiles 0x801/0x805) | **external** (`IL1Read`) | HyperCore state changes between EVM txs, so havoc is the sound model |
| `CoreWriter` (0x3333…) | **external** (`ICoreWriter`) | System contract; fire-and-forget |
| `BeHYPETimelock`, `UUPSProxy`, `ICreate3Deployer` | omitted | Deployment-only / unmodified OZ |

## How the cross-contract permission checks are preserved

Every former cross-contract hop is now an internal call. Each one still performs the check the
callee used to perform, against the same owner-settable pointer. The pointers are initialised to
`address(this)` (the correctly wired deployment).

| Original hop | Original check (in callee) | Merged |
|---|---|---|
| `StakingCore.stake` → `BeHYPE.mint` | `msg.sender == BeHYPE.stakingCore` | `_mintFromStakingCore`: `tokenStakingCore == address(this)` |
| `WithdrawManager` → `BeHYPE.burn` | `msg.sender == BeHYPE.withdrawManager` | `_burnFromWithdrawManager`: `tokenWithdrawManager == address(this)` |
| `WithdrawManager` → `StakingCore.sendFromWithdrawManager` | `msg.sender == StakingCore.withdrawManager` | `_sendFromWithdrawManager`: `withdrawManager == address(this)` |
| `StakingCore` → `IWithdrawManager(withdrawManager).hypeRequestedForWithdraw()` | — | Internal read if `withdrawManager == address(this)`, otherwise the same external call |
| `WithdrawManager` → `BeHYPE.transferFrom(user, WM, x)` | allowance `user → WM` | `_spendAllowance(user, address(this), x)` + `_transfer` (same order and errors as OZ `transferFrom`) |

The external entry points `mint`, `burn` and `sendFromWithdrawManager` keep their `msg.sender`
guards. If the protocol upgrader re-points a pointer to an EOA, that EOA gains exactly the powers
it would have in the original system, and the internal paths revert with the same errors.

## Interface mapping (original → merged)

All other functions, errors and events keep their names, selectors and signatures.

| Original | Merged |
|---|---|
| `BeHYPE.setStakingCore(address)` | `setTokenStakingCore(address)` |
| `BeHYPE.setWithdrawManager(address)` | `setTokenWithdrawManager(address)` (selector clashes with `StakingCore.setWithdrawManager`) |
| `BeHYPE.stakingCore()` / `BeHYPE.withdrawManager()` | `tokenStakingCore()` / `tokenWithdrawManager()` |
| `StakingCore.paused()` / `WithdrawManager.paused()` | `stakingPaused()` / `withdrawalsPaused()` (two independent flags; same `Paused`/`Unpaused` events and `EnforcedPause`/`ExpectedPause` errors) |
| `StakingCore.beHypeToken()`, `WithdrawManager.beHypeToken()`, `WithdrawManager.stakingCore()` | Same names; return `address(this)` |
| 3 × `initialize(...)` | `initialize(name, symbol, roleRegistry, InitConfig)`; the struct groups the StakingCore/WithdrawManager params so legacy (non-via-IR) codegen does not hit "stack too deep" |

To deploy against the unmodified `RoleRegistry`, point both its `withdrawManager` and its
`stakingCore` at the merged contract. `pauseProtocol()` then pauses both flags, as before.

## Residual differences (inherent to collapsing three addresses into one)

These are the only behaviours that differ, and they cannot be avoided in a single contract:

1. **Address collapse.**
   - HYPE sent directly to the WithdrawManager or token address is stranded in the original and
     not counted in `getTotalProtocolHype`. In the merged contract it is counted.
   - beHYPE sent to the StakingCore or token address is stuck in the original. In the merged
     contract it lands in the escrow balance `balanceOf(this)`.
   - Users approve the merged address instead of the WithdrawManager.

   When writing specs, express escrow properties as `balanceOf(currentContract) >= Σ unfinalized beHypeAmount`.
2. **Single proxy.** One upgrade replaces all three implementations.
3. **EIP-712 domain.** `verifyingContract` is the merged address, so permit signatures are
   per-deployment (the semantics are identical).
4. **Fewer call frames.** The 63/64 gas forwarding differs. This only matters for gas-griefing
   recipients.
5. **One emitter.** All events come from one address.

## Equivalence evidence

Equivalence with the original 3-contract system was established before the originals were
removed. Commit `8041e71` contains both systems and the differential suite
(`test/equivalence/`). It deploys them side by side, executes every action on both, and compares:

- success or revert, and the exact revert and return data (original SC/WM/token addresses
  normalised to the merged address);
- every emitted log (emitter, topics, data);
- ETH deltas of every tracked account and of protocol custody;
- the full observable state after each call.

That suite had 13 scenario and fuzz tests plus a stateful differential fuzzer over 15 action
types. A deep campaign of 512 runs × 100 depth (51,200 calls) found 0 divergences. The suite was
mutation-tested, and all seven planted bugs were caught. To reproduce:

```sh
git checkout 8041e71 && forge test --match-path "test/equivalence/*"
```

After the removal, the project's original 43 unit tests run against the merged contract with
their assertions unchanged (exact fees, balances, exchange ratios and revert selectors). In
`test/Base.t.sol`, the `beHYPE`, `stakingCore` and `withdrawManager` handles all point at the one
`BeHYPEProtocol` proxy. Only upgrade/re-initialization calls and `paused()` →
`stakingPaused()`/`withdrawalsPaused()` were adapted.

```sh
forge test
```

The flat file's runtime bytecode is byte-identical (metadata stripped) to the tested source build.

## Notes for writing specs

- Intended-configuration assumptions:
  - `withdrawManager == tokenStakingCore == tokenWithdrawManager == currentContract`;
  - `roleRegistry.protocolTreasury() != currentContract` (otherwise fees fold into the escrow).
- The constructor calls `_disableInitializers()`, as the originals do. Invariants therefore need
  `initialize` to be treated as the setup step (or filtered).
- `finalizeWithdrawals` is not `nonReentrant`. A recipient's `receive()` can call
  `withdraw(…, true)` mid-loop, before `lastFinalizedIndex` and `hypeRequestedForWithdraw` are
  updated. The merge keeps this window (the payout is a real external call), so the prover can
  explore it.
