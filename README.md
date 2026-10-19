# ERC-20S: Canonical Pool Tokens

## The problem

A project launches a token with a canonical pool: a Uniswap v4 pool whose hook
carries the fees, the launch protections, the protocol-owned liquidity, whatever
the token's economics depend on. The day it gains traction, someone spins up a
second pool for the same token with no hook, or a v2 pair on a fork, and routes
flow there, a "vampire attack" on liqudity.

Liquidity, volume and fees drain out of the pool the project built. The hook
cannot stop it, because a hook only governs its own pool.

## What ERC20S does

ERC-20S is built on the new URC-5 standard that forces trading to stay in the protocol's canonical pool while allowing tokens to be transferable to maintain token flexibility. 

ERC-20S uses the canonical pool's hook, which vouches for each swap and liquidity
change as it happens, and the token refuses to let the PoolManager take in or pay
out anything the hook did not vouch for. Every token that enters Uniswap v4 or
leaves it passes through the canonical pool. A copycat v4 pool can be created,
but no router, aggregator or wallet can fund it or be paid out by it: the only
balances it can hold are ERC-6909 claims that already paid the canonical fee on
the way in, and turning those claims back into tokens costs a canonical trade or
a matching one inside the same transaction. Nothing moves through it cheaper
than through the pool it copies. Copycat pairs on v2, v3 or a fork are refused by address via a
blacklist. For anyone holding the token in a wallet, which is every user of every
router and frontend, the pool the project built is the only pool that works.
Holders are not affected: wallet-to-wallet transfers, custody, multisigs and
claim contracts behave as with any ERC20.

Being built on URC-5, the new Uniswap standard for a token to declare where it
trades, allows seamless routing through aggregators.


## Files

Three files to copy into your own project:

| File | What it is |
|---|---|
| `IVenuePolicy.sol` | The URC-5 interface and the `VenueNotAllowed` error, pinned to [Uniswap/URCs#20](https://github.com/Uniswap/URCs/pull/20). |
| `ERC20S.sol` | ERC-20S, an abstract ERC20. Owner-set mode, canonical pools and external-venue policy, the URC-5 views and events, and the transfer guard. |
| `VenueGateHook.sol` | The canonical hook. Reports each canonical swap's and liquidity change's token leg to the token so its settlement is allowed, and refuses to initialize non-canonical pools. |

`ExampleERC20S.sol` is the smallest concrete token. Dependencies: OpenZeppelin
(`ERC20`, `Ownable2Step`, `TransientSlot`, `IERC165`) and `v4-core`. Solidity
0.8.26, Cancun (transient storage).

## How the gate works

Every v4 pool settles through one PoolManager, so a token cannot tell which pool a
transfer belongs to. The template does not try. Instead:

1. The hook's `afterSwap`, `afterAddLiquidity` and `afterRemoveLiquidity` read the
   token leg of the operation from the balance delta and call
   `token.authorizePoolManagerTransfer(inbound, amount)`. Hook callbacks run
   before the router settles, so the budget is in place when the transfer comes.
2. The token's `_update` lets a transfer into the PoolManager consume the inbound
   budget and a transfer out of it consume the outbound budget. Short budget,
   `VenueNotAllowed(poolManager, 0, inbound)`.
3. Budgets live in transient storage and are gone at the end of the transaction.

A pool for this token without the hook, or a pool with the hook that the token
has not listed, gets no budget. Liquidity cannot be added to it and swaps cannot
settle. The hook also rejects `initialize` for any key the token has not listed,
so a copycat pool cannot even carry this hook's address.

External venues (v2 pairs, v3 pools, other vaults) are separate contracts and are
gated by address. A listed venue moves tokens only in the directions its flags
allow. An unlisted address looks like a wallet to the token and is never blocked.

## Deploying

1. Deploy the token. `hook` is unset and no pool is canonical yet; mode is
   `Enforced`, so no v4 pool can take the token at all.
2. Mine a CREATE2 salt so the hook lands on an address whose low 14 bits equal
   `VenueGateHook.FLAGS`, and deploy `new VenueGateHook{salt: salt}(poolManager, token)`.
   The constructor reverts on a wrong address. `script/VenueGate.s.sol` does this.
3. `token.setHook(hook, true)`.
4. `token.setCanonicalPools([key])` with the pool key(s) you will initialize: the
   token on one side, `hooks == hook`, any fee and tick spacing.
5. `poolManager.initialize(key, sqrtPrice)`, then add liquidity. Outside LPs are off
   by default, so first list your LP contract with `setLiquidityProvider` or open the
   pool with `setOutsideLiquidity(true)` (see below).

Delisting a pool with `setCanonicalPools` stops swaps and new liquidity in it at
once; withdrawals keep working so LPs can leave. The same goes for a retired hook:
`setHook(old, false)` only after its pools are drained, since a hook the token no
longer allows cannot authorize anything, withdrawals included. To upgrade, allow
the new hook, list its pool, delist the old pool, and leave the old hook allowed
until it is empty.

An external venue listed with both flags false is refused in both directions.
`removeExternalVenue` returns it to the default for each direction.

Outside LPs are off by default. Any outside position is a way to mint transfer budget
without paying a fee (decrease and re-add it in one transaction, netted inside the
PoolManager, and both legs are vouched for while nothing is settled), so the hook vouches
for nobody's LP settlement until you say so. Two ways to add liquidity:

- `setLiquidityProvider(contract, true)` for a contract that settles each leg in ERC-20
  before returning and makes no external calls in between. Never a batching position
  manager; it can net a decrease against a re-add and leave budget behind.
- `setOutsideLiquidity(true)` opens the pool to any LP router, position managers included,
  and accepts the fee-free bridge that comes with it. Turn it off again at any time;
  outside positions then exit as claims.

Caveat: Malicious V4 pools are blocked indefinitely, but the team must be aware of newly spun up V2/V3 pools and add them to the gated list (either via keeper or manual).

## Modes

`Enforced` (default) is the gate above plus the declaration. `Preferred` switches
every check off: the token trades anywhere, `canonicalPools()` still names your
primary pool for discovery, `venueAllowed` reports true and `externalVenues()` is
empty, per the URC. Flip with `setEnforcement`; the event tells consumers to
re-read.



## Extending the hook

`VenueGateHook` is deliberately empty apart from the gate. Add fees, limits or
anything else, keep the four callbacks' flags in `FLAGS` (add more if you need
them, the address must match) and keep the `_authorize` calls. If you charge a fee
in the token by hook delta, authorize the net leg the PoolManager will actually
move.

## Consumer notes

Routers read `venueEnforcement()`, `canonicalPools()` and `externalVenues()`, and
treat a `VenueNotAllowed` revert as a policy refusal, not a broken token. The
PoolManager wraps hook and token reverts in `WrappedError`; match the inner
selector.
