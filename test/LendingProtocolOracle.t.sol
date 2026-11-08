// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice Values of tokens with different prices and decimals must be comparable (USD, 8 decimals).
contract LendingProtocolOracleTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public usdc; // 6 decimals, 1 USD
    MockToken public weth; // 18 decimals, 2000 USD

    address public owner = makeAddr("owner");
    address public lender = makeAddr("lender");
    address public borrower = makeAddr("borrower");

    uint256 constant COLLATERAL_FACTOR = 8000;

    function setUp() public {
        oracle = new MockPriceOracle();
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2000e8);

        vm.startPrank(owner);
        lending = new LendingProtocol(address(oracle));
        lending.addMarket(address(usdc), COLLATERAL_FACTOR, 0, 0);
        lending.addMarket(address(weth), COLLATERAL_FACTOR, 0, 0);
        vm.stopPrank();

        usdc.mint(lender, 5000e6);
        weth.mint(borrower, 1 ether);

        vm.startPrank(lender);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(usdc), 5000e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        weth.approve(address(lending), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), 1 ether);
        vm.stopPrank();
    }

    function test_RatioComparesValuesInUsdAcrossDecimals() public {
        vm.prank(borrower);
        lending.borrow(address(usdc), 1000e6);

        // collateral: 1 WETH * 2000 USD * 80% = 1600 USD; debt: 1000 USD => 16000 bps
        assertEq(lending.getCollateralizationRatio(borrower), 16_000);
    }

    function test_BorrowLimitIsExpressedInUsd() public {
        vm.startPrank(borrower);
        lending.borrow(address(usdc), 1000e6); // first borrow (skips the check, known bug #1)
        lending.borrow(address(usdc), 1000e6); // 2000 USD of debt: ratio exactly at 80%
        vm.expectRevert(LendingProtocol.BorrowExceedsCollateral.selector);
        lending.borrow(address(usdc), 1); // anything above the limit
        vm.stopPrank();
    }
}
