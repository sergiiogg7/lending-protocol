# PLAN

| Date | Change |
|---|---|
| 2026-11-05 | Project created with `forge init` from the downloaded `lending-borrow-protocol`. Best practices applied: pinned Foundry config, CI, Slither config, custom errors, `Ownable2Step`, named imports via remappings, NatSpec, `emergencyRecover` event, exit paths open while paused, mock moved to `test/mocks`, unit/fuzz/invariant tests (72), 100 % line coverage, deploy scripts, README, SECURITY (known bugs listed, not fixed). |
| 2026-11-08 | Contract walkthrough done. Phase 2 roadmap defined below (Aave-inspired, simplified). |

## Phase 2 roadmap

Goal: understand lending and borrowing by building a simplified Aave V3-style core. Each step: explain first, write the failing test, fix, update `SECURITY.md`. Numbers refer to `SECURITY.md`.

| Step | Fixes | What | Why it matters |
|---|---|---|---|
| 1 | #2 (done 2026-11-08) | `IPriceOracle` (USD, 8 decimals) with a mock oracle for tests and decimals normalization. Chainlink adapter later, for Sepolia. | Collateral and debt are only comparable in a common unit. Everything below depends on it. |
| 2 | #1, #3 (done 2026-11-08) | Per-market `ltv` and `liquidationThreshold` (threshold > LTV), health factor in USD, remove the "no debt, always allowed" shortcut. | The core risk model: borrow up to LTV, liquidated below the threshold. |
| 3 | #6, #13 (done 2026-11-08) | Liquidation: close factor 50 %, per-market bonus, liquidator picks the collateral, price-based seizure, health factor must improve, liquidity check. | Most asked topic in interviews. |
| 4 | #9 (done 2026-11-08) | Borrow against real available liquidity (`totalSupply - totalBorrow`). | Accounting correctness. |
| 5 | #7, #12 | Interest: utilization-based borrow rate (kinked curve), supply rate from borrow rate and utilization, per-market liquidity and borrow indexes. | The heart of Aave and Compound. |
| 6 | #4, #5 | Owner limits: `emergencyRecover` only for surplus (never user funds), bounded parameter changes. | Centralization risk. |
| 7 | #8 | Remove `depositWithSignature` (not gasless, adds attack surface). | Simplify. |
| 8 | #10, #11, #14 | Token validation, cap on markets, cleanup. | Hardening. |

## Deliberately left out (Aave has it, it adds difficulty but little understanding)

aTokens and debt tokens (internal accounting instead), stable-rate borrowing, flash loans, eMode, isolation mode, supply/borrow caps, bitmap configuration, upgradeable proxies, governance, `permit`. Each can be explained in an interview as the next step.
