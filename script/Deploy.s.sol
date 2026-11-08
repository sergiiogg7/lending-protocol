// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";

/// @notice Deploys `LendingProtocol`. Reads `PRIVATE_KEY`, `ORACLE` (price oracle address) and the optional `OWNER`
///         from the environment.
/// @dev If `OWNER` is set, ownership is only offered (two-step): `OWNER` must call `acceptOwnership()` afterwards.
///      Markets are added by the owner after deployment with `addMarket`.
contract Deploy is Script {
    function run() external returns (LendingProtocol lending) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address oracle = vm.envAddress("ORACLE");
        address newOwner = vm.envOr("OWNER", address(0));

        vm.startBroadcast(deployerKey);
        lending = new LendingProtocol(oracle);
        if (newOwner != address(0)) {
            lending.transferOwnership(newOwner);
        }
        vm.stopBroadcast();

        console.log("LendingProtocol:", address(lending));
        if (newOwner != address(0)) {
            console.log("Ownership offered to (must call acceptOwnership):", newOwner);
        }
    }
}
