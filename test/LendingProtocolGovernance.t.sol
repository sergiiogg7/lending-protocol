// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice Owner powers over the risk parameters of a market.
///         - `ltv` only limits NEW borrows, so it can change instantly (lowering it is the emergency lever).
///         - Raising the liquidation threshold only makes positions safer, so it is instant too.
///         - LOWERING the liquidation threshold can make existing positions liquidatable, so it needs a 2-day notice.
contract LendingProtocolGovernanceTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public usdc; // 6 decimals, 1 USD
    MockToken public weth; // 18 decimals, 2000 USD: ltv 75 %, liquidation threshold 80 %

    address public owner = makeAddr("owner");
    address public lender = makeAddr("lender");
    address public alice = makeAddr("alice");
    address public mallory = makeAddr("mallory");

    event MarketUpdated(address indexed token, uint256 ltv, uint256 liquidationThreshold);
    event LiquidationThresholdDecreaseProposed(address indexed token, uint256 newThreshold, uint256 executableAt);
    event LiquidationThresholdDecreaseCancelled(address indexed token);

    uint256 constant DELAY = 2 days;

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

        // a deep USDC market, so that the interest of a couple of days is negligible
        usdc.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(usdc), 100_000e6);
        vm.stopPrank();

        // Alice: 1 WETH (2000 USD) of collateral and 1500 USDC borrowed, the maximum for a 75 % LTV
        weth.mint(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(lending), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), 1 ether);
        lending.borrow(address(usdc), 1500e6);
        vm.stopPrank();

        // The owner lowers the LTV to 65 %: Alice is now above it (debt 1500, borrowing power 1300) but still healthy
        // (health factor 1.07), because liquidation depends on the threshold, not on the LTV
        vm.prank(owner);
        lending.setLtv(address(weth), 6500);
    }

    // ---------------------------------------------------------------- ltv: instant, only affects new borrows

    function test_LoweringTheLtvBlocksNewBorrowsButNeverLiquidatesAnyone() public {
        uint256 healthFactorBefore = lending.getHealthFactor(alice);

        vm.expectEmit(true, false, false, true);
        emit MarketUpdated(address(weth), 0, 8000);
        vm.prank(owner);
        lending.setLtv(address(weth), 0); // the emergency lever: stop new borrowing against WETH

        assertEq(lending.getHealthFactor(alice), healthFactorBefore); // nothing changes for existing positions
        assertFalse(lending.isLiquidatable(alice));
        assertEq(lending.getMarket(address(weth)).ltv, 0);

        vm.prank(alice);
        vm.expectRevert(LendingProtocol.BorrowExceedsCollateral.selector);
        lending.borrow(address(usdc), 1e6);
    }

    function test_RevertWhen_LtvIsAboveTheLiquidationThreshold() public {
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.setLtv(address(weth), 8001);
    }

    // ---------------------------------------------------------------- raising the threshold: instant

    function test_RaisingTheLiquidationThresholdIsInstant() public {
        vm.expectEmit(true, false, false, true);
        emit MarketUpdated(address(weth), 6500, 9000);
        vm.prank(owner);
        lending.raiseLiquidationThreshold(address(weth), 9000);

        assertEq(lending.getMarket(address(weth)).liquidationThreshold, 9000);
        // 2000 * 90 % / 1500
        assertEq(lending.getHealthFactor(alice), 1.2 ether);
    }

    function test_RevertWhen_RaisingToOrAboveTheMaximum() public {
        vm.startPrank(owner);
        lending.raiseLiquidationThreshold(address(weth), 9523); // the highest allowed with a 5 % liquidation bonus
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.raiseLiquidationThreshold(address(weth), 9524);
        vm.stopPrank();
    }

    function test_RevertWhen_RaisingToALowerValue() public {
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.raiseLiquidationThreshold(address(weth), 7900);
    }

    // ---------------------------------------------------------------- lowering the threshold: two days of notice

    function test_ProposingADecreaseChangesNothingYet() public {
        vm.expectEmit(true, false, false, true);
        emit LiquidationThresholdDecreaseProposed(address(weth), 7000, block.timestamp + DELAY);
        vm.prank(owner);
        lending.proposeLiquidationThresholdDecrease(address(weth), 7000);

        (uint256 threshold, uint256 executableAt) = lending.getPendingLiquidationThreshold(address(weth));
        assertEq(threshold, 7000);
        assertEq(executableAt, block.timestamp + DELAY);

        assertEq(lending.getMarket(address(weth)).liquidationThreshold, 8000);
        assertFalse(lending.isLiquidatable(alice));
    }

    function test_RevertWhen_ExecutingBeforeTheDelay() public {
        vm.prank(owner);
        lending.proposeLiquidationThresholdDecrease(address(weth), 7000);

        skip(DELAY - 1);
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.ChangeNotReady.selector);
        lending.executeLiquidationThresholdDecrease(address(weth));
    }

    function test_ExecutingAfterTheDelayMakesTheRiskyPositionLiquidatable() public {
        vm.prank(owner);
        lending.proposeLiquidationThresholdDecrease(address(weth), 7000);
        skip(DELAY);

        vm.expectEmit(true, false, false, true);
        emit MarketUpdated(address(weth), 6500, 7000);
        vm.prank(owner);
        lending.executeLiquidationThresholdDecrease(address(weth));

        // 2000 * 70 % = 1400 < 1500 of debt
        assertEq(lending.getMarket(address(weth)).liquidationThreshold, 7000);
        assertTrue(lending.isLiquidatable(alice));

        (uint256 threshold, uint256 executableAt) = lending.getPendingLiquidationThreshold(address(weth));
        assertEq(threshold, 0);
        assertEq(executableAt, 0);
    }

    function test_BorrowersUseTheNoticeToRepayAndStaySafe() public {
        vm.prank(owner);
        lending.proposeLiquidationThresholdDecrease(address(weth), 7000);
        skip(DELAY);

        // during the two days Alice repays enough: 1400 USD of collateral counted must cover the debt
        vm.prank(alice);
        lending.repay(address(usdc), 500e6);

        vm.prank(owner);
        lending.executeLiquidationThresholdDecrease(address(weth));
        assertFalse(lending.isLiquidatable(alice));
    }

    function test_CancelRemovesThePendingChange() public {
        vm.startPrank(owner);
        lending.proposeLiquidationThresholdDecrease(address(weth), 7000);

        vm.expectEmit(true, false, false, true);
        emit LiquidationThresholdDecreaseCancelled(address(weth));
        lending.cancelLiquidationThresholdDecrease(address(weth));

        skip(DELAY);
        vm.expectRevert(LendingProtocol.NoPendingChange.selector);
        lending.executeLiquidationThresholdDecrease(address(weth));
        vm.expectRevert(LendingProtocol.NoPendingChange.selector);
        lending.cancelLiquidationThresholdDecrease(address(weth));
        vm.stopPrank();
    }

    function test_ProposingAgainReplacesThePendingChangeAndRestartsTheClock() public {
        vm.startPrank(owner);
        lending.proposeLiquidationThresholdDecrease(address(weth), 7000);
        skip(DELAY - 1);
        lending.proposeLiquidationThresholdDecrease(address(weth), 7600);

        skip(1); // the first proposal would be ready now, the second is not
        vm.expectRevert(LendingProtocol.ChangeNotReady.selector);
        lending.executeLiquidationThresholdDecrease(address(weth));

        skip(DELAY);
        lending.executeLiquidationThresholdDecrease(address(weth));
        vm.stopPrank();

        assertEq(lending.getMarket(address(weth)).liquidationThreshold, 7600);
    }

    function test_RevertWhen_ProposingAnInvalidDecrease() public {
        vm.startPrank(owner);
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.proposeLiquidationThresholdDecrease(address(weth), 8000); // not lower than the current one
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.proposeLiquidationThresholdDecrease(address(weth), 6400); // below the LTV of 6500
        vm.stopPrank();
    }

    function test_RevertWhen_TheLtvWasRaisedAboveThePendingThreshold() public {
        vm.startPrank(owner);
        lending.proposeLiquidationThresholdDecrease(address(weth), 7600);
        lending.setLtv(address(weth), 7700); // allowed now: the threshold is still 8000
        skip(DELAY);

        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lending.executeLiquidationThresholdDecrease(address(weth)); // 7600 would fall below the new LTV
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- access

    function test_RevertWhen_CallerIsNotTheOwner() public {
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory);
        vm.startPrank(mallory);
        vm.expectRevert(notOwner);
        lending.setLtv(address(weth), 0);
        vm.expectRevert(notOwner);
        lending.raiseLiquidationThreshold(address(weth), 9000);
        vm.expectRevert(notOwner);
        lending.proposeLiquidationThresholdDecrease(address(weth), 7000);
        vm.expectRevert(notOwner);
        lending.executeLiquidationThresholdDecrease(address(weth));
        vm.expectRevert(notOwner);
        lending.cancelLiquidationThresholdDecrease(address(weth));
        vm.stopPrank();
    }

    function test_RevertWhen_TheMarketDoesNotExist() public {
        MockToken dai = new MockToken("Dai", "DAI", 18, 0);
        vm.startPrank(owner);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector);
        lending.setLtv(address(dai), 0);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector);
        lending.raiseLiquidationThreshold(address(dai), 9000);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector);
        lending.proposeLiquidationThresholdDecrease(address(dai), 7000);
        vm.stopPrank();
    }
}
