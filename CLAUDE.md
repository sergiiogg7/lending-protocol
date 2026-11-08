# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Foundry project (solc 0.8.24, EVM `cancun`, optimizer 200 runs). Dependencies (`forge-std`, `openzeppelin-contracts` v5.4.0) are git submodules in `lib/`: run `forge install` or clone with `--recurse-submodules`.

```bash
forge build
forge test -vvv                                   # what CI runs (profile ci: more fuzz/invariant runs)
forge test --match-test <name> -vvvv              # single test
forge test --match-path test/LendingProtocolFuzz.t.sol
forge coverage --no-match-coverage "script|test"  # line coverage on src/
forge fmt --check                                 # CI enforces formatting
forge snapshot                                    # regenerate .gas-snapshot after intentional gas changes
```

CI (`.github/workflows/test.yml`) runs `forge fmt --check`, `forge build --sizes`, `forge test` (profile `ci`), a 95% line-coverage gate on `src/`, `forge snapshot --check` and Slither (`fail-on: low`). Copy `.env.example` to `.env` for deployment; never commit `.env`.

Deploy: `script/Deploy.s.sol` reads `PRIVATE_KEY`, `ORACLE` (price oracle address) and the optional `OWNER` (offered ownership, must call `acceptOwnership()`). `script/LocalDeploy.s.sol` is the Anvil version: `MockPriceOracle` (every token at 1 USD), protocol, two mock tokens and their markets.

## Architecture

One contract in `src/`: `LendingProtocol` (`ReentrancyGuard`, `Pausable`, `Ownable2Step`). The owner adds markets (`addMarket`, `updateMarket`); users `deposit`, `withdraw`, `borrow`, `repay`, `depositWithSignature` and anyone can `liquidate(collateralToken, debtToken, user, debtToCover)` a position with a health factor below 1 (close factor 50 %, or 100 % below 0.95; 5 % bonus in the collateral chosen by the liquidator). State: `markets[token]`, `userDeposits[user][token]`, `userBorrows[user][token]`, `users[user]`, `userNonces`, `supportedTokens`. Interest rates are not stored: `getUtilization`, `getBorrowRate` and `getSupplyRate` compute them from constants (curve with a kink at 80 % utilization, no reserve factor). Every token is valued in USD (8 decimals) through the immutable `oracle`. Each market has an `ltv` and a `liquidationThreshold`; `_position` aggregates a user in USD (collateral rounded down, debt rounded up) and `getHealthFactor` (1e18 = 1), `canBorrow` (LTV), `canWithdraw` (health factor >= 1) and `isLiquidatable` (health factor < 1) loop over `supportedTokens`. `withdraw` and `repay` are not pausable on purpose. Errors are custom errors, never `require` strings.

**Known logic bugs are listed in `SECURITY.md`; the ones not marked as fixed are deliberately still open.** Do not "fix" them while doing unrelated work: phase 2 fixes them one by one, test first, following the roadmap in `PLAN.md`.

## Tests

| File | Type |
|---|---|
| `LendingProtocol.t.sol` | Unit tests (original suite, adapted to custom errors) |
| `LendingProtocolFlows.t.sol` | Unit tests: signed deposit, liquidation, pause, ownership, recovery |
| `LendingProtocolFuzz.t.sol` | Fuzz tests |
| `LendingProtocolInvariant.t.sol` | Invariant tests with a handler and ghost variables |
| `LendingProtocolRisk.t.sol` | Risk model: `ltv`, `liquidationThreshold`, health factor, withdrawals, end-to-end scenario |
| `LendingProtocolRates.t.sol` | Interest rate model: utilization, borrow rate curve with a kink, supply rate, fuzz |
| `LendingProtocolLiquidity.t.sol` | Available liquidity limits `borrow` and `withdraw`; borrowing the deposited token is allowed |
| `LendingProtocolLiquidation.t.sol` | Liquidation: close factor, bonus, liquidity, bad debt, `isActive`, fuzz on the health factor |
| `LendingProtocolOracle.t.sol` | How the protocol uses the oracle |
| `mocks/MockPriceOracle.sol` | Settable USD price source (tests and `LocalDeploy` only) |
| `mocks/MockToken.sol` | Mintable ERC20 with configurable decimals (also used by `LocalDeploy`) |

Naming: `test_<What>`, `test_RevertWhen_<Condition>`, `testFuzz_<Property>`, `invariant_<Property>`. Aim for 100% line coverage in `src/`. Tests need a `MockPriceOracle` with a price for every token. `LendingProtocolRisk.t.sol` holds the risk model, including the Lucia scenario.
