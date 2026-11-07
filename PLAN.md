# PLAN

| Date | Change |
|---|---|
| 2026-11-05 | Project created with `forge init` from the downloaded `lending-borrow-protocol`. Best practices applied: pinned Foundry config, CI, Slither config, custom errors, `Ownable2Step`, named imports via remappings, NatSpec, `emergencyRecover` event, exit paths open while paused, mock moved to `test/mocks`, unit/fuzz/invariant tests (72), 100 % line coverage, deploy scripts, README, SECURITY (known bugs listed, not fixed). |
| Next | Phase 2: fix the known vulnerabilities in `SECURITY.md` one by one, with a failing test first for each. |
