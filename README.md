# Lending Protocol

A minimal lending and borrowing protocol on Ethereum, built with Foundry. Users deposit ERC-20 tokens into markets, borrow against their deposits, and unhealthy positions can be liquidated.

![CI](https://github.com/sergiiogg7/lending-protocol/actions/workflows/test.yml/badge.svg)
![Solidity 0.8.24](https://img.shields.io/badge/Solidity-0.8.24-blue)
![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)
![Tests 72](https://img.shields.io/badge/tests-72%20passing-brightgreen)

> **Not audited and not safe for real funds.** The logic has known vulnerabilities (no interest accrual and more) that are listed in [SECURITY.md](SECURITY.md) and will be fixed in a later phase.

## How it works

One contract, `LendingProtocol`, holds every market.

| Action | Function | Who |
|---|---|---|
| Add / configure a token market | `addMarket`, `updateMarket` | Owner |
| Supply tokens | `deposit`, `depositWithSignature` | Anyone |
| Take tokens out | `withdraw` (only if the health factor stays at 1 or more) | Depositor |
| Borrow | `borrow` (needs liquidity and enough collateral for the LTV) | Anyone |
| Repay | `repay` | Borrower |
| Liquidate an unhealthy position | `liquidate` (health factor below 1: the liquidator repays up to 50 % of a debt, 100 % below 0.95, and receives the collateral of their choice worth the repaid debt plus a 5 % bonus) | Anyone |
| Emergency controls | `pause`, `unpause`, `emergencyRecover` | Owner |

Key numbers: per market, `ltv` (what you can borrow against the collateral) and `liquidationThreshold` (when you are liquidated), in basis points with `ltv <= liquidationThreshold <= 10 000`; liquidation bonus 5 %, so `liquidationThreshold` is at most 95.23 %. A position is healthy while its health factor, `sum(collateral usd * threshold) / sum(debt usd)`, is at least 1. `withdraw` and `repay` keep working while the protocol is paused.

## Usage example

```solidity
// owner
lending.addMarket(address(usdc), 8000, 500, 800);
lending.addMarket(address(weth), 8000, 500, 800);

// lender supplies WETH liquidity
weth.approve(address(lending), 100 ether);
lending.deposit(address(weth), 100 ether);

// borrower posts USDC and borrows WETH
usdc.approve(address(lending), 100 ether);
lending.deposit(address(usdc), 100 ether);
lending.borrow(address(weth), 50 ether);

// later
weth.approve(address(lending), 50 ether);
lending.repay(address(weth), 50 ether);
lending.withdraw(address(usdc), 100 ether);
```

## Build and test

```bash
git clone --recurse-submodules https://github.com/sergiiogg7/lending-protocol
cd lending-protocol
forge build
forge test -vvv
forge coverage --no-match-coverage "script|test"
```

72 tests: unit, fuzz and invariants (market totals match user balances, contract balance equals supply minus borrow), 100 % line coverage on `src/`. Dependencies: OpenZeppelin Contracts v5.4.0 and forge-std (git submodules).

## Local deployment

```bash
anvil
forge script script/LocalDeploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

For a testnet, copy `.env.example` to `.env` and run `script/Deploy.s.sol`.

## Project layout

```
src/LendingProtocol.sol        protocol
test/                          unit, fuzz and invariant tests, mocks/MockToken.sol
script/                        Deploy.s.sol, LocalDeploy.s.sol
SECURITY.md                    measures, invariants and known vulnerabilities
```

## License

MIT
