// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "../test/mocks/MockToken.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";

/// @dev Local-only deploy for manual testing on Anvil (run it with Anvil's account #0 key).
///      Deploys a mock price oracle (every token at 1 USD), the protocol, two mock tokens (USDC, WETH, 18 decimals) with active markets, and gives each of
///      Anvil's accounts #1 to #3 some tokens.
contract LocalDeploy is Script {
    uint256 constant TOKENS_PER_ACCOUNT = 100_000 ether;
    uint256 constant LTV = 7500;
    uint256 constant LIQUIDATION_THRESHOLD = 8000;

    function run() external {
        address[3] memory users = [
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906
        ];

        vm.startBroadcast();
        MockPriceOracle oracle = new MockPriceOracle();
        LendingProtocol lending = new LendingProtocol(address(oracle));
        MockToken usdc = new MockToken("USD Coin", "USDC", 18, 0);
        MockToken weth = new MockToken("Wrapped Ether", "WETH", 18, 0);

        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 1e8);

        lending.addMarket(address(usdc), LTV, LIQUIDATION_THRESHOLD);
        lending.addMarket(address(weth), LTV, LIQUIDATION_THRESHOLD);

        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], TOKENS_PER_ACCOUNT);
            weth.mint(users[i], TOKENS_PER_ACCOUNT);
        }
        vm.stopBroadcast();

        console.log("LendingProtocol:", address(lending));
        console.log("Oracle:", address(oracle));
        console.log("USDC:", address(usdc));
        console.log("WETH:", address(weth));
    }
}
