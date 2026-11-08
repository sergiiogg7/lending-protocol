// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @dev Unit tests for flows not covered by `LendingProtocol.t.sol`: signed deposits, multi-step borrowing,
///      liquidation, pause behaviour and two-step ownership.
contract LendingProtocolFlowsTest is Test {
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event EmergencyRecovered(address indexed token, address indexed to, uint256 amount);

    LendingProtocol internal lending;
    MockToken internal usdc;
    MockToken internal weth;

    address internal owner = makeAddr("owner");
    address internal lp = makeAddr("lp");
    address internal liquidator = makeAddr("liquidator");
    uint256 internal signerKey = 0xA11CE;
    address internal signer;

    uint256 internal constant AMOUNT = 100 ether;

    function setUp() public {
        signer = vm.addr(signerKey);
        MockPriceOracle oracle = new MockPriceOracle();
        vm.prank(owner);
        lending = new LendingProtocol(address(oracle));
        usdc = new MockToken("USD Coin", "USDC", 18, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 1e8);

        vm.startPrank(owner);
        lending.addMarket(address(usdc), 8000, 500, 800);
        lending.addMarket(address(weth), 8000, 500, 800);
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

    function _sign(uint256 key, address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (LendingProtocol.SignatureData memory)
    {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked("deposit", token, amount, nonce, deadline))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return LendingProtocol.SignatureData({nonce: nonce, deadline: deadline, signature: abi.encodePacked(r, s, v)});
    }

    // ---------------------------------------------------------------- signed deposit

    function test_DepositWithSignature() public {
        LendingProtocol.SignatureData memory sig = _sign(signerKey, address(usdc), AMOUNT, 0, block.timestamp + 1 hours);

        vm.expectEmit(true, true, false, true);
        emit Deposit(signer, address(usdc), AMOUNT);
        vm.prank(signer);
        lending.depositWithSignature(address(usdc), AMOUNT, sig);

        assertEq(lending.getUserDeposit(signer, address(usdc)), AMOUNT);
        assertEq(lending.getNonce(signer), 1);
    }

    function test_RevertWhen_DepositWithSignatureReplayed() public {
        LendingProtocol.SignatureData memory sig = _sign(signerKey, address(usdc), AMOUNT, 0, block.timestamp + 1 hours);
        vm.startPrank(signer);
        lending.depositWithSignature(address(usdc), AMOUNT, sig);
        vm.expectRevert(LendingProtocol.InvalidNonce.selector);
        lending.depositWithSignature(address(usdc), AMOUNT, sig);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositWithSignatureZeroAmount() public {
        LendingProtocol.SignatureData memory sig = _sign(signerKey, address(usdc), 0, 0, block.timestamp + 1 hours);
        vm.prank(signer);
        vm.expectRevert(LendingProtocol.ZeroAmount.selector);
        lending.depositWithSignature(address(usdc), 0, sig);
    }

    // ---------------------------------------------------------------- borrow / withdraw / liquidate

    function test_SecondBorrowIsCheckedAgainstExistingDebt() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 40 ether);
        lending.borrow(address(weth), 20 ether);
        vm.stopPrank();

        assertEq(lending.getUserBorrow(signer, address(weth)), 60 ether);
        assertEq(lending.getUser(signer).totalBorrowed, 60 ether);
    }

    function test_RevertWhen_SecondBorrowExceedsCollateral() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 60 ether);
        vm.expectRevert(LendingProtocol.BorrowExceedsCollateral.selector);
        lending.borrow(address(weth), 50 ether);
        vm.stopPrank();
    }

    function test_WithdrawEverythingDeactivatesUser() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.withdraw(address(usdc), AMOUNT);
        vm.stopPrank();

        assertFalse(lending.getUser(signer).isActive);
        assertEq(usdc.balanceOf(signer), 1000 ether);
    }

    function test_RepayEverythingDeactivatesUser() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 10 ether);
        lending.repay(address(weth), 10 ether);
        vm.stopPrank();

        assertEq(lending.getUserBorrow(signer, address(weth)), 0);
        assertFalse(lending.getUser(signer).isActive);
    }

    function test_Liquidate() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 50 ether);
        vm.stopPrank();

        vm.prank(owner);
        lending.updateMarket(address(usdc), 3000, 500, 800); // collateral value 30 < debt 50 * 80%
        assertTrue(lending.isLiquidatable(signer));

        vm.prank(liquidator);
        lending.liquidate(signer, address(weth), 10 ether);

        assertEq(lending.getUserBorrow(signer, address(weth)), 40 ether);
        assertEq(lending.getUserDeposit(signer, address(usdc)), AMOUNT - 10.5 ether);
        assertEq(usdc.balanceOf(liquidator), 1000 ether + 10.5 ether);
    }

    function test_RevertWhen_LiquidateWithoutCollateral() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 50 ether);
        vm.stopPrank();

        // collateral factor 0 -> the deposit has no value, so findBestCollateral returns address(0)
        vm.prank(owner);
        lending.updateMarket(address(usdc), 0, 500, 800);

        vm.prank(liquidator);
        vm.expectRevert(LendingProtocol.NoCollateralToSeize.selector);
        lending.liquidate(signer, address(weth), 1 ether);
    }

    function test_RevertWhen_LiquidateInsufficientCollateral() public {
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.deposit(address(weth), AMOUNT);
        lending.borrow(address(weth), 128 ether);
        vm.stopPrank();

        vm.startPrank(owner);
        lending.updateMarket(address(usdc), 5000, 500, 800);
        lending.updateMarket(address(weth), 5000, 500, 800);
        vm.stopPrank();

        // best collateral is usdc (first of two equal values) and holds 100, but 100 * 105% = 105 must be seized
        vm.prank(liquidator);
        vm.expectRevert(LendingProtocol.InsufficientCollateral.selector);
        lending.liquidate(signer, address(weth), AMOUNT);
    }

    function test_CanBorrowAndCanWithdrawViews() public {
        assertTrue(lending.canBorrow(signer, address(weth), 1 ether)); // no debt yet
        vm.startPrank(signer);
        lending.deposit(address(usdc), AMOUNT);
        lending.borrow(address(weth), 50 ether);
        vm.stopPrank();

        assertTrue(lending.canBorrow(signer, address(weth), 10 ether));
        assertFalse(lending.canBorrow(signer, address(weth), 100 ether));
        assertTrue(lending.canWithdraw(signer, address(usdc), 10 ether));
        assertFalse(lending.canWithdraw(signer, address(usdc), AMOUNT));
        assertEq(lending.getCollateralizationRatio(signer), 16_000);
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
        lending.addMarket(address(usdc), 8000, 0, 0);
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
