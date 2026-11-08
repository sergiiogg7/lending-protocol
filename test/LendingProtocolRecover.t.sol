// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice `emergencyRecover` can only take the surplus: what the contract holds beyond the cash that backs deposits
///         (supplied minus borrowed). Tokens sent by mistake and donations are surplus; user funds never are.
contract LendingProtocolRecoverTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public usdc; // 6 decimals, 1 USD
    MockToken public weth; // 18 decimals, 2000 USD
    MockToken public stray; // a token with no market

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public lender = makeAddr("lender");
    address public alice = makeAddr("alice");
    address public mallory = makeAddr("mallory");

    function setUp() public {
        oracle = new MockPriceOracle();
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        stray = new MockToken("Stray", "STR", 18, 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 2000e8);

        vm.startPrank(owner);
        lending = new LendingProtocol(address(oracle));
        lending.addMarket(address(usdc), 8000, 8500);
        lending.addMarket(address(weth), 7500, 8000);
        vm.stopPrank();

        usdc.mint(lender, 1000e6);
        vm.startPrank(lender);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(usdc), 1000e6);
        vm.stopPrank();

        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(lending), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), 10 ether);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- user funds are protected

    function test_NothingIsRecoverableWhileEverythingBelongsToDepositors() public {
        assertEq(lending.getRecoverableAmount(address(usdc)), 0);
        assertEq(lending.getRecoverableAmount(address(weth)), 0);

        vm.prank(owner);
        vm.expectRevert(LendingProtocol.AmountExceedsSurplus.selector);
        lending.emergencyRecover(address(usdc), treasury, 1);
    }

    function test_RevertWhen_RecoveringTheCashBackingDeposits() public {
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.AmountExceedsSurplus.selector);
        lending.emergencyRecover(address(usdc), treasury, 1000e6); // all of the lender's deposit

        vm.prank(owner);
        vm.expectRevert(LendingProtocol.AmountExceedsSurplus.selector);
        lending.emergencyRecover(address(weth), treasury, 10 ether); // all of Alice's collateral
    }

    function test_BorrowedFundsAndInterestDoNotCreateSurplus() public {
        vm.prank(alice);
        lending.borrow(address(usdc), 800e6);
        assertEq(lending.getRecoverableAmount(address(usdc)), 0); // 200 held, 200 available

        skip(365 days); // 32 USDC of interest are owed, but not held yet
        assertEq(lending.getRecoverableAmount(address(usdc)), 0);

        usdc.mint(alice, 32e6);
        vm.prank(alice);
        lending.repay(address(usdc), type(uint256).max);
        assertEq(lending.getRecoverableAmount(address(usdc)), 0); // 1032 held, 1032 owed to the lender
    }

    // ---------------------------------------------------------------- the surplus can be recovered

    function test_RecoverTokensOfAMarketThatWereSentDirectly() public {
        usdc.mint(address(lending), 50e6); // a donation or a transfer by mistake
        assertEq(lending.getRecoverableAmount(address(usdc)), 50e6);

        vm.prank(owner);
        lending.emergencyRecover(address(usdc), treasury, 50e6);

        assertEq(usdc.balanceOf(treasury), 50e6);
        assertEq(lending.getRecoverableAmount(address(usdc)), 0);

        vm.prank(owner);
        vm.expectRevert(LendingProtocol.AmountExceedsSurplus.selector);
        lending.emergencyRecover(address(usdc), treasury, 1);
    }

    function test_RecoverTokensWithoutAMarket() public {
        stray.mint(address(lending), 100 ether);
        assertEq(lending.getRecoverableAmount(address(stray)), 100 ether);

        vm.prank(owner);
        lending.emergencyRecover(address(stray), treasury, 100 ether);
        assertEq(stray.balanceOf(treasury), 100 ether);
    }

    function test_DepositorsStillExitAfterTheSurplusIsRecovered() public {
        usdc.mint(address(lending), 50e6);
        vm.prank(owner);
        lending.emergencyRecover(address(usdc), treasury, 50e6);

        vm.prank(lender);
        lending.withdraw(address(usdc), type(uint256).max);
        assertEq(usdc.balanceOf(lender), 1000e6);
    }

    // ---------------------------------------------------------------- access and inputs

    function test_RevertWhen_CallerIsNotTheOwner() public {
        stray.mint(address(lending), 1 ether);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        lending.emergencyRecover(address(stray), mallory, 1 ether);
    }

    function test_RevertWhen_RecipientIsTheZeroAddress() public {
        stray.mint(address(lending), 1 ether);
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.ZeroAddress.selector);
        lending.emergencyRecover(address(stray), address(0), 1 ether);
    }

    // ---------------------------------------------------------------- fuzz: recovering never breaks an exit

    function testFuzz_RecoveringTheSurplusNeverBlocksAnExit(uint256 borrowed, uint256 donated, uint256 elapsed) public {
        borrowed = bound(borrowed, 1e6, 1000e6);
        donated = bound(donated, 0, 500e6);
        elapsed = bound(elapsed, 1 days, 3 * 365 days);

        vm.prank(alice);
        lending.borrow(address(usdc), borrowed);
        usdc.mint(address(lending), donated);
        skip(elapsed);

        uint256 surplus = lending.getRecoverableAmount(address(usdc));
        assertGe(surplus, donated);
        vm.prank(owner);
        lending.emergencyRecover(address(usdc), treasury, surplus);

        // Alice repays everything and the lender can still take out capital plus interest
        uint256 debt = lending.getUserBorrow(alice, address(usdc));
        usdc.mint(alice, debt - borrowed);
        vm.prank(alice);
        lending.repay(address(usdc), type(uint256).max);

        vm.prank(lender);
        lending.withdraw(address(usdc), type(uint256).max);
        assertGe(usdc.balanceOf(lender), 1000e6);
    }
}
