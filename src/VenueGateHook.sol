// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {ERC20S} from "./ERC20S.sol";

/// @title VenueGateHook
/// @notice The canonical hook for a `ERC20S`. It does one thing: after
///         every swap and liquidity change in a canonical pool it tells the token
///         how much of it the PoolManager is about to receive or send, so the
///         token's gate lets that settlement through. It refuses to initialize
///         any pool the token has not listed as canonical.
///
///         Flags, read by v4 from the address: before initialize, after swap,
///         after add liquidity, after remove liquidity. Deploy with CREATE2 to an
///         address whose low 14 bits equal `FLAGS`.
///
///         Add your own logic (fees, limits, oracles) on top; keep the
///         `_authorize` calls, they are the gate.
contract VenueGateHook {
    uint160 public constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
    );

    IPoolManager public immutable poolManager;
    ERC20S public immutable token;

    error NotPoolManager();
    error NotCanonicalPool();
    error BadHookAddress();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, ERC20S token_) {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != FLAGS) revert BadHookAddress();
        poolManager = poolManager_;
        token = token_;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (!token.isCanonicalPool(key)) revert NotCanonicalPool();
        return IHooks.beforeInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _authorize(key, delta, false);
        return (IHooks.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        if (token.liquidityAllowed(sender)) _authorize(key, delta, false);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        if (token.liquidityAllowed(sender)) _authorize(key, delta, true);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev The caller's token delta: negative means the PoolManager is owed the
    ///      token (inbound), positive means it pays it out (outbound). Exact, so
    ///      the budget covers this operation and nothing more. A pool the token
    ///      has delisted gets no budget for swaps or new liquidity, only for
    ///      withdrawals, so it can be drained but not traded.
    function _authorize(PoolKey calldata key, BalanceDelta delta, bool withdrawal) internal {
        if (!withdrawal && !token.isCanonicalPool(key)) return;
        int128 leg =
            Currency.unwrap(key.currency0) == address(token) ? delta.amount0() : delta.amount1();
        if (leg == 0) return;
        bool inbound = leg < 0;
        token.authorizePoolManagerTransfer(
            inbound, inbound ? uint256(uint128(-leg)) : uint256(uint128(leg))
        );
    }
}
