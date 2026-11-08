// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice How the protocol uses its price oracle. The risk model itself is tested in `LendingProtocolRisk.t.sol`.
contract LendingProtocolOracleTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public weth;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        oracle.setPrice(address(weth), 2000e8);

        vm.startPrank(owner);
        lending = new LendingProtocol(address(oracle));
        lending.addMarket(address(weth), 7500, 8000);
        vm.stopPrank();

        weth.mint(user, 1 ether);
        vm.startPrank(user);
        weth.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_OracleIsSetInConstructor() public view {
        assertEq(address(lending.oracle()), address(oracle));
    }

    function test_RevertWhen_OracleIsZeroAddress() public {
        vm.expectRevert(LendingProtocol.ZeroAddress.selector);
        new LendingProtocol(address(0));
    }

    function test_RevertWhen_TokenInPositionHasNoPrice() public {
        MockToken dai = new MockToken("Dai", "DAI", 18, 0); // listed as a market but the oracle has no price for it
        vm.prank(owner);
        lending.addMarket(address(dai), 7500, 8000);
        dai.mint(user, 1 ether);

        vm.startPrank(user);
        dai.approve(address(lending), type(uint256).max);
        lending.deposit(address(dai), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(MockPriceOracle.PriceNotSet.selector, address(dai)));
        lending.getHealthFactor(user);
        vm.stopPrank();
    }

    function test_PositionWithoutAssetInMarketDoesNotNeedItsPrice() public {
        MockToken dai = new MockToken("Dai", "DAI", 18, 0);
        vm.prank(owner);
        lending.addMarket(address(dai), 7500, 8000);

        // the user holds no DAI, so the missing DAI price is never queried
        assertEq(lending.getHealthFactor(user), type(uint256).max);
    }
}
