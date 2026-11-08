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
| 6 | High | **Liquidation logic is flawed.** The seized collateral is `amount * 105 %` in collateral units with no price, there is no close factor (a whole debt can be liquidated at once), it does not check that the position is healthier afterwards, it never checks that the contract holds enough free liquidity of the seized token, and the collateral is chosen by the highest weighted balance rather than by the liquidator. | `liquidate`, `findBestCollateral` |
| 7 | Medium | **No interest accrual.** `supplyRate` and `borrowRate` are stored and emitted but never used, so depositors earn nothing and borrowers pay nothing. | `Market`, `updateMarket` |
| 8 | Medium | **Signed deposit has no real purpose and a weak message.** The signer must be `msg.sender`, so it is not gasless. The message is `abi.encodePacked` with no chain id, no contract address and no EIP-712 domain, so a signature can be replayed on another deployment or chain. | `depositWithSignature` |
| 9 | Medium | **Borrow limit uses `totalSupply`, not available liquidity.** `totalSupply` includes tokens already lent out, so a borrow can pass the check and then fail at transfer. A user can also borrow the same token they deposited as collateral. | `borrow` |
| 10 | Medium | **Fee-on-transfer and rebasing tokens break accounting.** Amounts are credited as requested, not as received. Any address (even a non-token) can be added as a market. | `deposit`, `repay`, `addMarket` |
| 11 | Low | **Unbounded loops.** Health checks iterate over `supportedTokens`, which only grows (markets cannot be removed), so gas grows with each market. | `_position`, `canBorrow`, `canWithdraw`, `findBestCollateral` |
| 12 | Low | **Rates are not validated** (no upper bound). | `addMarket`, `updateMarket` |
| 13 | Low | **`User.isActive` is inconsistent.** It is cleared when deposits reach zero even with open debt (and vice versa), and `liquidate` does not update the user record. | `withdraw`, `repay`, `liquidate` |
| 14 | Info | Redundant storage (`users`, `userDeposits`, `userBorrows`) and `MockToken` public `mint`/`burn` are for testing only. | |

## Notes on the best-practice pass

Two small cleanups were needed for 100 % coverage and do not change behaviour: the unreachable `signer != address(0)` check in `depositWithSignature` (OpenZeppelin's `ECDSA.recover` already reverts on an invalid signature) and the unreachable `totalBorrowValue == 0` early returns that `canWithdraw` and `canBorrow` used to have (both were rewritten with the risk model). One behaviour change: `withdraw` and `repay` no longer use `whenNotPaused`, so users can exit while the protocol is paused.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security tab, "Report a vulnerability") instead of opening a public issue.
