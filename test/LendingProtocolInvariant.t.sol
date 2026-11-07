// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev Drives the protocol with random user actions and keeps ghost sums of what it should hold.
contract InvHandler is Test {
    LendingProtocol public lending;
    MockToken public usdc;
    MockToken public weth;
    address public owner;
    address[] public actors;

    uint256 public ghostDepositsUsdc;
    uint256 public ghostDepositsWeth;
    uint256 public ghostBorrowsUsdc;
    uint256 public ghostBorrowsWeth;

    constructor(LendingProtocol _lending, MockToken _usdc, MockToken _weth, address _owner, address[] memory _actors) {
        lending = _lending;
        usdc = _usdc;
        weth = _weth;
        owner = _owner;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _token(uint256 seed) internal view returns (MockToken) {
        return seed % 2 == 0 ? usdc : weth;
    }

    function _addDeposit(MockToken t, uint256 a) internal {
        if (t == usdc) ghostDepositsUsdc += a;
        else ghostDepositsWeth += a;
    }

    function _addBorrow(MockToken t, uint256 a, bool up) internal {
        if (t == usdc) ghostBorrowsUsdc = up ? ghostBorrowsUsdc + a : ghostBorrowsUsdc - a;
        else ghostBorrowsWeth = up ? ghostBorrowsWeth + a : ghostBorrowsWeth - a;
    }

    function deposit(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        MockToken t = _token(tokenSeed);
        amount = bound(amount, 1, 1_000 ether);
        vm.prank(a);
        lending.deposit(address(t), amount);
        _addDeposit(t, amount);
    }

    function withdraw(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        MockToken t = _token(tokenSeed);
        uint256 max = lending.getUserDeposit(a, address(t));
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        try lending.withdraw(address(t), amount) {
            if (t == usdc) ghostDepositsUsdc -= amount;
            else ghostDepositsWeth -= amount;
        } catch {}
    }

    function borrow(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        MockToken t = _token(tokenSeed);
        amount = bound(amount, 1, 1_000 ether);
        vm.prank(a);
        try lending.borrow(address(t), amount) {
            _addBorrow(t, amount, true);
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 tokenSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        MockToken t = _token(tokenSeed);
        uint256 max = lending.getUserBorrow(a, address(t));
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        lending.repay(address(t), amount);
        _addBorrow(t, amount, false);
    }

    /// @dev Lowers collateral factors so that some positions become liquidatable.
    function crashCollateralFactor(uint256 factor) external {
        factor = bound(factor, 0, 8000);
        vm.startPrank(owner);
        lending.updateMarket(address(usdc), factor, 0, 0);
        lending.updateMarket(address(weth), factor, 0, 0);
        vm.stopPrank();
    }

    function liquidate(uint256 liquidatorSeed, uint256 userSeed, uint256 tokenSeed, uint256 amount) external {
        address liq = _actor(liquidatorSeed);
        address victim = _actor(userSeed);
        MockToken t = _token(tokenSeed);
        uint256 max = lending.getUserBorrow(victim, address(t));
        if (max == 0 || liq == victim) return;
        amount = bound(amount, 1, max);

        uint256 depUsdcBefore = lending.getMarket(address(usdc)).totalSupply;
        uint256 depWethBefore = lending.getMarket(address(weth)).totalSupply;
        vm.prank(liq);
        try lending.liquidate(victim, address(t), amount) {
            _addBorrow(t, amount, false);
            ghostDepositsUsdc -= depUsdcBefore - lending.getMarket(address(usdc)).totalSupply;
            ghostDepositsWeth -= depWethBefore - lending.getMarket(address(weth)).totalSupply;
        } catch {}
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

/// @dev Invariants of the lending accounting.
contract LendingProtocolInvariantTest is StdInvariant, Test {
    LendingProtocol internal lending;
    MockToken internal usdc;
    MockToken internal weth;
    InvHandler internal handler;
    address[] internal actors;

    function setUp() public {
        address owner = makeAddr("owner");
        vm.prank(owner);
        lending = new LendingProtocol();
        usdc = new MockToken("USD Coin", "USDC", 18, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        vm.startPrank(owner);
        lending.addMarket(address(usdc), 8000, 500, 800);
        lending.addMarket(address(weth), 8000, 500, 800);
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

        handler = new InvHandler(lending, usdc, weth, owner, actors);
        targetContract(address(handler));
    }

    /// @notice Market totals equal the sum of per-user balances.
    function invariant_MarketTotalsMatchUserSums() public view {
        uint256 depU;
        uint256 depW;
        uint256 borU;
        uint256 borW;
        for (uint256 i = 0; i < actors.length; i++) {
            depU += lending.getUserDeposit(actors[i], address(usdc));
            depW += lending.getUserDeposit(actors[i], address(weth));
            borU += lending.getUserBorrow(actors[i], address(usdc));
            borW += lending.getUserBorrow(actors[i], address(weth));
        }
        assertEq(lending.getMarket(address(usdc)).totalSupply, depU);
        assertEq(lending.getMarket(address(weth)).totalSupply, depW);
        assertEq(lending.getMarket(address(usdc)).totalBorrow, borU);
        assertEq(lending.getMarket(address(weth)).totalBorrow, borW);
    }

    /// @notice Tokens held by the contract equal total supply minus total borrow, for each market.
    function invariant_BalanceEqualsSupplyMinusBorrow() public view {
        assertEq(
            usdc.balanceOf(address(lending)),
            lending.getMarket(address(usdc)).totalSupply - lending.getMarket(address(usdc)).totalBorrow
        );
        assertEq(
            weth.balanceOf(address(lending)),
            lending.getMarket(address(weth)).totalSupply - lending.getMarket(address(weth)).totalBorrow
        );
    }

    /// @notice The per-user totals equal the sum of the per-token entries.
    function invariant_UserTotalsMatchTokenEntries() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            assertEq(
                lending.getUser(a).totalDeposited,
                lending.getUserDeposit(a, address(usdc)) + lending.getUserDeposit(a, address(weth))
            );
            assertEq(
                lending.getUser(a).totalBorrowed,
                lending.getUserBorrow(a, address(usdc)) + lending.getUserBorrow(a, address(weth))
            );
        }
    }

    /// @notice Ghost sums tracked by the handler equal the market totals.
    function invariant_GhostSumsMatchMarkets() public view {
        assertEq(lending.getMarket(address(usdc)).totalSupply, handler.ghostDepositsUsdc());
        assertEq(lending.getMarket(address(weth)).totalSupply, handler.ghostDepositsWeth());
        assertEq(lending.getMarket(address(usdc)).totalBorrow, handler.ghostBorrowsUsdc());
        assertEq(lending.getMarket(address(weth)).totalBorrow, handler.ghostBorrowsWeth());
    }
}
