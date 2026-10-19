// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {ExampleERC20S} from "../src/ExampleERC20S.sol";
import {VenueGateHook} from "../src/VenueGateHook.sol";

/// @title VenueGate
/// @notice Deploys the URC-5 template: the example token, then the hook at a
///         CREATE2-mined address, then `setHook`. Listing the canonical pool and
///         initializing it are owner steps afterwards, since the pool key depends
///         on the pair you choose.
/// @dev forge script script/VenueGate.s.sol --rpc-url $RPC --sender $DEPLOYER [--broadcast].
///      Env: POOL_MANAGER (required), NAME, SYMBOL, SUPPLY (default 1e27), OWNER (default sender).
contract VenueGate is Script {
    /// @dev Arachnid CREATE2 proxy; forge routes salted creations through it when broadcasting.
    address internal constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address owner = vm.envOr("OWNER", sender);

        ExampleERC20S token = new ExampleERC20S(
            vm.envOr("NAME", string("ERC20S")),
            vm.envOr("SYMBOL", string("ERC20S")),
            vm.envOr("SUPPLY", uint256(1e27)),
            address(poolManager),
            sender
        );
        (address hookAddr, bytes32 salt) = mineHookSalt(
            CREATE2_PROXY, type(VenueGateHook).creationCode, abi.encode(poolManager, token)
        );
        VenueGateHook hook = new VenueGateHook{salt: salt}(poolManager, token);
        require(address(hook) == hookAddr, "hook landed off the mined address");
        token.setHook(address(hook), true);
        if (owner != sender) token.transferOwnership(owner);
        vm.stopBroadcast();

        console2.log("token", address(token));
        console2.log("hook", address(hook));
        console2.log("Next: setCanonicalPools([key]) from the owner, then initialize the pool");
    }

    function mineHookSalt(address deployer, bytes memory creationCode, bytes memory args)
        public
        view
        returns (address hookAddr, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, args));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        for (uint256 i = 0; i < 500_000; i++) {
            salt = bytes32(i);
            hookAddr = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))
                )
            );
            if (uint160(hookAddr) & Hooks.ALL_HOOK_MASK == flags && hookAddr.code.length == 0) {
                return (hookAddr, salt);
            }
        }
        revert("hook salt not found");
    }
}
