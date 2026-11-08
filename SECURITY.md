# Security

## Status

**This code has not been externally audited.** It is a learning and portfolio project. It must not hold real funds.

The logic bugs found in the original code (table below) have all been fixed, one by one with a test first. That does not make the protocol safe: it has had no review other than its own tests, and the points under [Limitations that remain](#limitations-that-remain) are open on purpose. Only a mock price oracle exists, so it cannot be deployed against real markets yet.

## Measures in place

| Measure | Where |
|---|---|
| `ReentrancyGuard` (`nonReentrant`) on every state-changing user function | `src/LendingProtocol.sol` |
| `SafeERC20` for every token transfer | `src/LendingProtocol.sol` |
| `Ownable2Step`: ownership moves in two steps | `src/LendingProtocol.sol` |
| Custom errors, no `require` strings | `src/LendingProtocol.sol` |
| Checks-Effects-Interactions in `deposit`, `withdraw`, `borrow`, `repay`, `liquidate` (state is updated before any token transfer) | `src/LendingProtocol.sol` |
| `Pausable`: `deposit`, `borrow` and `liquidate` can be paused; `withdraw` and `repay` stay open so users can always exit | `src/LendingProtocol.sol` |
| Zero-address / zero-amount / risk-parameter range validation | `src/LendingProtocol.sol` |
| Slither in CI with `fail-on: low`, currently 0 findings. Two detectors need an explanation: `timestamp` is excluded in `slither.config.json` because interest accrual and the two-day notice need `block.timestamp` by design and the detector flags every comparison that depends on it; `incorrect-equality` (zero checks) and `calls-loop` (one oracle call per market) are disabled line by line in the code, each with its reason | `slither.config.json`, `src/LendingProtocol.sol` |
| Events with the user as `indexed` on every state change, including `emergencyRecover` | `src/LendingProtocol.sol` |

## Invariants (tested in `test/LendingProtocolInvariant.t.sol`)

The handler deposits, withdraws, borrows, repays, liquidates, skips time (up to 90 days per call) and moves prices.

1. For each market, `totalSupply` equals the sum of all users' deposits and `totalBorrow` the sum of all users' debts, interest included (up to rounding: deposits round down and debts round up, a few wei at most).
2. For each market, the tokens held by the contract cover `totalSupply - totalBorrow` (up to the same rounding). Interest that is owed but not paid yet is not held, so it does not enter this equation.
3. The liquidity index never goes below 1 and the borrow index is never below the liquidity index: borrowers pay at least what lenders earn.

Other properties are fuzzed in their own suites: interest paid equals interest earned, everyone can exit after the borrowers repay, recovering the surplus never blocks an exit, a liquidation improves the health factor while it is above `threshold * (1 + bonus)`, and the borrow rate never falls when utilization grows.

## Findings of the original code and their status

The 14 findings of the first review, ordered by severity. All of them are closed; the rows keep the original title crossed out and describe the fix.

| # | Severity | Issue | Where |
|---|---|---|---|
| 1 | ~~Critical~~ **Fixed (2026-11-08)** | ~~First borrow skips the collateral check.~~ `canBorrow` and `canWithdraw` no longer treat users without debt as a special case: they simulate the operation with `_position` and compare values, so the first borrow is checked like any other. Debt is valued rounding up and collateral rounding down, so dust amounts cannot be borrowed for free. | `canBorrow`, `canWithdraw`, `_position`, `_valueInUsd` |
| 2 | ~~Critical~~ **Fixed (2026-11-08)** | ~~No price oracle.~~ Every token is now valued in USD (8 decimals) through an immutable `IPriceOracle` and `_valueInUsd` (`amount * price / 10^decimals`), so tokens with different prices and decimals are comparable. The oracle reverts instead of returning 0. Only a mock oracle exists: the Chainlink adapter is listed under the limitations. | `_valueInUsd`, `_position`, `_collateralToSeize` |
| 3 | ~~High~~ **Fixed (2026-11-08)** | ~~Collateral factor and liquidation threshold are mixed up.~~ Each market has its own `ltv` (what can be borrowed; used by `canBorrow`) and `liquidationThreshold` (when a position is liquidated; used by the health factor, `canWithdraw` and `isLiquidatable`), with `ltv <= liquidationThreshold <= 95.23 %`. Health factor = sum(collateral usd * threshold) / sum(debt usd), scaled by 1e18; below 1 a position is liquidatable. | `getHealthFactor`, `canBorrow`, `canWithdraw`, `isLiquidatable`, `_checkRiskParameters` |
| 4 | ~~High~~ **Fixed (2026-11-08)** | ~~`emergencyRecover` can drain user funds.~~ It can only take the surplus: `getRecoverableAmount` = tokens held minus the available liquidity (supplied minus borrowed), so tokens sent by mistake, donations and rounding dust are recoverable and deposits never are. Interest owed but not yet paid is not held, so it creates no surplus. | `emergencyRecover`, `getRecoverableAmount` |
| 5 | ~~High~~ **Fixed (2026-11-08)** | ~~Instant, unbounded parameter changes by the owner.~~ `updateMarket` is gone. `setLtv` is instant (the LTV only limits new borrows, and setting it to 0 is the emergency lever); `raiseLiquidationThreshold` is instant (safer positions); lowering the threshold, which can make existing positions liquidatable, needs `proposeLiquidationThresholdDecrease` and a 2-day wait before `executeLiquidationThresholdDecrease`, with `cancelLiquidationThresholdDecrease`. All keep `ltv <= liquidationThreshold <= 95.23 %`. **Still centralised:** the owner can still pause deposits, borrows and liquidations and add markets; in production the owner should be a multisig behind a timelock. | `setLtv`, `raiseLiquidationThreshold`, `proposeLiquidationThresholdDecrease`, `executeLiquidationThresholdDecrease` |
| 6 | ~~High~~ **Fixed (2026-11-08)** | ~~Liquidation logic is flawed.~~ `liquidate(collateralToken, debtToken, user, debtToCover)` follows Aave: it needs a health factor below 1; at most 50 % of the debt in that token can be repaid (100 % if the health factor is below 0.95); the liquidator chooses the collateral and receives the repaid debt plus a 5 % bonus, priced with the oracle; it reverts if the user does not hold that much collateral or the market does not have enough free liquidity. `threshold * (1 + bonus) <= 100 %` is enforced when configuring a market. **Still open by design:** when the collateral is worth less than the debt plus the bonus (bad debt) there is no insurance fund, a liquidation reverts for the full amount and only smaller ones work; below a health factor of `threshold * (1 + bonus)` (0.84) each liquidation lowers the health factor, as in Aave. | `liquidate`, `_collateralToSeize`, `_checkRiskParameters` |
| 7 | ~~Medium~~ **Fixed (2026-11-08)** | ~~No interest accrual.~~ Each market has a `liquidityIndex` and a `borrowIndex`; deposits and debts are stored scaled (`amount / index`) and read as `scaled * index`. The indexes grow with the rates of `getBorrowRate` / `getSupplyRate` on every interaction (`_accrue`) and are projected to the current block by the views, so health factors always include accrued interest. Rounding favours the protocol (deposits and repayments round down, debts round up). `repay` and `withdraw` accept `type(uint256).max`. The indexes have 27 decimals (`RAY`, as in Aave): with 18 decimals the invariant suite found the contract short by 72 wei, because the rounding error of an accrual is proportional to the largest balance that ever passed through the market, not to what is left in it. | `_accrue`, `_indexes`, `_burnDeposit`, `_burnDebt`, `repay`, `withdraw` |
| 8 | ~~Medium~~ **Fixed (2026-11-08)** | ~~Signed deposit has no real purpose and a weak message.~~ `depositWithSignature` is removed together with its nonces, deadline and signature checks: the signer had to be `msg.sender`, so it was not gasless, and the message had no chain id or contract address, so a signature could be replayed on another deployment. A real gasless deposit would use EIP-712 and a token `permit` (EIP-2612) with a relayer. | removed |
| 9 | ~~Medium~~ **Fixed (2026-11-08)** | ~~Borrow limit uses `totalSupply`, not available liquidity.~~ `borrow`, `withdraw` and `liquidate` now check `getAvailableLiquidity` (supplied minus borrowed) and revert with `InsufficientLiquidity` instead of failing inside the token transfer. Severity was lower than listed: no funds could be lost, the transfer reverted anyway. Borrowing the token you deposited is **not** a bug (Aave allows it) and is kept on purpose. Lenders can still not withdraw while their cash is lent out: that is the liquidity risk of any lending market, mitigated by interest rates that rise with utilization (see #7). | `borrow`, `withdraw`, `liquidate`, `getAvailableLiquidity` |
| 10 | ~~Medium~~ **Fixed (2026-11-08)** | ~~Fee-on-transfer and rebasing tokens break accounting; any address can be a market.~~ `addMarket` now requires a contract with `decimals()` up to 18 and a price in the oracle (`InvalidToken`, or the oracle error when the price is missing). Deposits, repayments and liquidations check that exactly the requested amount arrived and revert with `UnsupportedToken` otherwise, so a token that charges a fee on transfer cannot make the protocol owe more than it holds. **Not supported and not detectable:** rebasing tokens, tokens whose balance changes on its own, and tokens with transfer hooks or blacklists (a blacklisted address could block an exit); only list plain ERC-20s. | `addMarket`, `_validateToken`, `_pull` |
| 11 | ~~Low~~ **Fixed (2026-11-08)** | ~~Unbounded loops.~~ `MAX_MARKETS = 16`: `addMarket` reverts with `TooManyMarkets` beyond it, so the loop over `supportedTokens` in the health checks (and the oracle call per market) is bounded. A test measures the worst case, a position with a deposit and a debt in all 16 markets: a borrow costs about 207 000 gas. Markets still cannot be removed. | `addMarket`, `_position` |
| 12 | ~~Low~~ **Fixed (2026-11-08)** | ~~Rates are not validated.~~ Rates are no longer inputs: `addMarket` takes no rates, and the rates are computed from the utilization with constants. | `addMarket`, `getBorrowRate` |
| 13 | ~~Low~~ **Obsolete (2026-11-08)** | ~~`User.isActive` is inconsistent.~~ The `User` struct was redundant (no logic read it) and has been removed, so there is no flag left to keep in sync. | removed |
| 14 | ~~Info~~ **Fixed (2026-11-08)** | ~~Redundant storage and unused fields.~~ The `User` struct (`users`, `getUser`) and the unused `token` field of the market are removed. `MockToken` has a public `mint`, but it lives in `test/mocks` and is never deployed by `Deploy.s.sol`. | removed |

## Limitations that remain

These are open on purpose or out of scope, not forgotten.

| Limitation | Why it matters | What would fix it |
|---|---|---|
| **Only a mock oracle** (`IPriceOracle` + `MockPriceOracle`) | The protocol is only as safe as its prices. The oracle is immutable, so a broken one cannot be replaced | A Chainlink adapter with staleness checks (and a sequencer check on an L2); a way to migrate the oracle behind the two-day notice |
| **Bad debt has no cover** | If the collateral is worth less than the debt plus the 5 % bonus, liquidations lose money for the protocol and, below a health factor of 0.84, each liquidation lowers the health factor | A reserve factor feeding a treasury or insurance module (Aave has both) |
| **Centralised owner** | The owner can list markets, pause deposits, borrows and liquidations, set the LTV (even to 0) at once, raise a threshold at once and recover the surplus. Lowering a threshold needs a two-day notice | Make the owner a multisig behind a timelock (for example OpenZeppelin `TimelockController`) |
| **One global rate curve, no reserve factor** | Every market uses the same kinked curve and depositors earn all the interest | Per-market rate strategies and a reserve factor |
| **Plain ERC-20s only** | Fee-on-transfer tokens revert; rebasing tokens, hooks and blacklists cannot be detected (a blacklisted address could block an exit) | List only audited, plain tokens |
| **Markets are permanent** | A listed market cannot be removed or frozen, only starved by setting its LTV to 0; at most 16 markets | A freeze and a deprecation flow |
| **No supply or borrow caps, no flash loans, no stable rates, no isolation mode** | Not implemented; each is an Aave feature that does not change the core mechanism | Add as separate, tested modules |
| **Not audited** | Own tests only: unit, fuzz, invariants and Slither | An external audit before any real funds |

## Notes on the best-practice pass

One small cleanup was needed for 100 % coverage and does not change behaviour: the unreachable `totalBorrowValue == 0` early returns that `canWithdraw` and `canBorrow` used to have (both were rewritten with the risk model). One behaviour change: `withdraw` and `repay` do not use `whenNotPaused`, so users can exit while the protocol is paused.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security tab, "Report a vulnerability") instead of opening a public issue.
