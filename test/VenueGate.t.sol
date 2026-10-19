// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IVenuePolicy, VenueNotAllowed} from "../src/IVenuePolicy.sol";
import {ERC20S} from "../src/ERC20S.sol";
import {VenueGateHook} from "../src/VenueGateHook.sol";
import {ExampleERC20S} from "../src/ExampleERC20S.sol";

/// @notice The URC-5 template end to end: a hookless copy pool cannot take the
///         token, the canonical pool settles every shape, the budget is exact
///         per direction, external venues are gated by address, the views and
///         events follow the URC in both modes.
contract VenueGateTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    address internal owner = makeAddr("owner");
    address internal trader = makeAddr("trader");
    address internal alice = makeAddr("alice");
    address internal v2Pair = makeAddr("v2Pair");

    PoolManager internal manager;
    MockERC20 internal usdc;
    ExampleERC20S internal token;
    VenueGateHook internal hook;
    PoolModifyLiquidityTest internal lp;
    PoolSwapTest internal swapper;

    PoolKey internal canonicalKey;
    PoolKey internal hooklessKey;
    bool internal tokenIs0;

    function setUp() public {
        manager = new PoolManager(owner);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        token = new ExampleERC20S("ERC20S", "ERC20S", 1e27, address(manager), owner);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        address hookAddr = address(uint160(0x4444 << 20) | flags);
        deployCodeTo("VenueGateHook.sol", abi.encode(manager, token), hookAddr);
        hook = VenueGateHook(hookAddr);
        vm.prank(owner);
        token.setHook(hookAddr, true);

        tokenIs0 = address(token) < address(usdc);
        (Currency c0, Currency c1) = tokenIs0
            ? (Currency.wrap(address(token)), Currency.wrap(address(usdc)))
            : (Currency.wrap(address(usdc)), Currency.wrap(address(token)));
        canonicalKey = PoolKey({
            currency0: c0, currency1: c1, fee: 3_000, tickSpacing: 60, hooks: IHooks(hookAddr)
        });
        hooklessKey = PoolKey({
            currency0: c0, currency1: c1, fee: 3_000, tickSpacing: 60, hooks: IHooks(address(0))
        });
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = canonicalKey;
        vm.prank(owner);
        token.setCanonicalPools(keys);
        vm.prank(owner);
        token.setOutsideLiquidity(true);

        manager.initialize(canonicalKey, SQRT_PRICE_1_1);
        manager.initialize(hooklessKey, SQRT_PRICE_1_1);

        lp = new PoolModifyLiquidityTest(manager);
        swapper = new PoolSwapTest(manager);
        vm.prank(owner);
        token.transfer(trader, 1e24);
        usdc.mint(trader, 1e24);
        vm.startPrank(trader);
        token.approve(address(lp), type(uint256).max);
        token.approve(address(swapper), type(uint256).max);
        usdc.approve(address(lp), type(uint256).max);
        usdc.approve(address(swapper), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _addLiquidity(PoolKey memory key, int256 liquidity) internal {
        vm.prank(trader);
        lp.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: liquidity,
                salt: 0
            }),
            ""
        );
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(trader);
        swapper.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev PoolManager wraps a token revert raised during settlement.
    function _wrapped(bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(token),
            bytes4(inner),
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _venueNotAllowed(address venue, bool inbound) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(VenueNotAllowed.selector, venue, bytes32(0), inbound);
    }

    // ------------------------------------------------------------------
    // The gate
    // ------------------------------------------------------------------

    function _lpParams(int256 liquidity)
        internal
        view
        returns (IPoolManager.ModifyLiquidityParams memory)
    {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(canonicalKey.tickSpacing),
            tickUpper: TickMath.maxUsableTick(canonicalKey.tickSpacing),
            liquidityDelta: liquidity,
            salt: 0
        });
    }

    /// @dev Off (the default): only listed providers get LP budgets; everyone
    ///      else moves as claims.
    function test_outsideLiquidity_switchAndProviderList() public {
        ExampleERC20S fresh = new ExampleERC20S("F", "F", 1e18, address(manager), owner);
        assertFalse(fresh.outsideLiquidity(), "off by default");
        _addLiquidity(canonicalKey, 1e18);

        vm.startPrank(owner);
        token.setOutsideLiquidity(false);
        vm.expectRevert(ERC20S.ZeroAddress.selector);
        token.setLiquidityProvider(address(0), true);
        vm.stopPrank();
        assertFalse(token.liquidityAllowed(address(lp)));

        vm.prank(trader);
        vm.expectRevert();
        lp.modifyLiquidity(canonicalKey, _lpParams(1e18), "");
        vm.prank(trader);
        vm.expectRevert();
        lp.modifyLiquidity(canonicalKey, _lpParams(-1e18), "");
        vm.prank(trader);
        lp.modifyLiquidity(canonicalKey, _lpParams(-5e17), "", false, true);
        assertGt(manager.balanceOf(trader, uint256(uint160(address(token)))), 0, "out as claims");
        _swap(canonicalKey, tokenIs0, -1e18);

        vm.prank(owner);
        token.setLiquidityProvider(address(lp), true);
        assertTrue(token.liquidityAllowed(address(lp)));
        vm.prank(trader);
        lp.modifyLiquidity(canonicalKey, _lpParams(-5e17), "");
        vm.prank(trader);
        lp.modifyLiquidity(canonicalKey, _lpParams(1e18), "");

        vm.prank(owner);
        token.setLiquidityProvider(address(lp), false);
        vm.prank(owner);
        token.setOutsideLiquidity(true);
        vm.prank(trader);
        lp.modifyLiquidity(canonicalKey, _lpParams(-1e18), "");
        assertEq(token.poolManagerTransferBudget(true), 0);
        assertEq(token.poolManagerTransferBudget(false), 0);
    }

    function test_hooklessPool_cannotTakeTheToken() public {
        vm.prank(trader);
        vm.expectRevert();
        lp.modifyLiquidity(
            hooklessKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e18,
                salt: 0
            }),
            ""
        );
    }

    function test_canonicalPool_liquidityAndEverySwapShapeSettle() public {
        _addLiquidity(canonicalKey, 1e21);
        uint256 before = token.balanceOf(trader);
        _swap(canonicalKey, tokenIs0, -1e18);
        _swap(canonicalKey, tokenIs0, 1e6);
        _swap(canonicalKey, !tokenIs0, -1e6);
        _swap(canonicalKey, !tokenIs0, 1e18);
        assertTrue(token.balanceOf(trader) != before);
        _addLiquidity(canonicalKey, -5e20);
        assertEq(token.poolManagerTransferBudget(true), 0);
        assertEq(token.poolManagerTransferBudget(false), 0);
    }

    function test_hookRefusesNonCanonicalKey() public {
        PoolKey memory other = canonicalKey;
        other.fee = 500;
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_budget_isExactPerDirectionAndOnlyTheHookGrantsIt() public {
        vm.expectRevert(ERC20S.NotHook.selector);
        token.authorizePoolManagerTransfer(true, 1);

        vm.prank(address(hook));
        token.authorizePoolManagerTransfer(true, 10);
        assertEq(token.poolManagerTransferBudget(true), 10);
        assertEq(token.poolManagerTransferBudget(false), 0);

        vm.prank(trader);
        vm.expectRevert(_venueNotAllowed(address(manager), true));
        token.transfer(address(manager), 11);
        vm.prank(trader);
        token.transfer(address(manager), 10);
        assertEq(token.poolManagerTransferBudget(true), 0);

        vm.prank(trader);
        vm.expectRevert(_venueNotAllowed(address(manager), true));
        token.transfer(address(manager), 1);
    }

    function test_walletTransfersAreFree() public {
        vm.prank(trader);
        token.transfer(alice, 5e18);
        vm.prank(alice);
        token.approve(trader, 5e18);
        vm.prank(trader);
        token.transferFrom(alice, trader, 5e18);
        assertEq(token.balanceOf(trader), 1e24);
    }

    function test_externalVenue_flagsGateByDirection() public {
        vm.prank(owner);
        token.setExternalVenue(v2Pair, false, true);
        vm.prank(trader);
        vm.expectRevert(_venueNotAllowed(v2Pair, true));
        token.transfer(v2Pair, 1);

        vm.prank(owner);
        token.setExternalVenue(v2Pair, true, false);
        vm.prank(trader);
        token.transfer(v2Pair, 1);
        vm.prank(v2Pair);
        vm.expectRevert(_venueNotAllowed(v2Pair, false));
        token.transfer(trader, 1);

        vm.prank(owner);
        token.setExternalVenue(v2Pair, false, false);
        vm.prank(v2Pair);
        vm.expectRevert(_venueNotAllowed(v2Pair, false));
        token.transfer(trader, 1);
        vm.prank(trader);
        vm.expectRevert(_venueNotAllowed(v2Pair, true));
        token.transfer(v2Pair, 1);
        (,, IVenuePolicy.ExternalVenue[] memory list) = token.externalVenues();
        assertEq(list.length, 0, "a full refusal is reactive, not an allowlist entry");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(token));
        emit IVenuePolicy.VenueStatusChanged(v2Pair, 0, true, true);
        vm.expectEmit(true, true, true, true, address(token));
        emit IVenuePolicy.VenueStatusChanged(v2Pair, 0, false, true);
        token.removeExternalVenue(v2Pair);
        vm.prank(v2Pair);
        token.transfer(trader, 1);
        vm.prank(owner);
        vm.expectRevert(ERC20S.InvalidVenue.selector);
        token.removeExternalVenue(v2Pair);
    }

    function test_setExternalVenue_rejectsPoolManagerSelfAndZero() public {
        vm.startPrank(owner);
        vm.expectRevert(ERC20S.InvalidVenue.selector);
        token.setExternalVenue(address(manager), true, true);
        vm.expectRevert(ERC20S.InvalidVenue.selector);
        token.setExternalVenue(address(token), true, true);
        vm.expectRevert(ERC20S.InvalidVenue.selector);
        token.setExternalVenue(address(0), true, true);
        vm.stopPrank();
    }

    function test_setCanonicalPools_requiresTheTokenAndTheHook() public {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = hooklessKey;
        vm.prank(owner);
        vm.expectRevert(ERC20S.InvalidCanonicalPool.selector);
        token.setCanonicalPools(keys);

        keys[0] = canonicalKey;
        keys[0].currency0 = Currency.wrap(address(usdc));
        keys[0].currency1 = Currency.wrap(address(0xBEEF));
        vm.prank(owner);
        vm.expectRevert(ERC20S.InvalidCanonicalPool.selector);
        token.setCanonicalPools(keys);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        token.setCanonicalPools(keys);
    }

    function test_setHook_allowlistGatesAuthorizeAndCanonicalKeys() public {
        vm.prank(owner);
        token.setHook(address(hook), false);
        vm.prank(address(hook));
        vm.expectRevert(ERC20S.NotHook.selector);
        token.authorizePoolManagerTransfer(true, 1);
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = canonicalKey;
        vm.prank(owner);
        vm.expectRevert(ERC20S.InvalidCanonicalPool.selector);
        token.setCanonicalPools(keys);
        assertTrue(
            token.isCanonicalPool(canonicalKey), "listing survives, only the hook is retired"
        );

        vm.prank(owner);
        token.setHook(address(hook), true);
        _addLiquidity(canonicalKey, 1e21);
    }

    function test_delistedPool_canOnlyBeDrained() public {
        _addLiquidity(canonicalKey, 1e21);
        vm.prank(owner);
        token.setCanonicalPools(new PoolKey[](0));

        vm.prank(trader);
        vm.expectRevert();
        swapper.swap(
            canonicalKey,
            IPoolManager.SwapParams({
                zeroForOne: tokenIs0,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: tokenIs0
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.prank(trader);
        vm.expectRevert();
        lp.modifyLiquidity(
            canonicalKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e18,
                salt: 0
            }),
            ""
        );
        _addLiquidity(canonicalKey, -1e21);
    }

    function test_retiredHook_blocksWithdrawalsUntilReallowed() public {
        _addLiquidity(canonicalKey, 1e21);
        vm.prank(owner);
        token.setHook(address(hook), false);
        vm.prank(trader);
        vm.expectRevert();
        lp.modifyLiquidity(
            canonicalKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: -1e21,
                salt: 0
            }),
            ""
        );
        vm.prank(owner);
        token.setHook(address(hook), true);
        _addLiquidity(canonicalKey, -1e21);
    }

    // ------------------------------------------------------------------
    // Views and events
    // ------------------------------------------------------------------

    function test_interfaceId_andErc165() public view {
        bytes4 expected = IVenuePolicy.canonicalPools.selector ^ IVenuePolicy.venueAllowed.selector
            ^ IVenuePolicy.venueEnforcement.selector ^ IVenuePolicy.externalVenues.selector;
        assertEq(type(IVenuePolicy).interfaceId, expected);
        assertTrue(token.supportsInterface(expected));
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertFalse(token.supportsInterface(0xdeadbeef));
    }

    function test_views_enforced() public {
        assertEq(uint8(token.venueEnforcement()), uint8(IVenuePolicy.VenueEnforcement.Enforced));
        PoolKey[] memory keys = token.canonicalPools();
        assertEq(keys.length, 1);
        assertEq(PoolId.unwrap(keys[0].toId()), PoolId.unwrap(canonicalKey.toId()));

        assertTrue(token.venueAllowed(address(manager), PoolId.unwrap(canonicalKey.toId()), true));
        assertFalse(token.venueAllowed(address(manager), PoolId.unwrap(hooklessKey.toId()), true));
        assertTrue(token.venueAllowed(v2Pair, 0, true), "unrestricted direction, unlisted venue");

        vm.startPrank(owner);
        token.setExternalRestriction(true, false);
        token.setExternalVenue(v2Pair, true, true);
        vm.stopPrank();
        assertFalse(token.venueAllowed(alice, 0, true), "restricted direction, unlisted venue");
        assertTrue(token.venueAllowed(alice, 0, false));
        assertTrue(token.venueAllowed(v2Pair, 0, true));

        (bool inb, bool outb, IVenuePolicy.ExternalVenue[] memory list) = token.externalVenues();
        assertTrue(inb);
        assertFalse(outb);
        assertEq(list.length, 1);
        assertEq(list[0].venue, v2Pair);
        assertTrue(list[0].inbound);
        assertFalse(list[0].outbound, "flag masked where the direction is unrestricted");
    }

    function test_preferredMode_switchesTheGateOffAndReportsNoRestrictions() public {
        vm.prank(owner);
        token.setExternalVenue(v2Pair, false, false);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(token));
        emit IVenuePolicy.VenueEnforcementChanged(IVenuePolicy.VenueEnforcement.Preferred);
        token.setEnforcement(IVenuePolicy.VenueEnforcement.Preferred);

        _addLiquidity(hooklessKey, 1e21);
        _swap(hooklessKey, tokenIs0, -1e18);
        assertTrue(token.venueAllowed(address(manager), PoolId.unwrap(hooklessKey.toId()), true));
        (bool inb, bool outb, IVenuePolicy.ExternalVenue[] memory list) = token.externalVenues();
        assertFalse(inb);
        assertFalse(outb);
        assertEq(list.length, 0);
        assertEq(token.canonicalPools().length, 1, "canonical pools still advertised");
    }

    function test_events_onEveryPolicyChange() public {
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = canonicalKey;
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(token));
        emit IVenuePolicy.CanonicalPoolsChanged();
        token.setCanonicalPools(keys);

        vm.expectEmit(true, true, true, true, address(token));
        emit IVenuePolicy.ExternalVenuesChanged();
        token.setExternalRestriction(true, true);

        vm.expectEmit(true, true, true, true, address(token));
        emit IVenuePolicy.VenueStatusChanged(v2Pair, 0, true, true);
        vm.expectEmit(true, true, true, true, address(token));
        emit IVenuePolicy.VenueStatusChanged(v2Pair, 0, false, false);
        vm.expectEmit(true, true, true, true, address(token));
        emit IVenuePolicy.ExternalVenuesChanged();
        token.setExternalVenue(v2Pair, true, false);
        vm.stopPrank();
    }

    function test_mintIsExempt() public {
        // Minting into the PoolManager needs no budget: from == address(0).
        ExampleERC20S fresh = new ExampleERC20S("F", "F", 1, address(manager), address(manager));
        assertEq(fresh.balanceOf(address(manager)), 1);
    }

    function test_hookConstructor_rejectsWrongAddress() public {
        vm.expectRevert(VenueGateHook.BadHookAddress.selector);
        new VenueGateHook(manager, token);
    }
}
