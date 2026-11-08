// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

/// @dev Drives the protocol with random user actions, time jumps and risk changes.
contract InvHandler is Test {
    LendingProtocol public lending;
    MockToken public usdc;
    MockToken public weth;
    MockPriceOracle public oracle;
    address[] public actors;

    constructor(
        LendingProtocol _lending,
        MockToken _usdc,
        MockToken _weth,
        MockPriceOracle _oracle,
        address[] memory _actors
    ) {
        lending = _lending;
        usdc = _usdc;
        weth = _weth;
        oracle = _oracle;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal view returns (MockToken) {
        return seed % 2 == 0 ? usdc : weth;
    }

    function deposit(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        vm.prank(_actor(actorSeed));
        try lending.deposit(address(_token(tokenSeed)), amount) {} catch {}
    }

    function withdraw(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        MockToken t = _token(tokenSeed);
        uint256 max = lending.getUserDeposit(a, address(t));
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        try lending.withdraw(address(t), amount) {} catch {}
    }

    function withdrawAll(uint256 actorSeed, uint256 tokenSeed) external {
        vm.prank(_actor(actorSeed));
        try lending.withdraw(address(_token(tokenSeed)), type(uint256).max) {} catch {}
    }

    function borrow(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        vm.prank(_actor(actorSeed));
        try lending.borrow(address(_token(tokenSeed)), amount) {} catch {}
    }

    function repay(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        MockToken t = _token(tokenSeed);
        uint256 max = lending.getUserBorrow(a, address(t));
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        try lending.repay(address(t), amount) {} catch {}
    }

    function repayAll(uint256 actorSeed, uint256 tokenSeed) external {
        vm.prank(_actor(actorSeed));
        try lending.repay(address(_token(tokenSeed)), type(uint256).max) {} catch {}
    }

    function liquidate(uint256 liquidatorSeed, uint256 userSeed, uint256 tokenSeed, uint256 amount) external {
        address liq = _actor(liquidatorSeed);
        address victim = _actor(userSeed);
        MockToken t = _token(tokenSeed);
        MockToken collateral = t == usdc ? weth : usdc;
        uint256 max = lending.getUserBorrow(victim, address(t));
        if (max == 0 || liq == victim) return;
        amount = bound(amount, 1, max);
        vm.prank(liq);
        try lending.liquidate(address(collateral), address(t), victim, amount) {} catch {}
    }

    /// @dev Lets interest accrue.
    function warp(uint256 secondsToSkip) external {
        skip(bound(secondsToSkip, 1, 90 days));
    }

    /// @dev Moves a price (between 20 % and 100 % of 1 USD) so that some positions become liquidatable.
    function movePrice(uint256 tokenSeed, uint256 priceBps) external {
        priceBps = bound(priceBps, 2000, 10_000);
        oracle.setPrice(address(_token(tokenSeed)), (1e8 * priceBps) / 10_000);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// @dev Invariants of the lending accounting, with interest accruing over time.
contract LendingProtocolInvariantTest is StdInvariant, Test {
    LendingProtocol internal lending;
    MockToken internal usdc;
    MockToken internal weth;
    InvHandler internal handler;
    address[] internal actors;

    /// @dev Rounding is always in favour of the protocol, so balances can differ from totals by a few wei per user.
    uint256 internal constant DUST = 8;

    function setUp() public {
        address owner = makeAddr("owner");
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

        for (uint256 i = 0; i < 4; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            usdc.mint(a, type(uint128).max);
            weth.mint(a, type(uint128).max);
            vm.startPrank(a);
            usdc.approve(address(lending), type(uint256).max);
            weth.approve(address(lending), type(uint256).max);
            vm.stopPrank();
        }

        handler = new InvHandler(lending, usdc, weth, oracle, actors);
        targetContract(address(handler));
    }

    function _sumDeposits(MockToken token) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += lending.getUserDeposit(actors[i], address(token));
        }
    }

    function _sumBorrows(MockToken token) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += lending.getUserBorrow(actors[i], address(token));
        }
    }

    function _checkMarketTotals(MockToken token) internal view {
        LendingProtocol.Market memory market = lending.getMarket(address(token));
        uint256 deposits = _sumDeposits(token);
        uint256 borrows = _sumBorrows(token);
        // each user balance is rounded down (deposits) or up (debts), so the sums stay within dust of the totals
        assertLe(deposits, market.totalSupply);
        assertGe(deposits + DUST, market.totalSupply);
        assertGe(borrows, market.totalBorrow);
        assertLe(borrows, market.totalBorrow + DUST);
    }

    /// @notice Market totals equal the sum of the user balances, interest included (up to rounding).
    function invariant_MarketTotalsMatchUserSums() public view {
        _checkMarketTotals(usdc);
        _checkMarketTotals(weth);
    }

    function _checkSolvency(MockToken token) internal view {
        LendingProtocol.Market memory market = lending.getMarket(address(token));
        if (market.totalSupply > market.totalBorrow) {
            // The cash held covers what is supplied and not lent out. The indexes have 27 decimals, so accruing
            // interest on a balance adds an error far below one wei; only the per-user rounding is left.
            assertGe(token.balanceOf(address(lending)) + DUST, market.totalSupply - market.totalBorrow);
        }
    }

    /// @notice The contract holds the cash that backs supplied minus borrowed, interest being owed but not yet paid.
    function invariant_BalanceBacksSupplyMinusBorrow() public view {
        _checkSolvency(usdc);
        _checkSolvency(weth);
    }

    function _checkIndexes(MockToken token) internal view {
        LendingProtocol.Market memory market = lending.getMarket(address(token));
        assertGe(market.liquidityIndex, 1e27);
        // borrowers pay at least what lenders earn
        assertGe(market.borrowIndex, market.liquidityIndex);
    }

    /// @notice Indexes never go below 1 and the borrow index is never below the liquidity index.
    function invariant_IndexesOnlyGrow() public view {
        _checkIndexes(usdc);
        _checkIndexes(weth);
    }
}
