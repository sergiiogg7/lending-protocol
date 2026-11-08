// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @dev Unit tests for flows not covered by `LendingProtocol.t.sol`: multi-step borrowing,
///      liquidation, pause behaviour and two-step ownership.
contract LendingProtocolFlowsTest is Test {
    event EmergencyRecovered(address indexed token, address indexed to, uint256 amount);

    LendingProtocol internal lending;
    MockToken internal usdc;
    MockToken internal weth;
    MockPriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal liquidator = makeAddr("liquidator");
    address internal signer;

    uint256 internal constant AMOUNT = 100 ether;

    function setUp() public {
        signer = makeAddr("signer");
        oracle = new MockPriceOracle();
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

        address[3] memory actors = [signer, lp, liquidator];
        for (uint256 i = 0; i < actors.length; i++) {
            usdc.mint(actors[i], 1000 ether);
            weth.mint(actors[i], 1000 ether);
            vm.startPrank(actors[i]);
            usdc.approve(address(lending), type(uint256).max);
            weth.approve(address(lending), type(uint256).max);
            vm.stopPrank();
        }

        vm.prank(lp);
        lending.deposit(address(weth), 500 ether);
    }

    // ---------------------------------------------------------------- borrow / withdraw / liquidate

    function test_SecondBorrowIsCheckedAgainstExistingDebt() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 40 ether);
        lending.borrow(address(weth), 20 ether);
        vm.stopPrank();

        assertEq(lending.getUserBorrow(signer, address(weth)), 60 ether);
    }

    function test_RevertWhen_SecondBorrowExceedsCollateral() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 60 ether);
        vm.expectRevert(LendingProtocol.BorrowExceedsCollateral.selector);
        lending.borrow(address(weth), 50 ether);
        vm.stopPrank();
    }

    function test_WithdrawEverythingReturnsTheDeposit() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.withdraw(address(usdc), AMOUNT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(signer), 1000 ether);
    }

    function test_Liquidate() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 50 ether);
        vm.stopPrank();

        oracle.setPrice(address(usdc), 0.5e8); // collateral counted 100 * 0.5 * 80 % = 40 < debt 50
        assertTrue(lending.isLiquidatable(signer));

        vm.prank(liquidator);
        lending.liquidate(address(usdc), address(weth), signer, 10 ether);

        assertEq(lending.getUserBorrow(signer, address(weth)), 40 ether);
        // 10 WETH repaid * 1.05 / 0.5 = 21 USDC seized
        assertEq(lending.getUserDeposit(signer, address(usdc)), AMOUNT - 21 ether);
        assertEq(usdc.balanceOf(liquidator), 1000 ether + 21 ether);
    }

    function test_RevertWhen_LiquidateCollateralTokenNotDeposited() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 50 ether);
        vm.stopPrank();

        // a falling USDC price makes the position liquidatable; the signer holds no WETH to seize
        oracle.setPrice(address(usdc), 0.1e8);

        vm.prank(liquidator);
        vm.expectRevert(LendingProtocol.InsufficientCollateral.selector);
        lending.liquidate(address(weth), address(weth), signer, 1 ether);
    }

    function test_RevertWhen_LiquidateInsufficientCollateral() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.deposit(address(weth), AMOUNT);
        lending.borrow(address(weth), 128 ether);
        vm.stopPrank();

        // USDC at 0.5: (100 * 0.5 + 100) * 80 % = 120 < 128 of debt, health factor 0.94
        oracle.setPrice(address(usdc), 0.5e8);

        // repaying 100 requires seizing 100 * 1.05 / 0.5 = 210 USDC, but the signer only holds 100
        vm.prank(liquidator);
        vm.expectRevert(LendingProtocol.InsufficientCollateral.selector);
        lending.liquidate(address(usdc), address(weth), signer, AMOUNT);
    }

    function test_CanBorrowAndCanWithdrawViews() public {
        assertFalse(lending.canBorrow(signer, address(weth), 1 ether)); // no collateral yet
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 50 ether);
        vm.stopPrank();

        assertTrue(lending.canBorrow(signer, address(weth), 10 ether));
        assertFalse(lending.canBorrow(signer, address(weth), 100 ether));
        assertTrue(lending.canWithdraw(signer, address(usdc), 10 ether));
        assertFalse(lending.canWithdraw(signer, address(usdc), AMOUNT));
        assertEq(lending.getHealthFactor(signer), 1.6 ether); // 100 * 80% / 50
    }

    // ---------------------------------------------------------------- pause

    function test_PausedBlocksEntryPoints() public {
        vm.prank(owner);
        lending.pause();

        vm.startPrank(signer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lending.deposit(address(usdc), AMOUNT);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lending.borrow(address(weth), 1);
        vm.stopPrank();
    }

    function test_ExitPathsWorkWhilePaused() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 10 ether);
        vm.stopPrank();

        vm.prank(owner);
        lending.pause();

        vm.startPrank(signer);
        lending.repay(address(weth), 10 ether);
        lending.withdraw(address(usdc), AMOUNT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(signer), 1000 ether);
    }

    function test_RevertWhen_NonOwnerPauses() public {
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, signer));
        lending.pause();
    }

    // ---------------------------------------------------------------- ownership and recovery

    function test_OwnershipTransferIsTwoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        lending.transferOwnership(newOwner);
        assertEq(lending.owner(), owner);
        assertEq(lending.pendingOwner(), newOwner);

        vm.prank(newOwner);
        lending.acceptOwnership();
        assertEq(lending.owner(), newOwner);
    }

    function test_RevertWhen_NonPendingOwnerAccepts() public {
        vm.prank(owner);
        lending.transferOwnership(makeAddr("newOwner"));
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, signer));
        lending.acceptOwnership();
    }

    function test_RevertWhen_NonOwnerAddsMarket() public {
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, signer));
        lending.addMarket(address(usdc), 7500, 8000);
    }

    function test_EmergencyRecoverEmitsEvent() public {
        usdc.mint(address(lending), 5 ether);
        vm.expectEmit(true, true, false, true);
        emit EmergencyRecovered(address(usdc), owner, 5 ether);
        vm.prank(owner);
        lending.emergencyRecover(address(usdc), owner, 5 ether);
    }

    function test_RevertWhen_NonOwnerRecovers() public {
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, signer));
        lending.emergencyRecover(address(usdc), signer, 1);
    }
}
