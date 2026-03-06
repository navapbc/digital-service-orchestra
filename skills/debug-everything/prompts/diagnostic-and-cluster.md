## Full Diagnostic Scan & Failure Clustering

You are a diagnostic agent. Your job is to run ALL diagnostic checks, collect verbose error output, cluster related failures, and return a structured failure inventory. Do NOT fix anything.

### Step 1: Run Summary Diagnostics (/debug-everything)

**If the orchestrator appended "Validation Gate Results" context below**, the summary
diagnostics have already been run. Use the provided passing/failing categories instead
of re-running validate.sh. Skip to Step 2, only running checks for failing categories.

**Otherwise** (no validation gate context), run the full summary:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT/app

# Full validation — collects pass/fail per category
$REPO_ROOT/lockpick-workflow/scripts/validate.sh --full --ci 2>&1
```

**Bash timeout**: Use `timeout: 960000` (16 minutes). The smart CI wait can poll for up to 15 minutes.

### Step 2: Collect Verbose Error Output (/debug-everything)

**If validation gate results were provided**: Only run verbose diagnostics for the
FAILING categories listed. Skip commands for passing categories entirely — report
them as count=0 in the failure inventory. This avoids redundant work since
validate.sh already confirmed they pass.

**Otherwise**: Run all commands below.

**Skip map** (orchestrator label → command to skip):
- `format` → `make format-check`
- `ruff` → `make lint-ruff`
- `mypy` → `make lint-mypy`
- `tests` → `make test-unit-only`
- `e2e` → `make test-e2e`
- `migrate` → migration heads check (always run — no separate skip command)
- `docker` → not applicable (early-exit path only, never in normal `failed_checks`)
- `ci` → not a local command (checked via `gh` in Step 3, not here)

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT/app

# Format errors — which files need formatting (skip if "format" passed)
make format-check 2>&1

# Ruff lint — specific rule violations with file:line (skip if "ruff" passed)
make lint-ruff 2>&1

# MyPy — specific type errors with file:line (skip if "mypy" passed)
make lint-mypy 2>&1

# Unit test failures — test names and tracebacks (skip if "tests" passed)
make test-unit-only args="-v --tb=short" 2>&1

# E2E test failures (skip if "e2e" passed)
make test-e2e args="-v --tb=short" 2>&1
```

### Step 3: Collect Beads & Git State (/debug-everything)

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)

# Existing ticket issues
tk ready
tk blocked

# Issue health
$REPO_ROOT/scripts/validate-issues.sh

# Git state
git status --short
git log --oneline -5
```

### Step 4: Cluster Related Failures (/debug-everything)

Group failures together when ANY of these conditions hold:

| Signal | Example | Likely Single Root Cause |
|--------|---------|--------------------------|
| Same file, multiple errors | 3 mypy errors + 2 ruff violations in `src/services/parser.py` | Bad refactor or merge in that file |
| Same module, cascading types | MyPy error in `types.py` + 5 test failures importing from that module | Type definition is wrong |
| Import chain | `ImportError` in test + mypy "Cannot find module" + ruff "unused import" | Missing or circular dependency |
| Same test fixture | 4 test failures all using `mock_pipeline` fixture | Fixture is broken or outdated |
| Same error pattern | 6 tests all fail with `AttributeError: 'NoneType' has no attribute 'content'` | Shared code path returns None unexpectedly |

**Clustering process:**
1. Group by file: all errors referencing the same source file
2. Group by module: errors referencing files in the same `src/<module>/` directory
3. Group by error pattern: errors with identical or near-identical messages
4. Group by dependency chain: if error A is in a file imported by files in errors B, C, D — A is likely root cause
5. Merge overlapping clusters: if two clusters share 50%+ of their errors, merge them

### Step 5: Report (/debug-everything)

Use this EXACT format:

```
FAILURE INVENTORY
=================
Category           | Count | Severity | Details
-------------------|-------|----------|---------
Format errors      |   N   | auto-fix | <list of files>
Ruff violations    |   N   | P2       | <rule IDs and counts>
MyPy type errors   |   N   | P1       | <error summaries>
Unit test failures |   N   | P1       | <test names>
E2E test failures  |   N   | P1       | <test names>
Migration heads    |   N   | P1       | <head count, should be 1>
Open bugs          |   N   | varies   | <issue IDs and titles>
Beads health       | P/F   | P2       | <issue summary>

CLUSTERS
========
CLUSTER 1: {short description}
  Root cause candidate: {file:line or "unknown"}
  Errors in cluster: {count}
  Categories spanned: {mypy, unit tests, etc.}
  Errors:
    - {error 1 summary}
    - {error 2 summary}

CLUSTER 2: ...

STANDALONE ERRORS
=================
  - {error summary — not part of any cluster}

BEADS STATE
===========
Open issues: {count} ({ids})
In-progress issues: {count} ({ids})
Blocked issues: {count} ({ids})
Open bugs: {count} ({ids and titles})
```

### Save Report to Disk (/debug-everything)

After producing the Step 5 report, write the FULL report to disk before returning:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
DIAG_FILE="$(get_artifacts_dir)/debug-diag.md"
mkdir -p "$(dirname "$DIAG_FILE")"
cat > "$DIAG_FILE" <<'DIAG_EOF'
<paste the full Step 5 report here>
DIAG_EOF
echo "DIAGNOSTIC_FILE: $DIAG_FILE"
```

**Return to the orchestrator ONLY:**
1. The line `DIAGNOSTIC_FILE: $(get_artifacts_dir)/debug-diag.md`
2. A ≤15-line summary: category counts + top-3 clusters (each ≤1 line) + open bugs count

Do NOT return the full failure inventory table in your response. The orchestrator reads it from disk.

### Rules
See `$(git rev-parse --show-toplevel)/lockpick-workflow/docs/SUB-AGENT-BOUNDARIES.md` for full sub-agent rules.
- Do NOT fix anything — diagnostic only
- Do NOT `git commit`, `git push`, `tk close`, `tk status`
- Report ALL errors, even if they seem trivial
