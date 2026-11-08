// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockFeeToken} from "./mocks/MockFeeToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice Which tokens can be listed, and what happens with tokens that deliver less than what is sent.
///         The protocol credits what it asked for, so a token that charges a fee on transfer would leave it
///         owing more than it holds: such transfers revert. Rebasing tokens cannot be detected and are not supported.
contract LendingProtocolTokensTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;
    MockToken public weth;
    MockFeeToken public feeToken;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public carlos = makeAddr("carlos");

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        feeToken = new MockFeeToken("Fee Token", "FEE", 0); // starts without a fee
        oracle.setPrice(address(weth), 2000e8);
        oracle.setPrice(address(feeToken), 1e8);

        vm.startPrank(owner);
        lending = new LendingProtocol(address(oracle));
        lending.addMarket(address(weth), 7500, 8000);
        lending.addMarket(address(feeToken), 7500, 8000);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- what can be listed

    function test_RevertWhen_TheTokenIsNotAContract() public {
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.InvalidToken.selector);
        lending.addMarket(makeAddr("an account"), 7500, 8000);
    }

    function test_RevertWhen_TheContractIsNotAnERC20() public {
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.InvalidToken.selector);
        lending.addMarket(address(oracle), 7500, 8000); // a contract without decimals()
    }

    function test_RevertWhen_TheTokenHasMoreThan18Decimals() public {
        MockToken odd = new MockToken("Odd", "ODD", 19, 0);
        oracle.setPrice(address(odd), 1e8);

        vm.prank(owner);
        vm.expectRevert(LendingProtocol.InvalidToken.selector);
        lending.addMarket(address(odd), 7500, 8000);
    }

    function test_AcceptsTokensWithUpTo18Decimals() public {
        MockToken usdt = new MockToken("Tether", "USDT", 6, 0);
        MockToken max = new MockToken("Max", "MAX", 18, 0);
        oracle.setPrice(address(usdt), 1e8);
        oracle.setPrice(address(max), 1e8);

        vm.startPrank(owner);
        lending.addMarket(address(usdt), 7500, 8000);
        lending.addMarket(address(max), 7500, 8000);
        vm.stopPrank();
    }

    function test_RevertWhen_TheOracleHasNoPriceForTheToken() public {
        MockToken unpriced = new MockToken("Unpriced", "UNP", 18, 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MockPriceOracle.PriceNotSet.selector, address(unpriced)));
        lending.addMarket(address(unpriced), 7500, 8000);
    }

    // ---------------------------------------------------------------- tokens that charge a fee on transfer

    function test_RevertWhen_DepositingATokenThatChargesAFee() public {
        feeToken.mint(alice, 100 ether);
        feeToken.setFee(100); // 1 % of every transfer is burnt

        vm.startPrank(alice);
        feeToken.approve(address(lending), type(uint256).max);
        vm.expectRevert(LendingProtocol.UnsupportedToken.selector);
        lending.deposit(address(feeToken), 100 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_RepayingATokenThatStartsChargingAFee() public {
        feeToken.mint(alice, 100 ether);
        weth.mint(alice, 1 ether);
        vm.startPrank(alice);
        feeToken.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        lending.deposit(address(feeToken), 100 ether);
        lending.deposit(address(weth), 1 ether);
        lending.borrow(address(feeToken), 50 ether);

        feeToken.setFee(100);
        vm.expectRevert(LendingProtocol.UnsupportedToken.selector);
        lending.repay(address(feeToken), 50 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_LiquidatingWithATokenThatStartsChargingAFee() public {
        address lender = makeAddr("lender");
        feeToken.mint(lender, 100 ether);
        vm.startPrank(lender);
        feeToken.approve(address(lending), type(uint256).max);
        lending.deposit(address(feeToken), 100 ether);
        vm.stopPrank();

        weth.mint(alice, 1 ether);
        vm.startPrank(alice);
        weth.approve(address(lending), type(uint256).max);
        lending.deposit(address(weth), 1 ether);
        lending.borrow(address(feeToken), 90 ether); // 90 USD against 2000 USD of collateral
        vm.stopPrank();

        oracle.setPrice(address(weth), 50e8); // the collateral collapses: 50 * 80 % = 40 < 90 of debt
        feeToken.mint(carlos, 100 ether);
        vm.prank(carlos);
        feeToken.approve(address(lending), type(uint256).max);
        feeToken.setFee(100);

        vm.prank(carlos);
        vm.expectRevert(LendingProtocol.UnsupportedToken.selector);
        lending.liquidate(address(weth), address(feeToken), alice, 10 ether);
    }

    function test_ATokenWithoutFeeKeepsWorkingNormally() public {
        feeToken.mint(alice, 100 ether);
        vm.startPrank(alice);
        feeToken.approve(address(lending), type(uint256).max);
        lending.deposit(address(feeToken), 100 ether);
        vm.stopPrank();

        assertEq(lending.getUserDeposit(alice, address(feeToken)), 100 ether);
    }
}
