# Lending Protocol

A minimal lending and borrowing protocol on Ethereum, built with Foundry and modelled on Aave. Users deposit ERC-20 tokens into markets and earn interest, borrow against their deposits, and unhealthy positions can be liquidated.

![CI](https://github.com/sergiiogg7/lending-protocol/actions/workflows/test.yml/badge.svg)
![Solidity 0.8.24](https://img.shields.io/badge/Solidity-0.8.24-blue)
![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)
![Tests 146](https://img.shields.io/badge/tests-146%20passing-brightgreen)

> **Not audited and not safe for real funds.** A few issues are still open (token validation, unbounded market loops, a signed deposit with no real purpose) and are listed in [SECURITY.md](SECURITY.md).

## How it works

One contract, `LendingProtocol`, holds every market. Every token is valued in USD through a price oracle (`IPriceOracle`, 8 decimals), so collateral and debt of different tokens and decimals can be compared.

| Action | Function | Who |
|---|---|---|
| Add a token market | `addMarket` | Owner |
| Change risk parameters | `setLtv` and `raiseLiquidationThreshold` take effect at once; lowering the liquidation threshold needs `proposeLiquidationThresholdDecrease`, two days and `executeLiquidationThresholdDecrease` | Owner |
| Supply tokens and earn interest | `deposit`, `depositWithSignature` | Anyone |
| Take tokens out | `withdraw` (only if the health factor stays at 1 or more and the market has the cash; `type(uint256).max` withdraws everything) | Depositor |
| Borrow | `borrow` (needs available liquidity and enough collateral for the LTV) | Anyone |
| Repay | `repay` (`type(uint256).max` repays the whole debt, interest included) | Borrower |
| Liquidate an unhealthy position | `liquidate` (health factor below 1: the liquidator repays up to 50 % of a debt, 100 % below 0.95, and receives the collateral of their choice worth the repaid debt plus a 5 % bonus) | Anyone |
| Emergency controls | `pause`, `unpause`, `emergencyRecover` (only the surplus the contract holds beyond what it owes to depositors) | Owner |

### Risk model

Per market, `ltv` (how much you can borrow against it) and `liquidationThreshold` (when you are liquidated), in basis points with `ltv <= liquidationThreshold`. The **health factor** is `sum(collateral usd * liquidationThreshold) / sum(debt usd)`: a position is healthy while it is at least 1 and liquidatable below 1. Borrowing is limited by the LTV, withdrawing and liquidating by the threshold, and the gap between them is the safety margin. With the 5 % liquidation bonus, a threshold can be at most 95.23 %. Collateral is valued rounding down and debt rounding up, always in favour of the protocol. `withdraw` and `repay` keep working while the protocol is paused.

### Interest

Rates are not set by anyone: they are computed from the utilization `borrowed / supplied`. The borrow rate follows a curve with a kink at 80 % utilization (0 % at no use, 4 % at the kink, 79 % at 100 %), and the supply rate is `borrowRate * utilization`, so depositors earn everything borrowers pay (no reserve factor). Interest accrues with two indexes per market, `liquidityIndex` and `borrowIndex`: balances are stored scaled (`amount / index`) and read as `scaled * index`, so growing one number grows the balance of every user. Indexes have 27 decimals (`RAY`, as in Aave) and are updated on every interaction with the market; the views project them to the current block.

## Usage example

```solidity
// owner: the oracle values every token in USD with 8 decimals
oracle.setPrice(address(usdc), 1e8);
oracle.setPrice(address(weth), 2000e8);
lending.addMarket(address(usdc), 8000, 8500); // ltv 80 %, liquidation threshold 85 %
lending.addMarket(address(weth), 7500, 8000);

// lender supplies USDC liquidity and starts earning interest
usdc.approve(address(lending), 100_000e6);
lending.deposit(address(usdc), 100_000e6);

// borrower posts WETH and borrows USDC (at most 75 % of the collateral value)
weth.approve(address(lending), 10 ether);
lending.deposit(address(weth), 10 ether);
lending.borrow(address(usdc), 10_000e6);

// later: repay everything, interest included, and take the collateral back
usdc.approve(address(lending), type(uint256).max);
lending.repay(address(usdc), type(uint256).max);
lending.withdraw(address(weth), type(uint256).max);
```

## Build and test

```bash
git clone --recurse-submodules https://github.com/sergiiogg7/lending-protocol
cd lending-protocol
forge build
forge test -vvv
forge coverage --no-match-coverage "script|test"
```

146 tests: unit, fuzz and invariants (market totals match user balances, the contract holds the cash that backs supplied minus borrowed, indexes only grow), 100 % line coverage on `src/`. The risk model, liquidation, rates and interest each have their own suite and an end-to-end scenario with exact numbers. Dependencies: OpenZeppelin Contracts v5.4.0 and forge-std (git submodules).

## Local deployment

```bash
anvil
forge script script/LocalDeploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

It deploys a mock price oracle (every token at 1 USD), the protocol and two mock tokens with their markets. For a testnet, copy `.env.example` to `.env` (set `ORACLE` to a real price oracle) and run `script/Deploy.s.sol`.

## Project layout

```
src/LendingProtocol.sol        protocol
src/interfaces/IPriceOracle.sol  price source (USD, 8 decimals)
test/                          unit, fuzz and invariant tests, mocks (token and price oracle)
script/                        Deploy.s.sol, LocalDeploy.s.sol
SECURITY.md                    measures, invariants and known vulnerabilities
PLAN.md                        phase 2 roadmap and what was changed
```

## License

MIT
