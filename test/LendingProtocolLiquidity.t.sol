// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice Available liquidity = supplied - borrowed. Borrowing and withdrawing are limited by it.
contract LendingProtocolLiquidityTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public usdc; // 6 decimals, 1 USD
    MockToken public weth; // 18 decimals, 2000 USD

    address public owner = makeAddr("owner");
    address public lender = makeAddr("lender");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        oracle = new MockPriceOracle();
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2000e8);

        vm.startPrank(owner);
        lending = new LendingProtocol(address(oracle));
        lending.addMarket(address(usdc), 8000, 8500, 0, 0);
        lending.addMarket(address(weth), 7500, 8000, 0, 0);
        vm.stopPrank();

        // The market has 1000 USDC; Alice borrows 800 of them, so 200 are left
        usdc.mint(lender, 1000e6);
        vm.startPrank(lender);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(usdc), 1000e6);
        vm.stopPrank();

        address[2] memory borrowers = [alice, bob];
        for (uint256 i = 0; i < borrowers.length; i++) {
            weth.mint(borrowers[i], 10 ether);
            vm.startPrank(borrowers[i]);
            weth.approve(address(lending), type(uint256).max);
            usdc.approve(address(lending), type(uint256).max);
            lending.deposit(address(weth), 10 ether);
            vm.stopPrank();
        }

        vm.prank(alice);
        lending.borrow(address(usdc), 800e6);
    }

    function test_AvailableLiquidityIsSupplyMinusBorrows() public view {
        assertEq(lending.getAvailableLiquidity(address(usdc)), 200e6);
        assertEq(lending.getAvailableLiquidity(address(weth)), 20 ether);
    }

    // ---------------------------------------------------------------- borrow

    function test_BorrowUpToTheAvailableLiquidityAndNoFurther() public {
        vm.startPrank(bob);
        vm.expectRevert(LendingProtocol.InsufficientLiquidity.selector);
        lending.borrow(address(usdc), 200e6 + 1); // bob has plenty of collateral, the market has no cash

        lending.borrow(address(usdc), 200e6);
        assertEq(lending.getAvailableLiquidity(address(usdc)), 0);

        vm.expectRevert(LendingProtocol.InsufficientLiquidity.selector);
        lending.borrow(address(usdc), 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- withdraw

    function test_RevertWhen_WithdrawingCashThatIsLentOut() public {
        // the lender has 1000 USDC deposited, but 800 are lent to Alice
        vm.startPrank(lender);
        vm.expectRevert(LendingProtocol.InsufficientLiquidity.selector);
        lending.withdraw(address(usdc), 201e6);

        lending.withdraw(address(usdc), 200e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(lender), 200e6);
    }

    function test_LenderCanExitOnceTheBorrowerRepays() public {
        vm.prank(alice);
        lending.repay(address(usdc), 800e6);

        vm.prank(lender);
        lending.withdraw(address(usdc), 1000e6);
        assertEq(usdc.balanceOf(lender), 1000e6);
    }

    // ---------------------------------------------------------------- borrowing the token you deposited

    /// @notice Allowed on purpose, as in Aave: the deposit counts as collateral for any borrow.
    function test_CanBorrowTheSameTokenThatIsDeposited() public {
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        lending.deposit(address(usdc), 1000e6);
        lending.borrow(address(usdc), 200e6); // within the liquidity of the market
        vm.stopPrank();

        assertEq(lending.getUserBorrow(bob, address(usdc)), 200e6);
        assertFalse(lending.isLiquidatable(bob));
    }
}
