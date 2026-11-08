// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @notice Health checks loop over every market, so the number of markets is capped to keep the gas of
///         `borrow`, `withdraw` and `liquidate` bounded.
contract LendingProtocolMarketsTest is Test {
    LendingProtocol public lending;
    MockPriceOracle public oracle;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    MockToken[] internal tokens;

    function setUp() public {
        oracle = new MockPriceOracle();
        vm.prank(owner);
        lending = new LendingProtocol(address(oracle));
    }

    function _listMarkets(uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            MockToken token = new MockToken("Token", "TKN", 18, 0);
            oracle.setPrice(address(token), 1e8);
            vm.prank(owner);
            lending.addMarket(address(token), 7500, 8000);
            tokens.push(token);
        }
    }

    function test_TheCapIsSixteenMarkets() public view {
        assertEq(lending.MAX_MARKETS(), 16);
    }

    function test_ListsMarketsUpToTheCap() public {
        _listMarkets(16);
        assertEq(lending.getSupportedTokens().length, 16);
    }

    function test_RevertWhen_ExceedingTheCap() public {
        _listMarkets(16);

        MockToken extra = new MockToken("Extra", "EXT", 18, 0);
        oracle.setPrice(address(extra), 1e8);
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.TooManyMarkets.selector);
        lending.addMarket(address(extra), 7500, 8000);
    }

    /// @notice The worst case for gas: a position with a deposit and a debt in every market.
    function test_BorrowStaysCheapWithAPositionInEveryMarket() public {
        _listMarkets(16);

        // a lender provides liquidity in every market, Alice deposits in every market and borrows in 15 of them
        address lender = makeAddr("lender");
        for (uint256 i = 0; i < 16; i++) {
            tokens[i].mint(lender, 1000 ether);
            tokens[i].mint(alice, 1000 ether);
            vm.startPrank(lender);
            tokens[i].approve(address(lending), type(uint256).max);
            lending.deposit(address(tokens[i]), 1000 ether);
            vm.stopPrank();
            vm.startPrank(alice);
            tokens[i].approve(address(lending), type(uint256).max);
            lending.deposit(address(tokens[i]), 100 ether);
            if (i < 15) lending.borrow(address(tokens[i]), 1 ether);
            vm.stopPrank();
        }

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        lending.borrow(address(tokens[15]), 1 ether);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("gas of a borrow with 16 markets in the position", gasUsed);
        assertLt(gasUsed, 400_000); // measured: about 207 000
        assertGt(lending.getHealthFactor(alice), 1 ether);
    }
}
