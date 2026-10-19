// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IVenuePolicy, VenueNotAllowed} from "./IVenuePolicy.sol";

/// @title ERC20S
/// @notice ERC20S: an ERC20 that declares and enforces where it trades (URC-5).
///
///         Declaration: the owner sets the mode, the canonical v4 pools, and
///         the external-venue policy; every change emits the URC-5 events so
///         routers and frontends re-read it.
///
///         Enforcement, in `Enforced` mode only:
///         - v4 pools all settle through one PoolManager, so the token cannot
///           tell pools apart by address. Instead the canonical hook reports
///           the token leg of every canonical swap and liquidity change from
///           its callbacks, which run before the router settles, and the token
///           lets the PoolManager receive or send only up to that budget in the
///           same transaction. A pool without the hook earns no budget and its
///           settlement reverts. Budgets are transient and die with the
///           transaction.
///         - External venues (v2 pairs, v3 pools, other vaults) are separate
///           contracts and are gated by address: a listed venue moves tokens
///           only in the directions its flags allow. An unlisted address is
///           indistinguishable from a wallet, so it is never blocked; the
///           restriction flags are a declaration consumers honor, not something
///           the token can prove.
///
///         Every refusal reverts `VenueNotAllowed`. Mint and burn are exempt.
///         Inherit, mint in your constructor, and deploy a `VenueGateHook`
///         bound to the token.
abstract contract ERC20S is ERC20, Ownable2Step, IVenuePolicy, IERC165 {
    using PoolIdLibrary for PoolKey;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;

    struct VenueFlags {
        bool listed;
        bool inbound;
        bool outbound;
    }

    bytes32 private constant INBOUND_BUDGET_SLOT = keccak256("urc5.ERC20S.inbound");
    bytes32 private constant OUTBOUND_BUDGET_SLOT = keccak256("urc5.ERC20S.outbound");

    address public immutable poolManager;
    /// @notice Hooks that may grant PoolManager budgets. Every canonical pool
    ///         must carry one. Keep a retired hook allowed until its pools have
    ///         been drained, or their LPs cannot withdraw.
    mapping(address hook => bool) public isHook;

    VenueEnforcement internal _enforcement = VenueEnforcement.Enforced;
    PoolKey[] internal _canonical;
    mapping(PoolId => bool) internal _isCanonical;
    bool public inboundRestricted;
    bool public outboundRestricted;
    mapping(address venue => VenueFlags) internal _external;
    address[] internal _externalList;
    /// @dev Off (default): canonical pools vouch for no LP settlement except from
    ///      listed providers, so outside positions can only move as claims. List
    ///      only a contract that settles each leg in ERC-20 before returning;
    ///      never a batching position manager.
    bool public outsideLiquidity;
    mapping(address sender => bool) public isLiquidityProvider;

    event HookSet(address hook, bool allowed);
    event OutsideLiquiditySet(bool allowed);
    event LiquidityProviderSet(address sender, bool allowed);
    event PoolManagerTransferAuthorized(bool inbound, uint256 amount);

    error ZeroAddress();
    error NotHook();
    error InvalidCanonicalPool();
    error InvalidVenue();

    constructor(address poolManager_, address initialOwner) Ownable(initialOwner) {
        if (poolManager_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
    }

    // ------------------------------------------------------------------
    // Owner policy
    // ------------------------------------------------------------------

    /// @notice Allows or retires a hook. Allow it before listing its pools.
    function setHook(address hook_, bool allowed) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        isHook[hook_] = allowed;
        emit HookSet(hook_, allowed);
    }

    function setOutsideLiquidity(bool allowed) external onlyOwner {
        outsideLiquidity = allowed;
        emit OutsideLiquiditySet(allowed);
    }

    function setLiquidityProvider(address sender, bool allowed) external onlyOwner {
        if (sender == address(0)) revert ZeroAddress();
        isLiquidityProvider[sender] = allowed;
        emit LiquidityProviderSet(sender, allowed);
    }

    /// @notice Whether the hook vouches for `sender`'s liquidity settlements.
    function liquidityAllowed(address sender) external view returns (bool) {
        return outsideLiquidity || isLiquidityProvider[sender];
    }

    function setEnforcement(VenueEnforcement enforcement) external onlyOwner {
        _enforcement = enforcement;
        emit VenueEnforcementChanged(enforcement);
    }

    /// @notice Replaces the canonical pool list, most preferred first. Every key
    ///         must pair this token and carry an allowed hook.
    function setCanonicalPools(PoolKey[] calldata keys) external onlyOwner {
        _clearCanonical();
        for (uint256 i = 0; i < keys.length; i++) {
            PoolKey calldata key = keys[i];
            bool hasToken = Currency.unwrap(key.currency0) == address(this)
                || Currency.unwrap(key.currency1) == address(this);
            PoolId id = key.toId();
            if (!hasToken || !isHook[address(key.hooks)] || _isCanonical[id]) {
                revert InvalidCanonicalPool();
            }
            _canonical.push(key);
            _isCanonical[id] = true;
        }
        emit CanonicalPoolsChanged();
    }

    function _clearCanonical() internal {
        for (uint256 i = 0; i < _canonical.length; i++) {
            _isCanonical[_canonical[i].toId()] = false;
        }
        delete _canonical;
    }

    /// @notice Declares whether unlisted external venues are permitted per direction.
    function setExternalRestriction(bool inbound, bool outbound) external onlyOwner {
        inboundRestricted = inbound;
        outboundRestricted = outbound;
        emit ExternalVenuesChanged();
    }

    /// @notice Lists an external venue with per-direction permission. Both false
    ///         is a full refusal. Cannot name the PoolManager or this token.
    function setExternalVenue(address venue, bool inbound, bool outbound) external onlyOwner {
        if (venue == address(0) || venue == poolManager || venue == address(this)) {
            revert InvalidVenue();
        }
        VenueFlags storage f = _external[venue];
        if (!f.listed) {
            f.listed = true;
            _externalList.push(venue);
        }
        f.inbound = inbound;
        f.outbound = outbound;
        emit VenueStatusChanged(venue, 0, true, inbound);
        emit VenueStatusChanged(venue, 0, false, outbound);
        emit ExternalVenuesChanged();
    }

    /// @notice Unlists a venue, returning it to the default for each direction:
    ///         permitted where unrestricted, refused where restricted.
    function removeExternalVenue(address venue) external onlyOwner {
        if (!_external[venue].listed) revert InvalidVenue();
        delete _external[venue];
        uint256 n = _externalList.length;
        for (uint256 i = 0; i < n; i++) {
            if (_externalList[i] == venue) {
                _externalList[i] = _externalList[n - 1];
                _externalList.pop();
                break;
            }
        }
        emit VenueStatusChanged(venue, 0, true, !inboundRestricted);
        emit VenueStatusChanged(venue, 0, false, !outboundRestricted);
        emit ExternalVenuesChanged();
    }

    // ------------------------------------------------------------------
    // PoolManager budget, granted by the hook
    // ------------------------------------------------------------------

    /// @notice Allow `amount` more of this token to move into (`inbound`) or out
    ///         of the PoolManager during this transaction. Allowed hooks only.
    function authorizePoolManagerTransfer(bool inbound, uint256 amount) external {
        if (!isHook[msg.sender]) revert NotHook();
        TransientSlot.Uint256Slot slot = _budgetSlot(inbound);
        slot.tstore(slot.tload() + amount);
        emit PoolManagerTransferAuthorized(inbound, amount);
    }

    /// @notice What the PoolManager may still receive (`inbound`) or send this transaction.
    function poolManagerTransferBudget(bool inbound) external view returns (uint256) {
        return _budgetSlot(inbound).tload();
    }

    function _budgetSlot(bool inbound) private pure returns (TransientSlot.Uint256Slot) {
        return (inbound ? INBOUND_BUDGET_SLOT : OUTBOUND_BUDGET_SLOT).asUint256();
    }

    function _consumeBudget(bool inbound, uint256 amount) private {
        TransientSlot.Uint256Slot slot = _budgetSlot(inbound);
        uint256 budget = slot.tload();
        if (budget < amount) revert VenueNotAllowed(poolManager, 0, inbound);
        slot.tstore(budget - amount);
    }

    // ------------------------------------------------------------------
    // Transfer guard
    // ------------------------------------------------------------------

    function _update(address from, address to, uint256 value) internal virtual override {
        if (_enforcement == VenueEnforcement.Enforced && from != address(0) && to != address(0)) {
            if (to == poolManager) _consumeBudget(true, value);
            else if (from == poolManager) _consumeBudget(false, value);
            VenueFlags storage into = _external[to];
            if (into.listed && !into.inbound) revert VenueNotAllowed(to, 0, true);
            VenueFlags storage outOf = _external[from];
            if (outOf.listed && !outOf.outbound) revert VenueNotAllowed(from, 0, false);
        }
        super._update(from, to, value);
    }

    // ------------------------------------------------------------------
    // URC-5 views
    // ------------------------------------------------------------------

    function venueEnforcement() external view returns (VenueEnforcement) {
        return _enforcement;
    }

    function canonicalPools() external view returns (PoolKey[] memory) {
        return _canonical;
    }

    function isCanonicalPool(PoolKey calldata key) external view returns (bool) {
        return _isCanonical[key.toId()];
    }

    /// @dev Preferred: everything. Enforced: a v4 pool only if canonical; a listed
    ///      venue by its flag; an unlisted venue by whether its direction is
    ///      restricted.
    function venueAllowed(address venue, bytes32 poolId, bool inbound)
        external
        view
        returns (bool)
    {
        if (_enforcement == VenueEnforcement.Preferred) return true;
        if (venue == poolManager) return _isCanonical[PoolId.wrap(poolId)];
        VenueFlags storage f = _external[venue];
        if (f.listed) return inbound ? f.inbound : f.outbound;
        return inbound ? !inboundRestricted : !outboundRestricted;
    }

    /// @dev The allowlist for each restricted direction. A listed venue's flag is
    ///      reported only where that direction is restricted; a refusal in an
    ///      unrestricted direction is a reactive one, visible through `venueAllowed`.
    function externalVenues() external view returns (bool, bool, ExternalVenue[] memory allowed) {
        if (_enforcement == VenueEnforcement.Preferred) return (false, false, allowed);
        uint256 n;
        ExternalVenue[] memory all = new ExternalVenue[](_externalList.length);
        for (uint256 i = 0; i < _externalList.length; i++) {
            VenueFlags storage f = _external[_externalList[i]];
            bool inb = f.inbound && inboundRestricted;
            bool outb = f.outbound && outboundRestricted;
            if (inb || outb) {
                all[n++] = ExternalVenue({venue: _externalList[i], inbound: inb, outbound: outb});
            }
        }
        allowed = new ExternalVenue[](n);
        for (uint256 i = 0; i < n; i++) {
            allowed[i] = all[i];
        }
        return (inboundRestricted, outboundRestricted, allowed);
    }

    function supportsInterface(bytes4 id) public view virtual returns (bool) {
        return id == type(IVenuePolicy).interfaceId || id == type(IERC165).interfaceId;
    }
}
