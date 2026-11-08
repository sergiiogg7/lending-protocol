// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice Liquidation, modelled on Aave: the liquidator repays part of the debt (close factor) and receives collateral
///         worth the repaid debt plus a 5 % bonus, valued with the oracle.
/// @dev Scenario: Lucia deposits 2 ETH (2000 USD, LTV 75 %, threshold 80 %) and borrows 2500 USDC.
contract LendingProtocolLiquidationTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public usdc; // 6 decimals, 1 USD, LTV 80 %, threshold 85 %
    MockToken public weth; // 18 decimals, 2000 USD, LTV 75 %, threshold 80 %

    address public owner = makeAddr("owner");
    address public lender = makeAddr("lender");
    address public lucia = makeAddr("lucia");
    address public carlos = makeAddr("carlos"); // the liquidator
    address public bob = makeAddr("bob");

    event Liquidate(
        address indexed liquidator,
        address indexed user,
        address indexed collateralToken,
        address debtToken,
        uint256 debtCovered,
        uint256 collateralSeized
    );

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

        // USDC liquidity
        usdc.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(usdc), 100_000e6);
        vm.stopPrank();

        // Lucia: 2 ETH of collateral, 2500 USDC of debt
        weth.mint(lucia, 2 ether);
        vm.startPrank(lucia);
        weth.approve(address(lending), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), 2 ether);
        lending.borrow(address(usdc), 2500e6);
        vm.stopPrank();

        // Carlos holds enough USDC to liquidate the whole debt
        usdc.mint(carlos, 2500e6);
        vm.prank(carlos);
        usdc.approve(address(lending), type(uint256).max);
    }

    // ---------------------------------------------------------------- the scenario (phases 5 and 6)

    function test_LiquidateHalfOfTheDebt() public {
        oracle.setPrice(address(weth), 1500e8); // HF = 3000 * 80 % / 2500 = 0.96

        vm.expectEmit(true, true, true, true);
        emit Liquidate(carlos, lucia, address(weth), address(usdc), 1250e6, 0.875 ether);
        vm.prank(carlos);
        lending.liquidate(address(weth), address(usdc), lucia, 1250e6);

        // Carlos pays 1250 USDC and receives 1250 * 1.05 / 1500 = 0.875 ETH (1312.5 USD: a 62.5 USD profit)
        assertEq(usdc.balanceOf(carlos), 1250e6);
        assertEq(weth.balanceOf(carlos), 0.875 ether);

        // Lucia: debt 2500 -> 1250 USDC, collateral 2 -> 1.125 ETH, health factor 0.96 -> 1.08
        assertEq(lending.getUserBorrow(lucia, address(usdc)), 1250e6);
        assertEq(lending.getUserDeposit(lucia, address(weth)), 1.125 ether);
        assertEq(lending.getHealthFactor(lucia), 1.08 ether);
        assertFalse(lending.isLiquidatable(lucia));

        // Market totals follow
        assertEq(lending.getMarket(address(usdc)).totalBorrow, 1250e6);
        assertEq(lending.getMarket(address(weth)).totalSupply, 1.125 ether);
    }

    // ---------------------------------------------------------------- close factor

    function test_CloseFactorCapsTheAmountAtHalfOfTheDebt() public {
        oracle.setPrice(address(weth), 1500e8); // HF 0.96, above 0.95: at most 50 %

        vm.prank(carlos);
        lending.liquidate(address(weth), address(usdc), lucia, 2500e6); // asks for everything

        assertEq(usdc.balanceOf(carlos), 1250e6); // only 1250 were taken
        assertEq(lending.getUserBorrow(lucia, address(usdc)), 1250e6);
    }

    function test_WholeDebtCanBeLiquidatedBelowHealthFactor095() public {
        oracle.setPrice(address(weth), 1400e8); // HF = 2800 * 80 % / 2500 = 0.896

        vm.prank(carlos);
        lending.liquidate(address(weth), address(usdc), lucia, 2500e6);

        // seized = 2500 * 1.05 / 1400 = 1.875 ETH
        assertEq(usdc.balanceOf(carlos), 0);
        assertEq(weth.balanceOf(carlos), 1.875 ether);
        assertEq(lending.getUserBorrow(lucia, address(usdc)), 0);
        assertEq(lending.getUserDeposit(lucia, address(weth)), 0.125 ether);
    }

    // ---------------------------------------------------------------- who can be liquidated

    function test_RevertWhen_PositionIsHealthy() public {
        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.NotLiquidatable.selector);
        lending.liquidate(address(weth), address(usdc), lucia, 1000e6);
    }

    function test_RevertWhen_HealthFactorIsExactlyOne() public {
        oracle.setPrice(address(weth), 1562.5e8); // 2 ETH * 1562.5 * 80 % = 2500 = debt: HF exactly 1
        assertEq(lending.getHealthFactor(lucia), 1 ether);

        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.NotLiquidatable.selector);
        lending.liquidate(address(weth), address(usdc), lucia, 1000e6);
    }

    function test_RevertWhen_UserHasNoDebtInThatToken() public {
        oracle.setPrice(address(weth), 1500e8);

        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.NoDebtToLiquidate.selector);
        lending.liquidate(address(usdc), address(weth), lucia, 1 ether); // Lucia owes USDC, not WETH
    }

    function test_RevertWhen_AmountIsZero() public {
        oracle.setPrice(address(weth), 1500e8);

        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.ZeroAmount.selector);
        lending.liquidate(address(weth), address(usdc), lucia, 0);
    }

    // ---------------------------------------------------------------- the liquidator needs enough collateral and liquidity

    function test_RevertWhen_CollateralDoesNotCoverTheBonus() public {
        oracle.setPrice(address(weth), 1000e8); // collateral 2000 USD < debt 2500 USD: bad debt zone

        // 2500 * 1.05 / 1000 = 2.625 ETH, but Lucia only has 2
        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.InsufficientCollateral.selector);
        lending.liquidate(address(weth), address(usdc), lucia, 2500e6);

        // a smaller amount works: 1900 * 1.05 / 1000 = 1.995 ETH
        vm.prank(carlos);
        lending.liquidate(address(weth), address(usdc), lucia, 1900e6);
        assertEq(weth.balanceOf(carlos), 1.995 ether);
    }

    function test_RevertWhen_MarketLacksLiquidityToPayTheCollateral() public {
        // Bob borrows 1.5 of the 2 ETH in the market, leaving only 0.5 ETH of free liquidity
        usdc.mint(bob, 10_000e6);
        vm.startPrank(bob);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(usdc), 10_000e6);
        lending.borrow(address(weth), 1.5 ether);
        vm.stopPrank();

        oracle.setPrice(address(weth), 1500e8);

        // Carlos would receive 0.875 ETH, but the contract only has 0.5 ETH available
        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.InsufficientLiquidity.selector);
        lending.liquidate(address(weth), address(usdc), lucia, 1250e6);
    }

    // ---------------------------------------------------------------- the bonus must not break the protocol

    function test_RevertWhen_ThresholdTimesBonusExceedsOneHundredPercent() public {
        // 95.23 % * 1.05 = 99.99 % is accepted, 95.24 % * 1.05 = 100.002 % is not
        vm.startPrank(owner);
        lending.updateMarket(address(weth), 7500, 9523);
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.updateMarket(address(weth), 7500, 9524);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- fuzz: liquidating helps the position

    /// @dev The health factor improves when it is at least `threshold * (1 + bonus)` = 0.84; below that the position
    ///      is so underwater that each liquidation lowers it, as in Aave.
    function testFuzz_LiquidationImprovesHealthFactor(uint256 price, uint256 cover) public {
        price = bound(price, 1313e8, 1562e8); // health factor between 0.8403 and 0.9997
        oracle.setPrice(address(weth), price);
        uint256 before_ = lending.getHealthFactor(lucia);
        assertLt(before_, 1 ether);

        cover = bound(cover, 1e6, 2500e6);
        vm.prank(carlos);
        lending.liquidate(address(weth), address(usdc), lucia, cover);

        assertGe(lending.getHealthFactor(lucia), before_);
    }
}
