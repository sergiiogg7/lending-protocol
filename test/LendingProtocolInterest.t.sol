// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice Interest accrual with indexes. Balances are stored scaled (amount / index) and read as scaled * index, so a
///         single index per market grows interest for every user at once. Rates come from the utilization (curve with
///         a kink at 80 %: 4 % at the kink) and the supply rate is borrowRate * utilization.
contract LendingProtocolInterestTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public usdc; // 6 decimals, 1 USD
    MockToken public weth; // 18 decimals, 2000 USD

    address public owner = makeAddr("owner");
    address public lender = makeAddr("lender");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public carlos = makeAddr("carlos"); // liquidator

    uint256 constant YEAR = 365 days;

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

        // 1000 USDC supplied by the lender
        usdc.mint(lender, 1000e6);
        vm.startPrank(lender);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(usdc), 1000e6);
        vm.stopPrank();

        // Alice and Bob have 10 WETH (20 000 USD) of collateral each; Carol only 0.5 WETH (1000 USD)
        _fundCollateral(alice, 10 ether);
        _fundCollateral(bob, 10 ether);
        _fundCollateral(carol, 0.5 ether);

        usdc.mint(carlos, 1000e6);
        vm.prank(carlos);
        usdc.approve(address(lending), type(uint256).max);
    }

    function _fundCollateral(address user, uint256 amount) internal {
        weth.mint(user, amount);
        vm.startPrank(user);
        weth.approve(address(lending), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), amount);
        vm.stopPrank();
    }

    function _borrow(address user, uint256 amount) internal {
        vm.prank(user);
        lending.borrow(address(usdc), amount);
    }

    // ---------------------------------------------------------------- indexes

    function test_IndexesStartAtOne() public view {
        LendingProtocol.Market memory market = lending.getMarket(address(usdc));
        assertEq(market.liquidityIndex, 1e18);
        assertEq(market.borrowIndex, 1e18);
    }

    function test_NoTimeNoInterest() public {
        _borrow(alice, 800e6);

        assertEq(lending.getUserBorrow(alice, address(usdc)), 800e6);
        assertEq(lending.getUserDeposit(lender, address(usdc)), 1000e6);
        assertEq(lending.getMarket(address(usdc)).borrowIndex, 1e18);
    }

    function test_NoBorrowsNoInterest() public {
        skip(YEAR);
        assertEq(lending.getUserDeposit(lender, address(usdc)), 1000e6);
    }

    // ---------------------------------------------------------------- one year of interest

    function test_BorrowerOwesInterestAfterOneYear() public {
        _borrow(alice, 800e6); // U = 80 %: borrow rate 4 %, supply rate 3.2 %
        skip(YEAR);

        assertEq(lending.getUserBorrow(alice, address(usdc)), 832e6); // 800 * 1.04
        assertEq(lending.getUserDeposit(lender, address(usdc)), 1032e6); // 1000 * 1.032
    }

    function test_InterestPaidEqualsInterestEarned() public {
        _borrow(alice, 800e6);
        skip(YEAR);

        uint256 paid = lending.getUserBorrow(alice, address(usdc)) - 800e6;
        uint256 earned = lending.getUserDeposit(lender, address(usdc)) - 1000e6;
        assertEq(paid, 32e6);
        assertEq(earned, paid);
    }

    function test_MarketTotalsAndLiquidityFollowTheInterest() public {
        _borrow(alice, 800e6);
        skip(YEAR);

        LendingProtocol.Market memory market = lending.getMarket(address(usdc));
        assertEq(market.totalBorrow, 832e6);
        assertEq(market.totalSupply, 1032e6);
        // the cash in the contract is the same: interest is only owed until the borrower repays
        assertEq(lending.getAvailableLiquidity(address(usdc)), 200e6);
        assertEq(usdc.balanceOf(address(lending)), 200e6);
    }

    // ---------------------------------------------------------------- one index, many users

    function test_EachBorrowerPaysOnlyForTheirOwnTime() public {
        _borrow(alice, 400e6); // U = 40 %: 2 %
        skip(YEAR);
        _borrow(bob, 400e6); // Alice has accrued one year: 400 * 1.02

        assertEq(lending.getUserBorrow(alice, address(usdc)), 408e6);
        assertApproxEqAbs(lending.getUserBorrow(bob, address(usdc)), 400e6, 1);

        uint256 rate = lending.getBorrowRate(address(usdc)); // rate that applies from now on
        skip(YEAR);

        assertApproxEqAbs(lending.getUserBorrow(alice, address(usdc)), (408e6 * (1e18 + rate)) / 1e18, 2);
        assertApproxEqAbs(lending.getUserBorrow(bob, address(usdc)), (400e6 * (1e18 + rate)) / 1e18, 2);
    }

    function test_InterestCompoundsOnEveryInteraction() public {
        _borrow(alice, 400e6); // 2 %
        skip(YEAR);
        usdc.mint(lender, 10);
        vm.prank(lender);
        lending.deposit(address(usdc), 10); // any interaction updates the index and the rate
        skip(YEAR);

        // two years at 2 % without compounding would be 416; updating in between gives a bit more
        assertGt(lending.getUserBorrow(alice, address(usdc)), 416e6);
        assertLt(lending.getUserBorrow(alice, address(usdc)), 417e6);
    }

    // ---------------------------------------------------------------- repay and withdraw everything

    function test_RepayAndWithdrawEverything() public {
        _borrow(alice, 800e6);
        skip(YEAR);

        usdc.mint(alice, 32e6); // the interest she has to pay on top of what she borrowed
        vm.prank(alice);
        lending.repay(address(usdc), type(uint256).max);

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(lending.getUserBorrow(alice, address(usdc)), 0);
        assertEq(lending.getMarket(address(usdc)).totalBorrow, 0);

        vm.prank(lender);
        lending.withdraw(address(usdc), type(uint256).max);

        assertEq(usdc.balanceOf(lender), 1032e6); // capital plus interest
        assertEq(usdc.balanceOf(address(lending)), 0); // nothing left over, nothing missing
    }

    // ---------------------------------------------------------------- the health factor sees the interest

    function test_PositionBecomesLiquidatableJustByTime() public {
        _borrow(carol, 750e6); // collateral counted by the health factor: 1000 * 80 % = 800; U = 75 %: 3.75 %

        skip(YEAR);
        assertFalse(lending.isLiquidatable(carol)); // debt 778.1 < 800

        skip(YEAR);
        assertTrue(lending.isLiquidatable(carol)); // debt 806.25 > 800, with the ETH price unchanged
    }

    function test_LiquidationRepaysAccruedDebt() public {
        _borrow(carol, 750e6);
        skip(2 * YEAR); // debt 806.25 USDC, health factor 0.992: the close factor is 50 %

        vm.prank(carlos);
        lending.liquidate(address(weth), address(usdc), carol, 1000e6);

        assertEq(usdc.balanceOf(carlos), 1000e6 - 403_125_000); // half of the accrued debt, not of the 750 borrowed
        assertApproxEqAbs(lending.getUserBorrow(carol, address(usdc)), 403_125_000, 1);
    }

    // ---------------------------------------------------------------- fuzz: the market stays solvent

    function testFuzz_EveryoneCanExitAfterTheBorrowersRepay(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1e6, 1000e6);
        elapsed = bound(elapsed, 1 days, 5 * YEAR);

        _borrow(alice, amount);
        skip(elapsed);

        uint256 debt = lending.getUserBorrow(alice, address(usdc));
        usdc.mint(alice, debt - amount); // she only needs the interest on top of what she borrowed
        vm.prank(alice);
        lending.repay(address(usdc), type(uint256).max);
        assertEq(lending.getUserBorrow(alice, address(usdc)), 0);

        // the interest she paid is the interest the lender earned (a few wei of rounding at most)
        uint256 earned = lending.getUserDeposit(lender, address(usdc)) - 1000e6;
        assertApproxEqAbs(debt - amount, earned, 3);

        // and the contract holds enough to pay the lender everything
        assertGe(usdc.balanceOf(address(lending)) + 3, lending.getUserDeposit(lender, address(usdc)));
        vm.prank(lender);
        lending.withdraw(address(usdc), type(uint256).max);
        assertGe(usdc.balanceOf(lender), 1000e6);
    }
}
