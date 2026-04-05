## TDD Enforcement Table

The orchestrator uses this table to decide whether to include TDD instructions in each sub-agent's prompt. The sub-agent prompt template (Phase 5) contains the full RED-GREEN-VALIDATE flow.

| Issue Type | TDD Required? | Why |
|-----------|---------------|-----|
| Runtime error without test | **YES** | Behavioral bug — most important TDD case |
| Logic bug (wrong output) | **YES** | Test proves correct behavior, prevents recurrence |
| Data corruption / state bug | **YES** | Test captures the exact failure condition |
| MyPy type error (complex) | **YES** | Multi-file type mismatches may cause runtime errors |
| MyPy type error (simple) | NO | Missing annotation or obvious fix — mypy itself is the test |
| Ruff lint violation | NO | Style/safety, not behavioral |
| Unit test failure | NO — failing test IS the RED test | Make it pass |
| E2E test failure | NO — failing test IS the RED test | Make it pass |
| Import error | NO | Mechanical fix — existing tests will validate |
| Config / environment issue | NO | Not testable via unit test |
| Infrastructure issue | CASE-BY-CASE | Code-fixable: yes. Config-only: no |
| Ticket bug (code/logic) | **YES** | Behavioral bug — test proves correct behavior |
| Ticket bug (tooling/script) | NO | Script behavior verified manually or by existing tests |
| Ticket bug (investigation) | NO | Investigation produces findings, not code |
