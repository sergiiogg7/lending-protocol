# Security

## Status

**This code has not been externally audited.** It is a learning and portfolio project. It must not hold real funds.

The current phase only applied engineering best practices (custom errors, two-step ownership, tests, CI). **The logic bugs listed below are known and intentionally not fixed yet**; they will be fixed one by one in a later phase. Until then the protocol is **not safe to use**.

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

1. For each market, `totalSupply` equals the sum of all users' deposits and `totalBorrow` equals the sum of all users' borrows.
2. For each market, the tokens held by the contract equal `totalSupply - totalBorrow`.
3. For each user, `totalDeposited` / `totalBorrowed` equal the sum of the per-token entries.
4. The totals tracked by the test handler (ghost variables) equal the market totals.

## Known vulnerabilities (not fixed yet)

Ordered by severity. Items marked *confirmed* were reproduced with a test or proof of concept.

| # | Severity | Issue | Where |
|---|---|---|---|
| 1 | ~~Critical~~ **Fixed (2026-11-08)** | ~~First borrow skips the collateral check.~~ `canBorrow` and `canWithdraw` no longer treat users without debt as a special case: they simulate the operation with `_position` and compare values, so the first borrow is checked like any other. Debt is valued rounding up and collateral rounding down, so dust amounts cannot be borrowed for free. | `canBorrow`, `canWithdraw`, `_position`, `_valueInUsd` |
| 2 | ~~Critical~~ **Fixed (2026-11-08)** | ~~No price oracle.~~ Every token is now valued in USD (8 decimals) through an immutable `IPriceOracle` and `_valueInUsd` (`amount * price / 10^decimals`), so tokens with different prices and decimals are comparable. The oracle reverts instead of returning 0. Still open: `liquidate` computes the seized collateral in raw units (see #6); integer division values dust amounts at 0 (see #1); a Chainlink adapter is still to be written. | `getCollateralizationRatio`, `canBorrow`, `canWithdraw`, `findBestCollateral` |
| 3 | ~~High~~ **Fixed (2026-11-08)** | ~~Collateral factor and liquidation threshold are mixed up.~~ Each market has its own `ltv` (what can be borrowed; used by `canBorrow`) and `liquidationThreshold` (when a position is liquidated; used by the health factor, `canWithdraw` and `isLiquidatable`), with `ltv <= liquidationThreshold <= 10000`. Health factor = sum(collateral usd * threshold) / sum(debt usd), scaled by 1e18; below 1 a position is liquidatable. | `getHealthFactor`, `canBorrow`, `canWithdraw`, `isLiquidatable`, `_checkRiskParameters` |
| 4 | ~~High~~ **Fixed (2026-11-08)** | ~~`emergencyRecover` can drain user funds.~~ It can only take the surplus: `getRecoverableAmount` = tokens held minus the available liquidity (supplied minus borrowed), so tokens sent by mistake, donations and rounding dust are recoverable and deposits never are. Interest owed but not yet paid is not held, so it creates no surplus. | `emergencyRecover`, `getRecoverableAmount` |
| 5 | ~~High~~ **Fixed (2026-11-08)** | ~~Instant, unbounded parameter changes by the owner.~~ `updateMarket` is gone. `setLtv` is instant (the LTV only limits new borrows, and setting it to 0 is the emergency lever); `raiseLiquidationThreshold` is instant (safer positions); lowering the threshold, which can make existing positions liquidatable, needs `proposeLiquidationThresholdDecrease` and a 2-day wait before `executeLiquidationThresholdDecrease`, with `cancelLiquidationThresholdDecrease`. All keep `ltv <= liquidationThreshold <= 95.23 %`. **Still centralised:** the owner can still pause deposits, borrows and liquidations and add markets; in production the owner should be a multisig behind a timelock. | `setLtv`, `raiseLiquidationThreshold`, `proposeLiquidationThresholdDecrease`, `executeLiquidationThresholdDecrease` |
| 6 | ~~High~~ **Fixed (2026-11-08)** | ~~Liquidation logic is flawed.~~ `liquidate(collateralToken, debtToken, user, debtToCover)` follows Aave: it needs a health factor below 1; at most 50 % of the debt in that token can be repaid (100 % if the health factor is below 0.95); the liquidator chooses the collateral and receives the repaid debt plus a 5 % bonus, priced with the oracle; it reverts if the user does not hold that much collateral or the market does not have enough free liquidity. `umbral * (1 + bonus) <= 100 %` is enforced when configuring a market. **Still open by design:** when the collateral is worth less than the debt plus the bonus (bad debt) there is no insurance fund, a liquidation reverts for the full amount and only smaller ones work; below a health factor of `threshold * (1 + bonus)` (0.84) each liquidation lowers the health factor, as in Aave. | `liquidate`, `_collateralToSeize`, `_checkRiskParameters` |
| 7 | ~~Medium~~ **Fixed (2026-11-08)** | ~~No interest accrual.~~ Each market has a `liquidityIndex` and a `borrowIndex`; deposits and debts are stored scaled (`amount / index`) and read as `scaled * index`. The indexes grow with the rates of `getBorrowRate` / `getSupplyRate` on every interaction (`_accrue`) and are projected to the current block by the views, so health factors always include accrued interest. Rounding favours the protocol (deposits and repayments round down, debts round up). `repay` and `withdraw` accept `type(uint256).max`. The indexes have 27 decimals (`RAY`, as in Aave): with 18 decimals the invariant suite found the contract short by 72 wei, because the rounding error of an accrual is proportional to the largest balance that ever passed through the market, not to what is left in it. | `_accrue`, `_indexes`, `_burnDeposit`, `_burnDebt`, `repay`, `withdraw` |
| 8 | ~~Medium~~ **Fixed (2026-11-08)** | ~~Signed deposit has no real purpose and a weak message.~~ `depositWithSignature` is removed together with its nonces, deadline and signature checks: the signer had to be `msg.sender`, so it was not gasless, and the message had no chain id or contract address, so a signature could be replayed on another deployment. A real gasless deposit would use EIP-712 and a token `permit` (EIP-2612) with a relayer. | removed |
| 9 | ~~Medium~~ **Fixed (2026-11-08)** | ~~Borrow limit uses `totalSupply`, not available liquidity.~~ `borrow`, `withdraw` and `liquidate` now check `getAvailableLiquidity` (supplied minus borrowed) and revert with `InsufficientLiquidity` instead of failing inside the token transfer. Severity was lower than listed: no funds could be lost, the transfer reverted anyway. Borrowing the token you deposited is **not** a bug (Aave allows it) and is kept on purpose. Lenders can still not withdraw while their cash is lent out: that is the liquidity risk of any lending market, mitigated by interest rates that rise with utilization (step 5). | `borrow`, `withdraw`, `liquidate`, `getAvailableLiquidity` |
| 10 | ~~Medium~~ **Fixed (2026-11-08)** | ~~Fee-on-transfer and rebasing tokens break accounting; any address can be a market.~~ `addMarket` now requires a contract with `decimals()` up to 18 and a price in the oracle (`InvalidToken`, or the oracle error when the price is missing). Deposits, repayments and liquidations check that exactly the requested amount arrived and revert with `UnsupportedToken` otherwise, so a token that charges a fee on transfer cannot make the protocol owe more than it holds. **Not supported and not detectable:** rebasing tokens, tokens whose balance changes on its own, and tokens with transfer hooks or blacklists (a blacklisted address could block an exit); only list plain ERC-20s. | `addMarket`, `_validateToken`, `_pull` |
| 11 | ~~Low~~ **Fixed (2026-11-08)** | ~~Unbounded loops.~~ `MAX_MARKETS = 16`: `addMarket` reverts with `TooManyMarkets` beyond it, so the loop over `supportedTokens` in the health checks (and the oracle call per market) is bounded. A test measures the worst case, a position with a deposit and a debt in all 16 markets: a borrow costs about 207 000 gas. Markets still cannot be removed. | `addMarket`, `_position` |
| 12 | ~~Low~~ **Fixed (2026-11-08)** | ~~Rates are not validated.~~ Rates are no longer inputs: `addMarket` and `updateMarket` take no rates, and the rates are computed from the utilization with constants. | `addMarket`, `updateMarket`, `getBorrowRate` |
| 13 | ~~Low~~ **Obsolete (2026-11-08)** | ~~`User.isActive` is inconsistent.~~ The `User` struct was redundant (no logic read it) and has been removed, so there is no flag left to keep in sync. | removed |
| 14 | Info | Redundant storage: the `User` struct (`users`, `getUser`) was **removed (2026-11-08)**. `MockToken` public `mint`/`burn` are for testing only. | |

## Notes on the best-practice pass

One small cleanup was needed for 100 % coverage and does not change behaviour: the unreachable `totalBorrowValue == 0` early returns that `canWithdraw` and `canBorrow` used to have (both were rewritten with the risk model). One behaviour change: `withdraw` and `repay` no longer use `whenNotPaused`, so users can exit while the protocol is paused.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security tab, "Report a vulnerability") instead of opening a public issue.
