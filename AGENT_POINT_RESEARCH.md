# AGENT_POINT_RESEARCH.md — Session Research Log

**Session**: 4eadd43a-ce61-435f-afd5-40bcfc367e94  
**Branch**: claude/agent-kudos-system-xeTRD  
**Date**: 2026-04-09  
**Topic**: Kudos System — Process Reward Model for AI coding agents

This file documents every research request made in this session, the steps taken, and the detailed findings.

---

## Research 1: Epic Scrutiny Pipeline — Gap Analysis & Web Research (Pre-Compaction)

### Context
The user asked to re-run the scrutiny pipeline on two Option A epics independently. The scrutiny pipeline (`plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md`) runs 4 steps: Gap Analysis → Web Research → Scenario Analysis → Fidelity Review.

### Research Steps (from prior session summary)

**Step 1 — Gap Analysis**:
The gap analysis agent reviewed the epic specs against the success criteria and identified:
- Missing: session identity mechanism (who writes .kudos/session-id)
- Missing: explicit fail-open behavior for absent tools
- Missing: jscpd file-output integration detail (stdout vs file)

**Step 2 — Web Research**:
Multiple web searches were performed on:

1. **sg (ast-grep) --json=stream behavior**
   - Query: "ast-grep sg --json=stream exit codes NDJSON"
   - **Result**: Exit code 0=no matches, 1=matches found confirmed. NDJSON schema fields: path, range, text, rule_id
   - Source: ast-grep CLI documentation

2. **ruff --stdin-filename with absolute path**
   - Query: "ruff check stdin-filename relative path pyproject.toml not found"
   - **Result**: Found GitHub issue #17405 — relative paths silently drop pyproject.toml config. Fix: use `$(pwd)/$f` absolute path
   - Source: https://github.com/astral-sh/ruff/issues/17405

3. **Python AST subtree hashing for duplicate detection**
   - Query: "Python AST subtree hashing duplicate code detection hashlib"
   - **Result**: `hashlib.sha256(ast.dump(node).encode())` is the correct pattern. `ast.walk` visits all nodes; for targeted subtree detection, filter by node type.
   - Source: Python 3 docs — ast.dump, hashlib

4. **jscpd output format**
   - Query: "jscpd JSON output file vs stdout reporters"
   - **Result**: jscpd does NOT write JSON to stdout with `--reporters json`. Correct pattern: `REPORT_DIR=$(mktemp -d) && jscpd --reporters json --output $REPORT_DIR <files> && cat $REPORT_DIR/jscpd-report.json`
   - This was a CRITICAL finding that invalidated the original T13 approach (stdout assumption)

5. **ast.NodeVisitor vs ast.walk for nesting depth**
   - Query: "Python ast.walk nesting depth counter ast.NodeVisitor"
   - **Result**: `ast.walk` does NOT track depth (flat traversal). `ast.NodeVisitor` with generic_visit override is correct for depth tracking. Pattern: increment counter in `visit_If`/`visit_For`/`visit_While`/`visit_With`/`visit_Try`, decrement after `generic_visit(node)`
   - Source: Python docs, discussion forum responses

6. **Process Reward Models for AI agents**
   - Query: "process reward model AI coding agents 2025 step-level feedback"
   - **Result**: 2025 research confirms step-level recognition reduces reasoning errors; immediate reward delivery is critical for behavioral linkage; design aligns with AgentPRM and PRIME findings
   - Source: Multiple academic sources

### Key Findings Summary
| Finding | Impact | Resolution |
|---------|--------|-----------|
| sg exit codes 0=no matches, 1=matches | T5/T11 implementation | Use in diff-to-sg-scope.sh |
| ruff #17405: relative path drops pyproject.toml | T9 implementation | Use absolute path `$(pwd)/$f` |
| jscpd writes to file not stdout | T13 fallback approach | mktemp + cat pattern |
| ast.walk doesn't track depth | T7 implementation | Use ast.NodeVisitor |
| jscpd absent from repo = new external dep | T13 risk | Spike S1 validates approach |

---

## Research 2: Feasibility Reviewer — Pass 1 (Pre-Compaction)

### Context
The feasibility reviewer agent (`dso:feasibility-reviewer`) was dispatched inline to evaluate Epic 1 technical feasibility and integration risk.

### Research Steps
The agent read the epic spec and evaluated 2 dimensions: `technical_feasibility` and `integration_risk`.

### Results (Pass 1)
- `technical_feasibility`: 2/5
- `integration_risk`: 2/5
- **Status**: FAIL (threshold is ≥4 on both)

**Findings**:
1. `ruff --stdin-filename` with relative path silently drops pyproject.toml rules (issue #17405)
2. `ast.walk` does not track nesting depth (T7 needs ast.NodeVisitor)
3. jscpd writes to file not stdout (T13 fallback incorrectly assumed stdout)

---

## Research 3: Feasibility Reviewer — Pass 2

### Context
After redesigning T7/T9/T13 based on Pass 1 findings, the feasibility reviewer was re-dispatched.

### Changes Made Before Pass 2
1. T9: Changed `--stdin-filename "$f"` to `--stdin-filename "$(pwd)/$f"` (absolute path)
2. T7: Changed `ast.walk` to `ast.NodeVisitor` with depth counter
3. T13: Changed jscpd stdout assumption to file-output pattern: `REPORT_DIR=$(mktemp -d) && jscpd --reporters json --output $REPORT_DIR <files> && cat $REPORT_DIR/jscpd-report.json`

### Results (Pass 2)
- `technical_feasibility`: 4/5
- `integration_risk`: 3/5
- **Status**: PARTIAL FAIL

**Remaining finding** (integration_risk=3):
1. ruff absolute path fix not yet in spec text
2. ast.NodeVisitor pattern not fully specified
3. jscpd file-output confirmation still incomplete

---

## Research 4: Feasibility Reviewer — Pass 3 (Targeted Inline Re-run)

### Context
Third pass targeted the 3 specific integration_risk=3 findings.

### Changes Made Before Pass 3
1. Verified ruff absolute path `$(pwd)/$f` explicitly in T9 spec text
2. Specified ast.NodeVisitor exact pattern: `visit_If/For/While/With/Try increment, generic_visit decrement`
3. Confirmed jscpd integration: `REPORT_DIR=$(mktemp -d) && jscpd --reporters json --output $REPORT_DIR <files> && cat $REPORT_DIR/jscpd-report.json` (file output, NOT stdout)

### Results (Pass 3)
- `technical_feasibility`: 4/5
- `integration_risk`: 4/5
- **Status**: PASS ✓
- **Findings**: Empty (no remaining findings)

---

## Research 5: Fidelity Review — Epic 1 (4 Reviewers in Parallel)

### Context
The fidelity review step dispatches 4 reviewers: Agent Clarity, Scope, Value Alignment, and Technical Feasibility. All dimensions must score ≥4.

### Research Steps
Four reviewer agents evaluated Epic 1 against the approved spec.

### Results
All 4 dimensions scored ≥4:
- Agent Clarity: 4/5
- Scope: 4/5
- Value Alignment: 5/5
- Technical Feasibility: 4/5 (after 3 feasibility passes)

**Status**: PASS ✓

Review JSON written to `/tmp/scrutiny-review-E1-5oew9w.json`

---

## Research 6: Fidelity Review — Epic 2 (3 Reviewers)

### Context
Epic 2 reviewed with 3 perspectives (no external integration requiring feasibility review).

### Results
All dimensions ≥4:
- Agent Clarity: 4/5
- Scope: 4/5
- Value Alignment: 5/5

**Status**: PASS ✓

---

## Research 7: Complexity Evaluation — Epic 1 (dso:complexity-evaluator)

### Context
After user approved both epic specs and said "proceed to complexity analysis on both," complexity evaluators were dispatched in parallel for both epics.

### Research Steps
The complexity-evaluator agent (haiku model, read inline from `plugins/dso/agents/complexity-evaluator.md`) applied the 8-dimension rubric to Epic 1.

### 8-Dimension Rubric Analysis for Epic 1

**Dimension 1 — Files**: 7+ files (commit-validate.sh, kudos-write-guard.sh, diff-to-sg-scope.sh, COMMIT-WORKFLOW.md, CLAUDE.md, dso-config.conf, integration test) → **COMPLEX signal (>3)**

**Dimension 2 — Layers**: Shell scripts (plugin scripts layer) + hooks layer + workflow/documentation layer + config layer = 3+ layers → **COMPLEX signal (≥3)**

**Dimension 3 — Interfaces**: New scripts (not modifying existing class/Protocol signatures) → **0 (neutral)**

**Dimension 4 — Scope Certainty**: SCs are extremely detailed with field names, formulas, file paths, exit codes, fallback conditions → **High**

**Dimension 5 — Confidence**: Files confirmed via Glob/Grep → **High**

**Dimension 6 — Blast Radius**: `blast-radius-score.py` returned `complex_override=true` (blast_radius_score=7) → **Forces COMPLEX**

**Dimension 7 — Pattern Familiarity**: PreToolUse write guard pattern exists (worktree-edit-guard.sh); JSONL ledger follows .review-events/ pattern; sg NDJSON parsing is new → **Medium**

**Dimension 8 — External Boundary Count**: sg (ast-grep) external CLI = 1 → **1**

**Epic Qualitative Overrides**:
- ✅ External integration: sg (ast-grep) is new external CLI tool with no existing usage in repo
- ✅ Success criteria overflow: 23 SCs > 6 threshold
- ✅ Single-concern failure: "infrastructure AND 10 triggers" = structural "and"

### Result
```json
{
  "classification": "COMPLEX",
  "confidence": "high",
  "files_estimated": [
    "plugins/dso/scripts/commit-validate.sh",
    "plugins/dso/hooks/tools/kudos-write-guard.sh",
    "plugins/dso/scripts/diff-to-sg-scope.sh",
    "plugins/dso/docs/workflows/COMMIT-WORKFLOW.md",
    "CLAUDE.md",
    ".claude/dso-config.conf",
    "tests/integration/test-kudos-t9-end-to-end.sh"
  ],
  "qualitative_overrides": ["success_criteria_overflow", "external_integration", "single_concern_fail"],
  "blast_radius_score": 7,
  "pattern_familiarity": "medium",
  "external_boundary_count": 1,
  "feasibility_review_recommended": true
}
```

---

## Research 8: Complexity Evaluation — Epic 2 (dso:complexity-evaluator)

### Research Steps
Applied 8-dimension rubric to Epic 2.

### 8-Dimension Rubric Analysis for Epic 2

**Dimension 1 — Files**: 6 files (kudos-snapshot.sh, completion-verifier.md, approach-decision-maker.md, doc-writer.md, using-lockpick/SKILL.md, worktree-create.sh) → **COMPLEX signal (>3)**

**Dimension 2 — Layers**: Skill/prompt/agent files = 0 architectural layers; plugin scripts = 0 architectural layers → **0 layers (SIMPLE signal)**

**Dimension 3 — Interfaces**: No public method signatures changed → **0 (neutral)**

**Dimension 4 — Scope Certainty**: Named file paths, exact behavior specs, measurable conditions → **High**

**Dimension 5 — Confidence**: All specific files confirmed via Glob → **High**

**Dimension 6 — Blast Radius**: `complex_override=false`, score=0 → **No forced escalation**

**Dimension 7 — Pattern Familiarity**: flock usage exists in 20+ files; JSON snapshot files have precedents; text additions to agent md files are common → **Medium** (T4 AST hashing novel)

**Dimension 8 — External Boundary Count**: No external APIs, reads local files only → **0**

**Epic Qualitative Overrides**:
- ✅ Success criteria overflow: 9 SCs > 6 threshold
- ✅ Single-concern failure: "snapshot triggers AND agent contract updates" = structural "and"

### Result
```json
{
  "classification": "COMPLEX",
  "confidence": "high",
  "files_estimated": [
    "plugins/dso/scripts/kudos-snapshot.sh",
    "plugins/dso/agents/completion-verifier.md",
    "plugins/dso/agents/approach-decision-maker.md",
    "plugins/dso/agents/doc-writer.md",
    "plugins/dso/skills/using-lockpick/SKILL.md",
    "plugins/dso/scripts/worktree-create.sh"
  ],
  "qualitative_overrides": ["success_criteria_overflow", "single_concern_failure"],
  "blast_radius_score": 0,
  "pattern_familiarity": "medium",
  "external_boundary_count": 0,
  "feasibility_review_recommended": false
}
```

---

## Research 9: Red Team Adversarial Review — Epic 1 Story Map

### Context
Phase 2.5 of `/dso:preplanning` for Epic 1. The dso:red-team-reviewer agent (opus model) attacked the drafted story map for cross-story blind spots, implicit assumptions, and interaction gaps.

### Story Map Submitted for Review

9 stories drafted for Epic 1:
- S0: Spike — validate sg --json=stream behavior
- S1: Spike — Python AST subtree hashing
- A: Core kudos ledger infrastructure (walking skeleton)
- B: diff-to-sg-scope.sh wrapper
- C: Shell triggers T6/T9/T12 + integration test
- D: Review workflow triggers T3/T14/T15
- E: sg-based structural triggers T5/T11
- F: AST-based complexity triggers T7/T13
- H: Documentation (CLAUDE.md Kudos section)

### Consumer Enumeration (Red Team Step)
The red team enumerated all consumers of systems being modified:
- `commit-validate.sh`: consumed by COMMIT-WORKFLOW.md, /dso:commit, /dso:sprint, /dso:fix-bug, /dso:debug-everything
- `COMMIT-WORKFLOW.md`: consumed by per-worktree-review-commit.md, merge-to-main.sh, all workflows
- `pre-edit-write-functions.sh` dispatcher: consumed by every Edit/Write tool call
- `reviewer-findings.json`: consumed by record-review.sh, review workflow (protected artifact)
- `.review-events/` JSONL: consumed by review stats, commit-validate.sh (T14/T15)
- `compute-diff-hash.sh`: consumed by pre-commit-review-gate.sh and pre-commit-test-gate.sh

### Findings by Category

**Critical (4)**:

1. **CSIG-1**: commit-validate.sh has no defined integration point in the existing pre-commit hook chain or COMMIT-WORKFLOW.md step ordering
   - Impact: All trigger stories depend on this but position in hook chain is unspecified
   - Recommendation: Specify exact COMMIT-WORKFLOW.md step position, timeout budget, compute-diff-hash.sh interaction

2. **CSIG-2**: kudos-write-guard.sh registration missing from consolidated PreToolUse dispatcher
   - Impact: Guard cannot function without registration in pre-edit-write-functions.sh
   - Recommendation: Specify dispatcher chain registration (6th function after existing 5)

3. **FMBS-1**: Concurrent writes to ledger.jsonl will corrupt file in shared-directory mode
   - Impact: Session ceiling check is a TOCTOU race; concurrent agents share ledger without protection
   - Recommendation: flock-based atomic writes

4. **CIA-1**: COMMIT-WORKFLOW.md is a safeguard file — modification impacts all workflows
   - Impact: merge-to-main.sh ticket-sync commits, per-worktree-review-commit.md, checkpoint auto-saves all need exclusion
   - Recommendation: Explicit cascade consumer exclusion list

**Important (11)**:

5. **CSIG-3**: T14 data source ambiguous — review-events JSONL only has aggregates, not individual finding events
   - Resolution: T14 should read reviewer-findings.json for finding presence + review-events for resubmission

6. **CSIG-4**: Session UUID producer ambiguous — SC-E1-7 says "at worktree creation" but SC-E1-6 says "first commit"
   - Resolution: Commit-validate.sh creates on first run (fail-open if absent)

7. **CSIG-5**: diff-to-sg-scope.sh output contract not specified for consumers (E and F)
   - Resolution: Formal contract with exit codes + NDJSON format + grep fallback format

8. **IA-1**: .kudos/ not in .gitignore causes review gate chicken-and-egg problem
   - Resolution: Pre-seed in .gitignore during development, not at runtime

9. **IA-2**: n=session-scoped not explicitly stated (could be cumulative)
   - Resolution: Explicit session-scope clarification

10. **IA-3**: T6 ticket timestamp resolution mechanism unspecified
    - Resolution: `dso ticket show <id>` + created_at parsing; fail-open when unresolvable

11. **IA-4**: T9 has no fail-open clause for missing/erroring ruff
    - Resolution: Explicit skip when ruff absent or fails with non-lint errors

12. **FMBS-3**: T12 "commented-out code" detection heuristic unspecified
    - Resolution: Regex pattern: `^\s*#\s*(def |class |import |...)`, 2+ consecutive lines

13. **FMBS-4**: T7 done-definition says "HAS >= 4 levels" — incentivizes writing complex code
    - Resolution: Must detect REDUCTION (removed diff hunks >= 4 AND resulting file has lower depth)

14. **FMBS-5**: commit-validate.sh timeout context not specified
    - Resolution: COMMIT-WORKFLOW.md step with timeout: 600000 (not pre-commit hook)

15. **TSG-1**: Integration test runs via git commit requires full hook chain setup
    - Resolution: Direct invocation of commit-validate.sh (not via git commit)

**Minor (3)**:
16. CIA-4: .kudos/** not in review-gate-allowlist.conf
17. SBV-3: grep fallback parity testing with sg not required
18. IA-5: Rank tier scope (session-scoped vs cumulative) not clarified

### Blue Team Filter Results

**22 accepted, 1 rejected**:
- Rejected: S0 fixture production (B can create its own fixtures)
- All 22 others accepted

**New story added**: CLAUDE.md prohibition block (P1) — must ship before any trigger is active. Prohibition rules cannot be P4 (Story H) if they govern system behavior from first trigger onward.

**Modified story map**: 10 stories (added PROHIBITION story, split from Story H)

---

## Research 10: Red Team Adversarial Review — Epic 2 Story Map

### Context
Phase 2.5 of `/dso:preplanning` for Epic 2. Currently running (agent ID: a56b6e456e8a67a50).

### Story Map Submitted for Review

6 stories drafted for Epic 2:
- J: kudos-snapshot.sh infrastructure (SC-E2-1, SC-E2-2)
- K: Snapshot-dependent triggers T1/T2 (SC-E2-3, SC-E2-4)
- L: T4 trigger — pre-session dedup reduction (SC-E2-5)
- M: Agent contract updates — completion-verifier, approach-decision-maker, doc-writer (SC-E2-6, SC-E2-7, SC-E2-8)
- N: SKILL.md kudos awareness — using-lockpick (SC-E2-9)
- H2: Documentation update

### Consumer Enumeration (submitted to red team)
- test-gate-status file: record-test-status.sh (write), pre-commit-test-gate.sh (read), kudos-snapshot.sh (new reader)
- completion-verifier.md: /dso:sprint Step 10a and Phase 7 Step 0.75
- approach-decision-maker.md: /dso:implementation-plan proposal resolution loop
- doc-writer.md: /dso:sprint doc stories, /dso:update-docs
- using-lockpick/SKILL.md: /dso:sprint and related orchestrators
- worktree-create.sh: /dso:sprint, /dso:fix-bug, /dso:debug-everything

### Results
**STATUS: In progress** (agent a56b6e456e8a67a50 running)

---

## Key Technical Decisions Made Based on Research

| Decision | Research Basis | Spec Impact |
|----------|---------------|-------------|
| T9: absolute path `$(pwd)/$f` | ruff issue #17405 | Prevents silent pyproject.toml config drop |
| T7: ast.NodeVisitor, not ast.walk | Python docs + discussion | Enables depth tracking (ast.walk is flat) |
| T13: AST hashing primary, jscpd file-output as fallback | Spike S1 approach | hashlib.sha256(ast.dump(node).encode()) |
| jscpd: file output, not stdout | Research finding | mktemp + cat pattern required |
| sg absence: `command -v sg`, not exit code | sg CLI docs | Exit code 127 ≠ "absent", use command -v |
| commit-validate.sh: COMMIT-WORKFLOW.md step, not pre-commit hook | Red team FMBS-5 + CSIG-1 | timeout: 600000 available; avoids hook timeout |
| .gitignore: pre-seeded in dev commit | Red team IA-1 | Avoids chicken-and-egg with review gate |
| ledger writes: flock atomic | Red team FMBS-1 | Prevents corruption in shared-directory mode |
| T7 done definition: detect REDUCTION not presence | Red team FMBS-4 | Prevents perverse incentive (adding complex code for kudos) |
| CLAUDE.md prohibition block: P1 priority | Red team SBV-1 + new story | Rules must exist before first trigger ships |
| T14 data source: reviewer-findings.json + review-events | Red team CSIG-3 | review-events JSONL has only aggregates, not individual events |
