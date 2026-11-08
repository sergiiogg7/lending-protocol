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
| Checks-Effects-Interactions in `deposit`, `depositWithSignature`, `withdraw`, `borrow`, `repay`, `liquidate` (state is updated before any token transfer) | `src/LendingProtocol.sol` |
| `Pausable`: `deposit`, `borrow`, `depositWithSignature` and `liquidate` can be paused; `withdraw` and `repay` stay open so users can always exit | `src/LendingProtocol.sol` |
| Zero-address / zero-amount / collateral-factor range validation | `src/LendingProtocol.sol` |
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
| 4 | High | **`emergencyRecover` can drain user funds** (*confirmed*). The owner can withdraw any amount of any token, including tokens backing deposits, with no accounting check. | `emergencyRecover` |
| 5 | High | **Instant, unbounded parameter changes by the owner.** `updateMarket` can set `ltv` and `liquidationThreshold` to 0 and make every borrower liquidatable at once. No timelock, no lower bound. | `updateMarket` |
| 6 | ~~High~~ **Fixed (2026-11-08)** | ~~Liquidation logic is flawed.~~ `liquidate(collateralToken, debtToken, user, debtToCover)` follows Aave: it needs a health factor below 1; at most 50 % of the debt in that token can be repaid (100 % if the health factor is below 0.95); the liquidator chooses the collateral and receives the repaid debt plus a 5 % bonus, priced with the oracle; it reverts if the user does not hold that much collateral or the market does not have enough free liquidity. `umbral * (1 + bonus) <= 100 %` is enforced when configuring a market. **Still open by design:** when the collateral is worth less than the debt plus the bonus (bad debt) there is no insurance fund, a liquidation reverts for the full amount and only smaller ones work; below a health factor of `threshold * (1 + bonus)` (0.84) each liquidation lowers the health factor, as in Aave. | `liquidate`, `_collateralToSeize`, `_checkRiskParameters` |
| 7 | Medium | **No interest accrual** (*partly addressed*). The rates are now computed from the utilization (`getUtilization`, `getBorrowRate`, `getSupplyRate`: a curve with a kink at 80 %, supply rate = borrow rate * utilization, no reserve factor), but they are not charged yet: balances do not grow, so depositors earn nothing and borrowers pay nothing. Interest accrual with indexes is the next commit. | `getBorrowRate`, `getSupplyRate`, `borrow`, `repay` |
| 8 | Medium | **Signed deposit has no real purpose and a weak message.** The signer must be `msg.sender`, so it is not gasless. The message is `abi.encodePacked` with no chain id, no contract address and no EIP-712 domain, so a signature can be replayed on another deployment or chain. | `depositWithSignature` |
| 9 | ~~Medium~~ **Fixed (2026-11-08)** | ~~Borrow limit uses `totalSupply`, not available liquidity.~~ `borrow`, `withdraw` and `liquidate` now check `getAvailableLiquidity` (supplied minus borrowed) and revert with `InsufficientLiquidity` instead of failing inside the token transfer. Severity was lower than listed: no funds could be lost, the transfer reverted anyway. Borrowing the token you deposited is **not** a bug (Aave allows it) and is kept on purpose. Lenders can still not withdraw while their cash is lent out: that is the liquidity risk of any lending market, mitigated by interest rates that rise with utilization (step 5). | `borrow`, `withdraw`, `liquidate`, `getAvailableLiquidity` |
| 10 | Medium | **Fee-on-transfer and rebasing tokens break accounting.** Amounts are credited as requested, not as received. Any address (even a non-token) can be added as a market. | `deposit`, `repay`, `addMarket` |
| 11 | Low | **Unbounded loops.** Health checks iterate over `supportedTokens`, which only grows (markets cannot be removed), so gas grows with each market. | `_position`, `canBorrow`, `canWithdraw`, `findBestCollateral` |
| 12 | ~~Low~~ **Fixed (2026-11-08)** | ~~Rates are not validated.~~ Rates are no longer inputs: `addMarket` and `updateMarket` take no rates, and the rates are computed from the utilization with constants. | `addMarket`, `updateMarket`, `getBorrowRate` |
| 13 | ~~Low~~ **Obsolete (2026-11-08)** | ~~`User.isActive` is inconsistent.~~ The `User` struct was redundant (no logic read it) and has been removed, so there is no flag left to keep in sync. | removed |
| 14 | Info | Redundant storage: the `User` struct (`users`, `getUser`) was **removed (2026-11-08)**. `MockToken` public `mint`/`burn` are for testing only. | |

## Notes on the best-practice pass

Two small cleanups were needed for 100 % coverage and do not change behaviour: the unreachable `signer != address(0)` check in `depositWithSignature` (OpenZeppelin's `ECDSA.recover` already reverts on an invalid signature) and the unreachable `totalBorrowValue == 0` early returns that `canWithdraw` and `canBorrow` used to have (both were rewritten with the risk model). One behaviour change: `withdraw` and `repay` no longer use `whenNotPaused`, so users can exit while the protocol is paused.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security tab, "Report a vulnerability") instead of opening a public issue.
