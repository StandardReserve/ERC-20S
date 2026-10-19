// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice URC-5 token venue policy, pinned to Uniswap/URCs#20 as of 2026-10-16.
///         Declares a token's preferred pools and venue restrictions.
///         ERC-165 interface id: `type(IVenuePolicy).interfaceId`.
interface IVenuePolicy {
    enum VenueEnforcement {
        Preferred,
        Enforced
    }

    struct ExternalVenue {
        address venue;
        bool inbound;
        bool outbound;
    }

    event VenueEnforcementChanged(VenueEnforcement enforcement);
    event CanonicalPoolsChanged();
    event VenueStatusChanged(
        address indexed venue, bytes32 indexed poolId, bool inbound, bool allowed
    );
    event ExternalVenuesChanged();

    function venueEnforcement() external view returns (VenueEnforcement);
    function canonicalPools() external view returns (PoolKey[] memory);
    function venueAllowed(address venue, bytes32 poolId, bool inbound) external view returns (bool);
    function externalVenues()
        external
        view
        returns (bool inboundRestricted, bool outboundRestricted, ExternalVenue[] memory allowed);
}

/// @notice The only error a venue-gated token reverts with when a transfer is
///         refused because of venue policy.
error VenueNotAllowed(address venue, bytes32 poolId, bool inbound);
