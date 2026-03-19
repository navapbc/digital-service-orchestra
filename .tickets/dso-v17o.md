---
id: dso-v17o
status: open
deps: [dso-12ap]
links: []
created: 2026-03-19T06:04:57Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-slh5
---
# GREEN: Add cluster investigation mode to SKILL.md

## Description

Update `plugins/dso/skills/fix-bug/SKILL.md` to add the cluster investigation mode so that `TestClusterInvestigation` tests turn GREEN. This adds a new section describing:

1. **Cluster invocation interface** — how to invoke `dso:fix-bug` with multiple bug IDs (e.g., `/dso:fix-bug <id1> <id2> ...` or `/dso:fix-bug --cluster <id1> <id2>`)
2. **Cluster-to-single-problem investigation logic** — investigates all bugs as a single problem; dispatches a single investigation sub-agent (at the tier determined by the highest-scoring bug) with all bug contexts
3. **Root-cause-based splitting** — after investigation, if a single root cause explains all bugs, proceeds as a single fix track; if multiple independent root causes are identified, splits into one per-root-cause track, each following the standard single-bug workflow from Step 3 onward
4. **Reference to `prompts/cluster-investigation.md`** — dispatch uses this template

**File to edit**: `plugins/dso/skills/fix-bug/SKILL.md`

**Where to add**: Add a new "## Cluster Investigation Mode" section before "## Investigation RESULT Report Schema". Also add a Usage section at the top noting the cluster invocation form.

**Cluster scoring rule**: Score is determined by the highest individual score across all bugs in the cluster (conservative — treats the cluster as the most complex bug it contains).

**TDD Requirement**: The RED tests in `dso-12ap` must already be failing before this task runs. After implementing, run `python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigation -v` and confirm all 4 tests PASS (GREEN).

**Implementation steps**:
1. Open `plugins/dso/skills/fix-bug/SKILL.md`
2. Add a Usage section near the top (after Config Resolution) showing cluster invocation syntax
3. Add a "## Cluster Investigation Mode" section with cluster logic
4. Add reference to `prompts/cluster-investigation.md`
5. Run `python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigation -v` — all 4 tests must PASS

**Constraint**: Change ONLY what is necessary. Do not modify existing sections unless required to reference the new cluster mode.

## ACCEPTANCE CRITERIA

- [ ] `python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigation` exits zero (all RED tests now GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigation
- [ ] SKILL.md contains "cluster" language (cluster invocation interface)
  Verify: grep -qi 'cluster' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] SKILL.md contains "single problem" investigation language
  Verify: grep -qi 'single problem' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] SKILL.md references `cluster-investigation.md`
  Verify: grep -q 'cluster-investigation.md' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] All pre-existing tests still pass (no regressions)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_fix_bug_skill.py -v
- [ ] `ruff check` passes (no skill-ref lint violations)
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/check-skill-refs.sh
- [ ] `ruff format --check` passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_fix_bug_skill.py
