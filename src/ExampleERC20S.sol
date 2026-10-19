// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20S} from "./ERC20S.sol";

/// @notice The smallest complete ERC20S: fixed supply minted to the
///         owner at deployment. Replace with your own supply logic.
contract ExampleERC20S is ERC20S {
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply,
        address poolManager_,
        address initialOwner
    ) ERC20(name_, symbol_) ERC20S(poolManager_, initialOwner) {
        _mint(initialOwner, supply);
    }
}
