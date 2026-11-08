// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice Interest rate model. Utilization = borrowed / supplied. The borrow rate follows a curve with a kink at 80 %
///         (base 0 %, slope1 4 %, slope2 75 %) and the supply rate is borrowRate * utilization (no reserve factor).
///         Rates are annual and scaled by 1e18 (0.04e18 = 4 %).
contract LendingProtocolRatesTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public usdc; // 6 decimals
    MockToken public weth; // 18 decimals

    address public owner = makeAddr("owner");
    address public lender = makeAddr("lender");
    address public borrower = makeAddr("borrower");

    function setUp() public {
        oracle = new MockPriceOracle();
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2000e8);

        vm.startPrank(owner);
        lending = new LendingProtocol(address(oracle));
        lending.addMarket(address(usdc), 8000, 8500);
        lending.addMarket(address(weth), 7500, 8000);
        vm.stopPrank();

        // 1000 USDC supplied
        usdc.mint(lender, 1000e6);
        vm.startPrank(lender);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(usdc), 1000e6);
        vm.stopPrank();

        // the borrower has 10 WETH (20 000 USD) of collateral
        weth.mint(borrower, 10 ether);
        vm.startPrank(borrower);
        weth.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), 10 ether);
        vm.stopPrank();
    }

    function _borrow(uint256 usdcAmount) internal {
        vm.prank(borrower);
        lending.borrow(address(usdc), usdcAmount);
    }

    // ---------------------------------------------------------------- utilization

    function test_UtilizationIsBorrowedOverSupplied() public {
        assertEq(lending.getUtilization(address(usdc)), 0);
        _borrow(400e6);
        assertEq(lending.getUtilization(address(usdc)), 0.4e18);
        _borrow(500e6);
        assertEq(lending.getUtilization(address(usdc)), 0.9e18);
        _borrow(100e6);
        assertEq(lending.getUtilization(address(usdc)), 1e18);
    }

    function test_AMarketWithoutDepositsHasNoUtilizationNorRates() public {
        MockToken dai = new MockToken("Dai", "DAI", 18, 0);
        vm.prank(owner);
        lending.addMarket(address(dai), 7500, 8000);

        assertEq(lending.getUtilization(address(dai)), 0);
        assertEq(lending.getBorrowRate(address(dai)), 0);
        assertEq(lending.getSupplyRate(address(dai)), 0);
    }

    // ---------------------------------------------------------------- borrow rate: a curve with a kink

    function test_BorrowRateIsZeroWithoutBorrows() public view {
        assertEq(lending.getBorrowRate(address(usdc)), 0);
    }

    function test_BorrowRateGrowsLinearlyBelowTheKink() public {
        _borrow(400e6); // U = 40 %: 4 % * 40 / 80 = 2 %
        assertEq(lending.getBorrowRate(address(usdc)), 0.02e18);
        _borrow(400e6); // U = 80 %: exactly the kink, 4 %
        assertEq(lending.getBorrowRate(address(usdc)), 0.04e18);
    }

    function test_BorrowRateJumpsAboveTheKink() public {
        _borrow(900e6); // U = 90 %: 4 % + 75 % * (90 - 80) / (100 - 80) = 41.5 %
        assertEq(lending.getBorrowRate(address(usdc)), 0.415e18);
        _borrow(100e6); // U = 100 %: 4 % + 75 % = 79 %
        assertEq(lending.getBorrowRate(address(usdc)), 0.79e18);
    }

    // ---------------------------------------------------------------- supply rate

    function test_SupplyRateIsBorrowRateTimesUtilization() public {
        assertEq(lending.getSupplyRate(address(usdc)), 0);

        _borrow(400e6); // 2 % * 40 %
        assertEq(lending.getSupplyRate(address(usdc)), 0.008e18);
        _borrow(400e6); // 4 % * 80 %: borrowers pay 32 USDC a year, shared by the 1000 supplied
        assertEq(lending.getSupplyRate(address(usdc)), 0.032e18);
        _borrow(100e6); // 41.5 % * 90 %
        assertEq(lending.getSupplyRate(address(usdc)), 0.3735e18);
    }

    // ---------------------------------------------------------------- properties

    function testFuzz_SupplyRateNeverExceedsBorrowRate(uint256 amount) public {
        amount = bound(amount, 1, 1000e6);
        _borrow(amount);
        assertLe(lending.getSupplyRate(address(usdc)), lending.getBorrowRate(address(usdc)));
    }

    function testFuzz_BorrowRateNeverFallsWhenBorrowingMore(uint256 first, uint256 second) public {
        first = bound(first, 1, 1000e6);
        second = bound(second, 0, 1000e6 - first);
        _borrow(first);
        uint256 rateBefore = lending.getBorrowRate(address(usdc));
        if (second > 0) _borrow(second);
        assertGe(lending.getBorrowRate(address(usdc)), rateBefore);
    }

    function testFuzz_UtilizationNeverExceedsOneHundredPercent(uint256 amount) public {
        amount = bound(amount, 1, 1000e6);
        _borrow(amount);
        assertLe(lending.getUtilization(address(usdc)), 1e18);
    }
}
