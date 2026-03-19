---
id: dso-7plu
status: closed
deps: [dso-s3g4]
links: []
created: 2026-03-19T06:04:58Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-slh5
---
# GREEN: Create plugins/dso/skills/fix-bug/prompts/cluster-investigation.md

## Description

Create `plugins/dso/skills/fix-bug/prompts/cluster-investigation.md` — the investigation prompt template for the cluster mode. This template is dispatched when `dso:fix-bug` is invoked with multiple bug IDs and all must be investigated as a single problem.

**File to create**: `plugins/dso/skills/fix-bug/prompts/cluster-investigation.md`

**Required content**:

1. **Header/role** — "You are a bug cluster investigator. Your task is to investigate multiple related bugs as a single problem and identify whether they share a common root cause or have independent root causes."
2. **Context slots**:
   - `{ticket_ids}` — comma-separated list of bug ticket IDs in the cluster
   - `{failing_tests}` — combined failing test output for all bugs
   - `{stack_traces}` — stack traces extracted from all bug reports
   - `{commit_history}` — recent commit history for affected files
   - `{prior_fix_attempts}` — any prior fix attempt records from all tickets
3. **Investigation instructions** — investigate all bugs as a single problem; look for a shared root cause before concluding there are independent causes
4. **Splitting logic** — if and only if investigation reveals multiple independent root causes, split findings into per-root-cause tracks; each track follows the standard RESULT schema
5. **RESULT schema** — either a unified RESULT (single root cause) or an array of RESULT objects (one per independent root cause), each conforming to the Investigation RESULT Report Schema from SKILL.md
6. **Rules section** — do NOT modify source files; do NOT implement fixes; investigation only

**Composability note**: Follow the same structural pattern as `basic-investigation.md` (Context block → Investigation Instructions → RESULT). This prompt is composable — shared base elements with the basic template.

**TDD Requirement**: The RED tests in `dso-s3g4` must already be failing before this task runs. After creating the file, run `python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigationPrompt -v` and confirm all 5 tests PASS (GREEN).

**Implementation steps**:
1. Create `plugins/dso/skills/fix-bug/prompts/cluster-investigation.md`
2. Populate with required sections above
3. Run `python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigationPrompt -v` — all 5 tests must PASS

## ACCEPTANCE CRITERIA

- [ ] `python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigationPrompt` exits zero (all RED tests now GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigationPrompt
- [ ] Prompt file exists at `plugins/dso/skills/fix-bug/prompts/cluster-investigation.md`
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/cluster-investigation.md
- [ ] Prompt contains `{ticket_ids}` slot
  Verify: grep -q '{ticket_ids}' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/cluster-investigation.md
- [ ] Prompt contains single-problem investigation instruction
  Verify: grep -qi 'single problem' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/cluster-investigation.md
- [ ] Prompt contains split/independent root cause instruction
  Verify: grep -qi 'independent root cause\|per-root-cause\|split' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/cluster-investigation.md
- [ ] Prompt contains RESULT schema reference
  Verify: grep -q 'RESULT' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/cluster-investigation.md
- [ ] `ruff check` passes (no lint violations in skill files)
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/check-skill-refs.sh
