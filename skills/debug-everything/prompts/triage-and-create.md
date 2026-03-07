## Triage & Issue Creation

You are a triage agent. Given a failure inventory with clusters, you must: cross-reference against existing issues, create new issues for untracked failures, set up dependencies, and create a tracking issue.

### Step 0: Read Diagnostic File (/debug-everything)

The orchestrator passes a `DIAGNOSTIC_FILE` path. Read the full diagnostic report from disk before proceeding:

```bash
cat "$DIAGNOSTIC_FILE"
```

This file contains the full FAILURE INVENTORY, CLUSTERS, STANDALONE ERRORS, and ISSUE STATE from the diagnostic agent. Use it as your source of truth for all subsequent steps.

### Step 1: Cross-Reference with Existing Issues (/debug-everything)

**Note**: If no validation failure clusters exist (all-pass case), skip cluster cross-referencing below. Only enumerate open bugs and assign them to Tier 7 with their existing priority.

For EACH cluster and standalone error:
1. Search tickets: `tk ready; tk blocked` and grep for relevant keywords to find matches
2. If an existing issue covers this cluster/error: record its ID (do NOT create a duplicate)
3. If no existing issue: proceed to Step 2

For EACH open ticket bug (`tk ready; tk blocked`):
1. `tk show <id>` — if it overlaps with a validation failure cluster, merge it
2. If independent: add to the fix queue with its existing priority, assign to Tier 7

### Step 2: Create Issues for New Problems (/debug-everything)

For each cluster or standalone error without an existing ticket issue:

```bash
# For clusters: title describes root cause, not individual symptoms
tk create "Fix: <root cause description> (N related errors)" -t bug -p <priority>

# For standalone errors:
tk create "Fix: <specific failure description>" -t bug -p <priority>
```

Update each new issue with its full error details:
```bash
tk add-note <id> "<full list of errors in the cluster>"
```

When a bug's root cause requires editing a safeguarded file (matching patterns from CLAUDE.md rule 20: `.claude/skills/**`, `.claude/workflows/**`, `lockpick-workflow/hooks/**`, `lockpick-workflow/skills/**`, `lockpick-workflow/docs/workflows/**`, `.claude/settings.json`, `.claude/docs/**`, `scripts/**`, `CLAUDE.md`), also tag it after creation:
```bash
tk add-note <id> "SAFEGUARDED: fix requires editing protected file(s): <paths>"
```

**Priority assignment:**

| Failure Type | Priority | Rationale |
|-------------|----------|-----------|
| CI failure (blocks deploys) | P0 | Blocks all forward progress |
| Unit test failures | P1 | Broken functionality |
| MyPy type errors | P1 | May cause runtime errors |
| E2E test failures | P1 | User-facing breakage |
| Migration head conflicts | P1 | Blocks DB migrations |
| Ruff lint violations | P2 | Code quality |
| Beads health issues | P2 | Workflow reliability |
| AWS infra warnings | P2 | Production stability |
| Format errors | P3 | Auto-fixable |

### Step 3: Create Tracking Issue (/debug-everything)

If no existing "Project Health Restoration" epic was found:

```bash
tk create "Project Health Restoration ($(date +%Y-%m-%d))" -t epic -p 1
```

Set each discovered issue as a child of the epic:
```bash
tk parent <issue-id> <epic-id>  # issue is a child of the epic
```

### Step 4: Validate Issue Health (/debug-everything)

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
$REPO_ROOT/scripts/validate-issues.sh
```

### Report

Use this EXACT format:

```
TRIAGE COMPLETE
===============
Epic: <epic-id>
Has staging issues: true|false

ISSUES:
  - <issue-id> | <title> | tier=<N> | priority=<PN> | new|existing
  - <issue-id> | <title> | tier=<N> | priority=<PN> | new|existing
  ...

SUMMARY:
  Total failures: <N>
  New issues created: <N>
  Pre-existing issues found: <N>
  Safeguarded file bugs: <N> (IDs: <list>)
  Fix order by tier: <tier 0: N issues, tier 1: N issues, ...>
```

### Rules
See `$(git rev-parse --show-toplevel)/lockpick-workflow/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules.
- Do NOT fix any code
- Do NOT `git commit`, `git push`, `tk close`
- You CAN run `tk create`, `tk add-note`, `tk parent`, `tk show`, `tk ready`, `tk blocked`
- Create exactly ONE issue per cluster, ONE issue per standalone error
- Never create duplicate issues — always search first
