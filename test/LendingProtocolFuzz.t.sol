// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @dev Fuzz tests of the accounting and of the health checks.
contract LendingProtocolFuzzTest is Test {
    LendingProtocol internal lending;
    MockToken internal usdc;
    MockToken internal weth;

    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal user = makeAddr("user");

    uint256 internal constant MAX = 1_000_000 ether;

    function setUp() public {
        MockPriceOracle oracle = new MockPriceOracle();
        vm.prank(owner);
        lending = new LendingProtocol(address(oracle));
        usdc = new MockToken("USD Coin", "USDC", 18, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 1e8);
        vm.startPrank(owner);
        lending.addMarket(address(usdc), 7500, 8000);
        lending.addMarket(address(weth), 7500, 8000);
        vm.stopPrank();

        address[2] memory actors = [lp, user];
        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 2 * MAX);
            weth.mint(actors[i], 2 * MAX);
            vm.startPrank(actors[i]);
            usdc.approve(address(lending), type(uint256).max);
            weth.approve(address(lending), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lp);
        lending.deposit(address(weth), MAX);
    }

    function testFuzz_DepositWithdrawRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, MAX);
        vm.startPrank(user);
        lending.deposit(address(usdc), amount);
        assertEq(lending.getUserDeposit(user, address(usdc)), amount);
        lending.withdraw(address(usdc), amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), 2 * MAX);
        assertEq(lending.getUserDeposit(user, address(usdc)), 0);
        assertEq(lending.getMarket(address(usdc)).totalSupply, 0);
        assertFalse(lending.getUser(user).isActive);
    }

    function testFuzz_BorrowRepayRoundTrip(uint256 collateral, uint256 borrowAmount) public {
        collateral = bound(collateral, 1 ether, MAX);
        borrowAmount = bound(borrowAmount, 1, (collateral * 7000) / 10_000); // below the 75 % LTV
        vm.startPrank(user);
        lending.deposit(address(usdc), collateral);
        lending.borrow(address(weth), borrowAmount);
        lending.repay(address(weth), borrowAmount);
        vm.stopPrank();

        assertEq(lending.getUserBorrow(user, address(weth)), 0);
        assertEq(lending.getMarket(address(weth)).totalBorrow, 0);
        assertEq(weth.balanceOf(user), 2 * MAX);
    }

    function testFuzz_BorrowNeverLeavesPositionLiquidatable(uint256 collateral, uint256 borrowAmount) public {
        collateral = bound(collateral, 1 ether, MAX);
        borrowAmount = bound(borrowAmount, 1, MAX);
        vm.startPrank(user);
        lending.deposit(address(usdc), collateral);
        try lending.borrow(address(weth), borrowAmount) {
            assertFalse(lending.isLiquidatable(user));
        } catch {}
        vm.stopPrank();
    }

    function testFuzz_WithdrawNeverLeavesPositionLiquidatable(uint256 collateral, uint256 borrowAmount, uint256 out)
        public
    {
        collateral = bound(collateral, 1 ether, MAX);
        borrowAmount = bound(borrowAmount, 1, (collateral * 7000) / 10_000); // below the 75 % LTV
        out = bound(out, 1, collateral);
        vm.startPrank(user);
        lending.deposit(address(usdc), collateral);
        lending.borrow(address(weth), borrowAmount);
        try lending.withdraw(address(usdc), out) {
            assertFalse(lending.isLiquidatable(user));
        } catch {}
        vm.stopPrank();
    }

    function testFuzz_AddMarketRejectsThresholdAboveMax(uint256 factor) public {
        factor = bound(factor, 10_001, type(uint256).max);
        MockToken token = new MockToken("T", "T", 18, 0);
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.addMarket(address(token), 0, factor);
    }

    function testFuzz_RevertWhen_WithdrawMoreThanDeposited(uint256 deposited, uint256 extra) public {
        deposited = bound(deposited, 1, MAX);
        extra = bound(extra, 1, MAX);
        vm.startPrank(user);
        lending.deposit(address(usdc), deposited);
        vm.expectRevert(LendingProtocol.InsufficientDeposit.selector);
        lending.withdraw(address(usdc), deposited + extra);
        vm.stopPrank();
    }
}
