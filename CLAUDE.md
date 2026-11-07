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

Deploy: `script/Deploy.s.sol` reads `PRIVATE_KEY` and the optional `OWNER` (offered ownership, must call `acceptOwnership()`). `script/LocalDeploy.s.sol` is the Anvil version: protocol, two mock tokens and their markets.

## Architecture

One contract in `src/`: `LendingProtocol` (`ReentrancyGuard`, `Pausable`, `Ownable2Step`). The owner adds markets (`addMarket`, `updateMarket`); users `deposit`, `withdraw`, `borrow`, `repay`, `depositWithSignature` and anyone can `liquidate` an unhealthy position. State: `markets[token]`, `userDeposits[user][token]`, `userBorrows[user][token]`, `users[user]`, `userNonces`, `supportedTokens`. Health checks (`getCollateralizationRatio`, `canBorrow`, `canWithdraw`, `isLiquidatable`) loop over `supportedTokens`. `withdraw` and `repay` are not pausable on purpose. Errors are custom errors, never `require` strings.

**Known logic bugs are listed in `SECURITY.md` and are deliberately not fixed yet.** Do not "fix" them while doing unrelated work; fixing them is phase 2, one by one, test first.

## Tests

| File | Type |
|---|---|
| `LendingProtocol.t.sol` | Unit tests (original suite, adapted to custom errors) |
| `LendingProtocolFlows.t.sol` | Unit tests: signed deposit, liquidation, pause, ownership, recovery |
| `LendingProtocolFuzz.t.sol` | Fuzz tests |
| `LendingProtocolInvariant.t.sol` | Invariant tests with a handler and ghost variables |
| `mocks/MockToken.sol` | Mintable ERC20 with configurable decimals (also used by `LocalDeploy`) |

Naming: `test_<What>`, `test_RevertWhen_<Condition>`, `testFuzz_<Property>`, `invariant_<Property>`. Aim for 100% line coverage in `src/`. Because of the known bug that the first borrow skips the collateral check, fuzz properties about borrowing start from the second borrow.
