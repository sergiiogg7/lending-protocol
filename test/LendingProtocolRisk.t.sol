// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice Risk model: per-market `ltv` (what you can borrow) and `liquidationThreshold` (when you are liquidated),
///         and a health factor (1e18 scale) = sum(collateral usd * threshold) / sum(debt usd).
contract LendingProtocolRiskTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public usdc; // 6 decimals, 1 USD, LTV 80 %, threshold 85 %
    MockToken public weth; // 18 decimals, 2000 USD, LTV 75 %, threshold 80 %

    address public owner = makeAddr("owner");
    address public lender = makeAddr("lender");
    address public borrower = makeAddr("borrower");
    address public attacker = makeAddr("attacker");

    uint256 constant WAD = 1e18;

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

        // Liquidity provided by the lender in both markets
        usdc.mint(lender, 100_000e6);
        weth.mint(lender, 100 ether);
        vm.startPrank(lender);
        usdc.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        lending.deposit(address(usdc), 100_000e6);
        lending.deposit(address(weth), 100 ether);
        vm.stopPrank();

        // The borrower holds 1 WETH as collateral
        weth.mint(borrower, 1 ether);
        vm.startPrank(borrower);
        weth.approve(address(lending), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), 1 ether);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- market parameters

    function test_RevertWhen_LtvAboveLiquidationThreshold() public {
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.updateMarket(address(weth), 8100, 8000, 0, 0);
    }

    function test_RevertWhen_ThresholdAboveOneHundredPercent() public {
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.updateMarket(address(weth), 7500, 10_001, 0, 0);
    }

    // ---------------------------------------------------------------- bug #1: the first borrow must be checked

    function test_RevertWhen_BorrowWithoutCollateral() public {
        vm.prank(attacker);
        vm.expectRevert(LendingProtocol.BorrowExceedsCollateral.selector);
        lending.borrow(address(usdc), 1000e6);
    }

    function test_RevertWhen_BorrowDustWithoutCollateral() public {
        // 1 wei of WETH is worth less than one USD unit; debt is rounded up, so it still counts.
        vm.prank(attacker);
        vm.expectRevert(LendingProtocol.BorrowExceedsCollateral.selector);
        lending.borrow(address(weth), 1);
    }

    // ---------------------------------------------------------------- LTV caps new borrows

    function test_BorrowUpToLtvAndNoFurther() public {
        // borrowing power = 1 WETH * 2000 USD * 75 % = 1500 USD
        vm.startPrank(borrower);
        lending.borrow(address(usdc), 1500e6);
        vm.expectRevert(LendingProtocol.BorrowExceedsCollateral.selector);
        lending.borrow(address(usdc), 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- health factor

    function test_HealthFactorIsMaxWithoutDebt() public view {
        assertEq(lending.getHealthFactor(borrower), type(uint256).max);
    }

    function test_HealthFactor() public {
        vm.prank(borrower);
        lending.borrow(address(usdc), 1500e6);

        // (2000 USD * 80 % threshold) / 1500 USD = 1.0666...
        assertEq(lending.getHealthFactor(borrower), 1_066_666_666_666_666_666);
        assertFalse(lending.isLiquidatable(borrower));
    }

    function test_HealthFactorOfExactlyOneIsNotLiquidatable() public {
        vm.prank(borrower);
        lending.borrow(address(usdc), 1500e6);

        // price 1875: 1875 * 80 % = 1500 = debt => HF is exactly 1
        oracle.setPrice(address(weth), 1875e8);
        assertEq(lending.getHealthFactor(borrower), WAD);
        assertFalse(lending.isLiquidatable(borrower));

        // one dollar less and HF < 1
        oracle.setPrice(address(weth), 1874e8);
        assertLt(lending.getHealthFactor(borrower), WAD);
        assertTrue(lending.isLiquidatable(borrower));
    }

    function test_AboveLtvButStillHealthy() public {
        vm.prank(borrower);
        lending.borrow(address(usdc), 1500e6);

        // price 1900: borrowing power 1425 < debt 1500 (no more borrowing), but HF = 1520 / 1500 > 1
        oracle.setPrice(address(weth), 1900e8);
        assertFalse(lending.isLiquidatable(borrower));
        vm.prank(borrower);
        vm.expectRevert(LendingProtocol.BorrowExceedsCollateral.selector);
        lending.borrow(address(usdc), 1);
    }

    // ---------------------------------------------------------------- withdrawals use the liquidation threshold

    function test_WithdrawUpToHealthFactorOne() public {
        vm.startPrank(borrower);
        lending.borrow(address(usdc), 1000e6);

        // 1000 USD of debt needs 1000 / 80 % = 1250 USD of collateral = 0.625 WETH, so 0.375 WETH can leave
        lending.withdraw(address(weth), 0.375 ether);
        assertEq(lending.getHealthFactor(borrower), WAD);

        vm.expectRevert(LendingProtocol.WithdrawalUnsafe.selector);
        lending.withdraw(address(weth), 1);
        vm.stopPrank();
    }

    function test_RevertWhen_WithdrawWithDebtAndNoCollateralLeft() public {
        vm.startPrank(borrower);
        lending.borrow(address(usdc), 1000e6);
        vm.expectRevert(LendingProtocol.WithdrawalUnsafe.selector);
        lending.withdraw(address(weth), 1 ether);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- end-to-end scenario (phases 2 to 4)

    /// @notice Lucia deposits 2 ETH (2000 USD, LTV 75 %, threshold 80 %) and borrows 2500 USDC; then ETH falls to 1500.
    function test_LuciaScenario() public {
        address lucia = makeAddr("lucia");
        weth.mint(lucia, 2 ether);
        vm.startPrank(lucia);
        weth.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), 2 ether);

        // Phase 2: borrowing power is 4000 * 75 % = 3000 USD; she borrows 2500, within the LTV
        assertTrue(lending.canBorrow(lucia, address(usdc), 3000e6));
        assertFalse(lending.canBorrow(lucia, address(usdc), 3000e6 + 1));
        lending.borrow(address(usdc), 2500e6);
        vm.stopPrank();

        // Phase 3: HF = 4000 * 80 % / 2500 = 1.28
        assertEq(lending.getHealthFactor(lucia), 1.28 ether);
        assertFalse(lending.isLiquidatable(lucia));

        // Phase 4: ETH falls to 1500; HF = 3000 * 80 % / 2500 = 0.96. Her loan-to-value is 83 %, above the 75 % limit,
        // and now the liquidation threshold has been crossed too
        oracle.setPrice(address(weth), 1500e8);
        assertEq(lending.getHealthFactor(lucia), 0.96 ether);
        assertTrue(lending.isLiquidatable(lucia));
    }
}
