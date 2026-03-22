---
id: dso-qzn4
status: in_progress
deps: [dso-ofdr, dso-qxyd, dso-2eu7]
links: []
created: 2026-03-22T15:16:39Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-jtkr
---
# Create review-complexity-classifier.sh with 7 scoring factors, floor rules, and behavioral file detection

Implement plugins/dso/scripts/review-complexity-classifier.sh. All tests from the RED task (dso-qxyd) must pass after this task.

## TDD Requirement

Failing tests are written in dso-qxyd (test-review-complexity-classifier.sh). Run those tests first to confirm RED, then implement, then confirm GREEN. Tests must pass: test_classifier_outputs_json_object, test_classifier_exits_zero_on_success, and all 18+ named tests.

## Implementation

### File
plugins/dso/scripts/review-complexity-classifier.sh

### Interface (from contract dso-ofdr)
Input: staged diff (same file set as compute-diff-hash.sh)
Output: JSON on stdout — fields: blast_radius, critical_path, anti_shortcut, staleness, cross_cutting, diff_lines, change_volume, computed_total, selected_tier
Exit: 0 on success; any non-zero default to standard tier by caller (REVIEW-WORKFLOW.md)

### Script header
#!/usr/bin/env bash
# plugins/dso/scripts/review-complexity-classifier.sh
# Deterministic complexity classifier for the DSO tiered review system.
# ...
set -euo pipefail

### 7 Scoring Factors (each capped at its maximum)
1. blast_radius: max import/usage count across changed source files (0-3 pts)
   - Count: grep -r 'import <filename>\|require <filename>\|source <filename>' in repo, take max across files
2. critical_path: touches persistence, auth, security, or request handling paths (0-3 pts)
   - Check: any changed file matches patterns for db/, auth/, security/, routes/, handlers/, request
3. anti_shortcut: count of noqa, type:ignore, pytest.mark.skip, tolerance-change patterns in diff (0-3 pts)
   - Check: grep each pattern in diff output, count occurrences (capped at 3)
4. staleness: max days since last substantive modification across changed files (0-2 pts)
   - Check: git log -1 --format=%ct <file> for each changed file
   - 0-30 days = 0 pts; 31-90 days = 1 pt; 91+ days = 2 pts
5. cross_cutting: distinct top-level directories touched (0-2 pts)
   - Count: unique top-level dirs in changed file list; 1 dir = 0 pts; 2 dirs = 1 pt; 3+ dirs = 2 pts
6. diff_lines: non-test, non-ticket lines added+modified (0-1 pt)
   - Count: diff lines in non-test, non-.tickets/ files; 1-49 = 0 pts; 50+ = 1 pt
7. change_volume: count of source + behavioral files changed (0-1 pt)
   - 1-4 files = 0 pts; 5+ files = 1 pt

### Floor Rules (each overrides computed score to minimum 3 = standard tier)
1. anti_shortcut floor: any noqa/type:ignore/skip pattern in diff → minimum score 3
2. critical_path floor: any file matched by critical_path patterns → minimum score 3
3. safeguard floor: any file in CLAUDE.md rule #20 list (plus classifier itself) → minimum score 3
4. test_deletion floor: test file deleted without corresponding source file deleted → minimum score 3
5. exception_broadening floor: 'catch Exception\|bare except' pattern in diff → minimum score 3

### Behavioral File Detection
- Read review.behavioral_patterns from dso-config.conf (semicolon-delimited glob list)
- Parse the value by splitting on `;` to build an array of glob patterns (e.g., IFS=';' read -ra BEHAVIORAL_PATTERNS <<< "$RAW_PATTERNS")
- For each changed file, iterate the BEHAVIORAL_PATTERNS array and test with case/glob matching
- Files matching behavioral patterns: scored with full weight (treated as source code)
- Files matching review-gate-allowlist.conf: exempt (score 0, skip)
- All other files: scored normally

### File Set
Same as compute-diff-hash.sh:
- git diff HEAD --name-only plus git ls-files --others --exclude-standard (untracked)
- Exclude patterns from review-gate-allowlist.conf
- Use the same checkpoint-aware diff base detection (read /pre-checkpoint-base if exists)

### Performance Requirement
Must complete in <2 seconds. Use efficient grep patterns; avoid per-file subshell invocations where possible.

### Exit 144 Handling
Script uses set -euo pipefail. Exit 144 (SIGURG) terminates the script — the caller (REVIEW-WORKFLOW.md) handles non-zero exit by defaulting to standard tier.

### Output
printf JSON object to stdout on success. No other output to stdout (stderr for debug messages).

## Implementation Steps

1. Write script header, set -euo pipefail, source deps.sh for get_artifacts_dir
2. Implement file set collection (same as compute-diff-hash.sh — use allowlist patterns)
3. Implement behavioral_patterns reading from read-config.sh
4. Implement each of the 7 scoring factors as functions
5. Implement floor rule evaluation (after all factors computed)
6. Compute computed_total = sum of all factor scores, then apply floor rules
7. Compute selected_tier from computed_total (0-2=light, 3-6=standard, 7+=deep)
8. Output JSON to stdout, exit 0

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/tests/run-all.sh"
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Classifier script exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/review-complexity-classifier.sh
- [ ] All unit tests in tests/hooks/test-review-complexity-classifier.sh pass (GREEN)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/tests/hooks/test-review-complexity-classifier.sh" 2>&1 | grep -q 'FAILED: 0'
- [ ] JSON output contains all required fields (7 factor scores + computed_total + selected_tier)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); required=['blast_radius','critical_path','anti_shortcut','staleness','cross_cutting','diff_lines','change_volume','computed_total','selected_tier']; missing=[k for k in required if k not in d]; exit(1 if missing else 0)"
- [ ] Script completes in under 2 seconds
  Verify: time REPO_ROOT=$(git rev-parse --show-toplevel) bash "$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh" 2>/dev/null | python3 -c "import sys; json.loads(sys.stdin.read())"
- [ ] Fuzzy match for test file is verified (no .test-index entry needed)
  Verify: echo 'testreviewcomplexityclassifiersh' | grep -q 'reviewcomplexityclassifiersh' && echo 'fuzzy-match-ok'


## Notes

**2026-03-22T15:41:32Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T15:41:59Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T15:42:11Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T15:46:29Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T15:46:33Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T16:41:59Z**

CHECKPOINT 6/6: Done ✓
