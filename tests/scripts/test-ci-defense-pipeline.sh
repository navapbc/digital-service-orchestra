#!/usr/bin/env bash
# tests/scripts/test-ci-defense-pipeline.sh
# Structural workflow test for the CI defense-suppression pipeline.
#
# Bug cluster [ee3a-43fc, b2ef-cd72, 9e84-2b78, d565-805a, a2e9-4227] RC-A:
#   1. .github/workflows/*.yml never exported DSO_REVIEW_CYCLE, so the
#      cycle_number gate at runner.py:789 always evaluated to 1, disabling
#      every cycle>=2 suppression branch (runner.py:843, 894, 922).
#   2. ci.yml invoked mirror-defenses-to-pr.sh with no stdin producer, so the
#      script's `while read -r line` loop received zero input — no DEFENSE_RECORD
#      lines were ever mirrored to PR comments, leaving _fetch_pr_defenses() in
#      runner.py empty on every subsequent cycle.
#
# This test enforces the structural shape of the fix bundle (F1 + F2). It is
# intentionally a YAML/grep check, not a runtime test — the goal is to prevent
# a regression where the wiring is silently removed again.
#
# Usage: bash tests/scripts/test-ci-defense-pipeline.sh
# Returns: exit 0 if all assertions pass, exit 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
DEFENSE_STORE_SH="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ci-defense-pipeline.sh ==="

# ── Preconditions ─────────────────────────────────────────────────────────────
_snapshot_fail
[[ -f "$CI_YML" ]] || { echo "FAIL: missing $CI_YML" >&2; (( ++FAIL )); }
[[ -f "$DEFENSE_STORE_SH" ]] || { echo "FAIL: missing $DEFENSE_STORE_SH" >&2; (( ++FAIL )); }
assert_pass_if_clean "preconditions: required files exist"

# ── test_ci_yml_exports_dso_review_cycle ──────────────────────────────────────
# F2: ci.yml must export DSO_REVIEW_CYCLE somewhere in the llm-review job so
# runner.py:789 sees the real cycle number. The export may live either in a
# preceding step's run: block (writing to $GITHUB_ENV) or in the env: block
# of the "Run LLM review" step. We check both shapes.
echo ""
echo "--- test_ci_yml_exports_dso_review_cycle ---"
_snapshot_fail

ci_check_exit=0
ci_check_output=""
ci_check_output=$(python3 - "$CI_YML" <<'PYEOF' 2>&1
import sys, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

job = doc.get('jobs', {}).get('llm-review', {})
if not job:
    print("MISSING: llm-review job not found")
    sys.exit(1)

steps = job.get('steps', [])
found_via_env = False
found_via_github_env_write = False
for s in steps:
    env = s.get('env') or {}
    if 'DSO_REVIEW_CYCLE' in env:
        found_via_env = True
    run = s.get('run') or ''
    # Look for a write to $GITHUB_ENV that sets DSO_REVIEW_CYCLE
    if 'DSO_REVIEW_CYCLE' in run and 'GITHUB_ENV' in run:
        found_via_github_env_write = True

if not (found_via_env or found_via_github_env_write):
    print("MISSING: no step in llm-review job exports DSO_REVIEW_CYCLE "
          "(neither in step env nor via $GITHUB_ENV write)")
    sys.exit(1)
print("OK")
PYEOF
) || ci_check_exit=$?

assert_eq "ci.yml llm-review exports DSO_REVIEW_CYCLE (exit code)" "0" "$ci_check_exit"
assert_eq "ci.yml llm-review exports DSO_REVIEW_CYCLE (output)" "OK" "$ci_check_output"
assert_pass_if_clean "test_ci_yml_exports_dso_review_cycle"

# test_per_branch_review_exports_dso_review_cycle: test removed; restoration
# covered by remediation epic (per-branch-review.yml was deleted in story 20d7-09d6-b831-4c3a).

# ── test_mirror_defenses_step_has_stdin_producer ──────────────────────────────
# F1: The mirror-defenses-to-pr step in ci.yml must pipe data INTO the script,
# not invoke it bare. We accept either:
#   <producer> | bash plugins/dso/scripts/mirror-defenses-to-pr.sh ...
#   bash plugins/dso/scripts/mirror-defenses-to-pr.sh ... < <some-file>
echo ""
echo "--- test_mirror_defenses_step_has_stdin_producer ---"
_snapshot_fail

mirror_check_exit=0
mirror_check_output=""
mirror_check_output=$(python3 - "$CI_YML" <<'PYEOF' 2>&1
import sys, yaml, re

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

job = doc.get('jobs', {}).get('mirror-defenses-to-pr', {})
if not job:
    print("MISSING: mirror-defenses-to-pr job not found")
    sys.exit(1)

# Find the run: step that invokes mirror-defenses-to-pr.sh
target_run = None
for s in job.get('steps', []) or []:
    run = s.get('run') or ''
    if 'mirror-defenses-to-pr.sh' in run:
        target_run = run
        break

if target_run is None:
    print("MISSING: no step invokes mirror-defenses-to-pr.sh")
    sys.exit(1)

# Accept either a pipe immediately before the script invocation, or a stdin
# redirect from a file. Multi-line YAML run: blocks include both forms.
# Pipe pattern: '... |\s*\\?\s*\n?\s*bash .* mirror-defenses-to-pr.sh' or '... | bash .* mirror-defenses-to-pr.sh'.
pipe_pattern = re.compile(r'\|\s*\\?\s*\n?\s*bash\s+[^\n]*mirror-defenses-to-pr\.sh', re.MULTILINE)
redirect_pattern = re.compile(r'mirror-defenses-to-pr\.sh[^\n]*<', re.MULTILINE)

if pipe_pattern.search(target_run):
    print("OK")
    sys.exit(0)
if redirect_pattern.search(target_run):
    print("OK")
    sys.exit(0)

# Report what we actually saw (truncated) so the failure is debuggable.
preview = target_run[:300].replace('\n', ' \\n ')
print(f"MISSING: mirror-defenses-to-pr.sh is invoked WITHOUT a stdin producer. "
      f"run block preview: {preview}")
sys.exit(1)
PYEOF
) || mirror_check_exit=$?

assert_eq "mirror-defenses step pipes input (exit code)" "0" "$mirror_check_exit"
assert_eq "mirror-defenses step pipes input (output)" "OK" "$mirror_check_output"
assert_pass_if_clean "test_mirror_defenses_step_has_stdin_producer"

# ── test_mirror_defenses_producer_is_deterministic_source ─────────────────────
# F1: The producer must reference a deterministic source so that defenses
# come from a known origin. Accept either:
#   - review-defense-store.sh (TrackerDefenseStore — list/dump subcommand)
#   - `git show tickets:<path>` (direct read from the tickets orphan branch)
echo ""
echo "--- test_mirror_defenses_producer_is_deterministic_source ---"
_snapshot_fail

producer_check_exit=0
producer_check_output=""
producer_check_output=$(python3 - "$CI_YML" <<'PYEOF' 2>&1
import sys, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

job = doc.get('jobs', {}).get('mirror-defenses-to-pr', {})
for s in job.get('steps', []) or []:
    run = s.get('run') or ''
    if 'mirror-defenses-to-pr.sh' not in run:
        continue
    if 'review-defense-store.sh' in run or 'git show tickets:' in run or 'git show tickets ' in run:
        print("OK")
        sys.exit(0)
    print("MISSING: mirror-defenses step does not reference a deterministic "
          "defense source (review-defense-store.sh or `git show tickets:...`)")
    sys.exit(1)

print("MISSING: no mirror-defenses-to-pr.sh run step found")
sys.exit(1)
PYEOF
) || producer_check_exit=$?

assert_eq "mirror-defenses producer references deterministic source (exit code)" "0" "$producer_check_exit"
assert_eq "mirror-defenses producer references deterministic source (output)" "OK" "$producer_check_output"
assert_pass_if_clean "test_mirror_defenses_producer_is_deterministic_source"

# ── test_review_defense_store_supports_list_subcommand ────────────────────────
# F1: review-defense-store.sh must support a CLI list/dump subcommand that
# emits DEFENSE_RECORD lines on stdout. The script is sourced as a library by
# other callers, so we only test the CLI dispatch behaviour here by inspecting
# the file for the subcommand handler. (A runtime test would require a fully
# initialised tickets tree, which is out of scope for this structural test.)
echo ""
echo "--- test_review_defense_store_supports_list_subcommand ---"
_snapshot_fail

# A list/dump subcommand handler is signalled by a case branch matching
# "list" or "dump" inside the script, OR by the script defining a function
# named *_list / *_dump / defense_store_list.
list_support_exit=0
# Strip comments before searching so a stray `list)` in a comment can't mask
# deletion of the real handler.
DEFENSE_STORE_SH_NOCOMMENTS=$(grep -v '^[[:space:]]*#' "$DEFENSE_STORE_SH")
if echo "$DEFENSE_STORE_SH_NOCOMMENTS" | grep -qE '(^|[^A-Za-z0-9_])(list|dump)\)' \
    || echo "$DEFENSE_STORE_SH_NOCOMMENTS" | grep -qE 'defense_store_(list|dump)'; then
    list_support_output="OK"
else
    list_support_output="MISSING: review-defense-store.sh has no list/dump CLI handler"
    list_support_exit=1
fi

assert_eq "review-defense-store.sh has list/dump support (exit code)" "0" "$list_support_exit"
assert_eq "review-defense-store.sh has list/dump support (output)" "OK" "$list_support_output"
assert_pass_if_clean "test_review_defense_store_supports_list_subcommand"

# ── test_list_requires_pr_filter ──────────────────────────────────────────────
# Regression guard: `list` without --pr must refuse to emit anything (exit 2).
# This is the safety check that prevents cross-PR comment pollution — without
# it, the mirror step would dump every historical DEFENSE_RECORD into every PR.
echo ""
echo "--- test_list_requires_pr_filter ---"
_snapshot_fail

set +e
LIST_OUTPUT=$(bash "$DEFENSE_STORE_SH" list 2>&1 >/dev/null)
LIST_EXIT=$?
set -e

assert_eq "list without --pr exits 2 (refuses to emit)" "2" "$LIST_EXIT"
if echo "$LIST_OUTPUT" | grep -qF -- '--pr <pr_number> is required'; then
    pr_required_msg_ok=1
else
    pr_required_msg_ok=0
fi
assert_eq "list without --pr emits the '--pr required' message" "1" "$pr_required_msg_ok"

# Also assert ci.yml passes --pr to the list invocation (already covered by
# test_mirror_defenses_step_has_stdin_producer, but make the contract explicit).
if grep -qE 'review-defense-store\.sh[[:space:]]+list[[:space:]]+--pr' "$CI_YML"; then
    ci_passes_pr=1
else
    ci_passes_pr=0
fi
assert_eq "ci.yml mirror step passes --pr to defense_store_list" "1" "$ci_passes_pr"

assert_pass_if_clean "test_list_requires_pr_filter"

# ── test_ci_cycle_counter_queries_review_thread_comments ─────────────────────
# Bug 59e3-8b8b fix regression: _post_pr_review now posts findings via the Pulls
# Reviews API (gh api -X POST .../pulls/N/reviews), which creates PR review-thread
# comments. These are NOT returned by `gh pr view --json comments` (issue-level
# comments only). The ci.yml Compute DSO_REVIEW_CYCLE step must also query PR
# review-thread comments (/repos/.../pulls/N/comments) so cycle detection works
# when the primary posting path is used.
echo ""
echo "--- test_ci_cycle_counter_queries_review_thread_comments ---"
_snapshot_fail

cycle_check_exit=0
cycle_check_output=""
cycle_check_output=$(python3 - "$CI_YML" <<'PYEOF' 2>&1
import sys, yaml, re

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

job = doc.get('jobs', {}).get('llm-review', {})
if not job:
    print("MISSING: llm-review job not found in ci.yml")
    sys.exit(1)

cycle_run = None
for s in job.get('steps', []) or []:
    run = s.get('run') or ''
    if 'DSO_REVIEW_CYCLE' in run and 'GITHUB_ENV' in run:
        cycle_run = run
        break

if cycle_run is None:
    print("MISSING: no step in llm-review computes and exports DSO_REVIEW_CYCLE")
    sys.exit(1)

# The step must query PR review-thread comments (/pulls/N/comments endpoint)
# in addition to (or instead of) issue comments, since findings are now posted
# via the Pulls Reviews API which creates review-thread comments.
# Accept any of these patterns that prove the step reads review-thread comments:
#   gh api .../pulls/*/comments
#   gh pr view ... --json reviews
#   gh pr view ... --json reviewThreads
review_comment_patterns = [
    re.compile(r'pulls/[^/\s]+/comments', re.IGNORECASE),
    re.compile(r'--json\s+reviews\b', re.IGNORECASE),
    re.compile(r'--json\s+reviewThreads\b', re.IGNORECASE),
]

if any(p.search(cycle_run) for p in review_comment_patterns):
    print("OK")
    sys.exit(0)

preview = cycle_run[:400].replace('\n', ' \\n ')
print(f"MISSING: Compute DSO_REVIEW_CYCLE step does not query PR review-thread "
      f"comments. Findings are now posted via the Pulls Reviews API, so "
      f"--json comments misses them. Add a /pulls/N/comments query to count "
      f"review-thread-based findings. Step preview: {preview}")
sys.exit(1)
PYEOF
) || cycle_check_exit=$?

assert_eq "ci.yml cycle counter queries PR review-thread comments (exit code)" "0" "$cycle_check_exit"
assert_eq "ci.yml cycle counter queries PR review-thread comments (output)" "OK" "$cycle_check_output"
assert_pass_if_clean "test_ci_cycle_counter_queries_review_thread_comments"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
