# Overlay Calibration Baselines

Generated: 2026-03-28 21:41 UTC
Branch: `worktree-20260328-102526`
Commits analyzed: 20 (limit: 20)

## Summary Statistics

| Metric | Count | Rate |
|--------|-------|------|
| Total commits analyzed | 20 | 100% |
| Security overlay triggered | 5 | 25.0% |
| Performance overlay triggered | 8 | 40.0% |
| Both overlays triggered | 4 | 20.0% |

## Security Overlay

### Top directory patterns

  - `plugins` (23 files)
  - `tests` (3 files)
  - `.test-index` (3 files)
  - `llm-debugging-research.md` (1 files)
  - `llm-debugging-agent.md` (1 files)
  - `CHANGELOG.md` (1 files)

### Files that triggered security overlay (unique, top 20)

  - `.test-index`
  - `CHANGELOG.md`
  - `llm-debugging-agent.md`
  - `llm-debugging-research.md`
  - `plugins/dso/agents/code-reviewer-deep-arch.md`
  - `plugins/dso/agents/code-reviewer-deep-correctness.md`
  - `plugins/dso/agents/code-reviewer-deep-hygiene.md`
  - `plugins/dso/agents/code-reviewer-deep-verification.md`
  - `plugins/dso/agents/code-reviewer-light.md`
  - `plugins/dso/agents/code-reviewer-performance.md`
  - `plugins/dso/agents/code-reviewer-security-red-team.md`
  - `plugins/dso/agents/code-reviewer-standard.md`
  - `plugins/dso/docs/contracts/security-red-team-output.md`
  - `plugins/dso/docs/designs/test-failure-subagent-strategy.md`
  - `plugins/dso/docs/SUB-AGENT-BOUNDARIES.md`
  - `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md`
  - `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-arch.md`
  - `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-correctness.md`
  - `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-hygiene.md`
  - `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-verification.md`

## Performance Overlay

### Top directory patterns

  - `plugins` (32 files)
  - `.test-index` (3 files)
  - `tests` (2 files)
  - `llm-debugging-research.md` (1 files)
  - `llm-debugging-agent.md` (1 files)
  - `CHANGELOG.md` (1 files)

### Files that triggered performance overlay (unique, top 20)

  - `.test-index`
  - `CHANGELOG.md`
  - `llm-debugging-agent.md`
  - `llm-debugging-research.md`
  - `plugins/dso/agents/code-reviewer-deep-arch.md`
  - `plugins/dso/agents/code-reviewer-deep-correctness.md`
  - `plugins/dso/agents/code-reviewer-deep-hygiene.md`
  - `plugins/dso/agents/code-reviewer-deep-verification.md`
  - `plugins/dso/agents/code-reviewer-light.md`
  - `plugins/dso/agents/code-reviewer-performance.md`
  - `plugins/dso/agents/code-reviewer-security-blue-team.md`
  - `plugins/dso/agents/code-reviewer-security-red-team.md`
  - `plugins/dso/agents/code-reviewer-standard.md`
  - `plugins/dso/docs/contracts/security-red-team-output.md`
  - `plugins/dso/docs/designs/test-failure-subagent-strategy.md`
  - `plugins/dso/docs/SUB-AGENT-BOUNDARIES.md`
  - `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md`
  - `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-arch.md`
  - `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-correctness.md`
  - `plugins/dso/docs/workflows/prompts/reviewer-delta-deep-hygiene.md`

## Per-Commit Detail

| SHA | Subject | Security | Performance | Tier |
|-----|---------|----------|-------------|------|
| `9381a98e` | docs(dso-5ooy): add overlay dispatch Step 4b to REVIEW-WO... | no | no | standard |
| `ea8043a4` | feat(dso-5ooy): implement overlay dispatch logic and reso... | no | no | standard |
| `035c8a90` | test(dso-5ooy): add RED tests for overlay dispatch and re... | no | no | light |
| `09765452` | feat(dso-5ooy): implement security-blue-team reviewer del... | no | yes | standard |
| `01225760` | test(dso-5ooy): add RED tests for security-blue-team agen... | no | no | light |
| `0868f6d8` | docs(dso-5ooy): update classifier-tier-output contract wi... | no | no | light |
| `6a86b587` | feat(dso-5ooy): implement performance_overlay detection i... | no | no | standard |
| `aba75828` | test(dso-5ooy): add RED performance_overlay tests and sec... | yes | yes | light |
| `a06e8c4e` | feat(dso-5ooy): implement security/performance overlay cl... | yes | yes | standard |
| `ba861337` | test(dso-5ooy): add RED tests for security/performance ov... | yes | no | light |
| `4581b763` | test(dso-l2ct): update batch title display tests for phas... | no | no | standard |
| `9bb2b993` | Merge remote-tracking branch 'origin/main' into worktree-... | no | no | standard |
| `cf2c7c51` | test(dso-l2ct): update batch title display tests for phas... | no | no | light |
| `625c6b14` | docs(dso-l2ct): update project docs for sprint phase renu... | yes | yes | standard |
| `b273b6a9` | refactor(dso-l2ct): convert model selection to decision t... | no | yes | standard |
| `4ec920a5` | refactor(dso-l2ct): merge Phase 3+4 into single batch-pre... | no | yes | standard |
| `4af34287` | llm debugging research | yes | yes | light |
| `cfbd3894` | refactor(dso-l2ct): prune explanatory prose and remove Ta... | no | yes | standard |
| `23cbd445` | fix: resolve 10 bugs across hooks, scripts, skills, and t... | no | no | standard |
| `7790446d` | fix: resolve 10 bugs across hooks, scripts, skills, and t... | no | no | standard |


## Interpretation Notes

- **Security overlay** triggers when changed files match `*/auth/*`, `*/security/*`,
  `*/crypto/*`, `*/encryption/*`, `*/session/*`, `*/oauth/*`, or when added lines
  contain security-sensitive imports/keywords (password, secret, token, credential,
  certificate, cryptography imports).
- **Performance overlay** triggers when changed files match `*/db/*`, `*/database/*`,
  `*/cache/*`, `*/query/*`, `*/pool/*`, `*/persistence/*`, or when added lines
  contain SQL/async/concurrency keywords (SELECT, INSERT, UPDATE, DELETE, cursor,
  pool, async def, await, threading, multiprocessing).
- Trigger rates above 30% suggest the overlay patterns are well-calibrated for
  this codebase. Rates below 5% may indicate the patterns don't match the
  project's naming conventions.

## How to Refresh

```bash
bash plugins/dso/scripts/run-overlay-retrospective.sh --limit 20
```
