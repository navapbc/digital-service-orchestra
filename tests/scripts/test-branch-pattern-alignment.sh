#!/usr/bin/env bash
# tests/scripts/test-branch-pattern-alignment.sh
#
# R7a (PR-2): Asserts that the branch patterns in the source-of-truth file
# (${CLAUDE_PLUGIN_ROOT}/config/sub-pr-branch-patterns.txt) stay aligned
# across the two consumers:
#
#   1. llm-review-dispatch-or-skip.sh — reads the patterns file at runtime to
#      build the _FORCE_REVIEW branch regex. We verify it references the
#      patterns file path.
#
#   2. provision-ruleset.sh — emits patterns (prefixed with "refs/heads/")
#      into the "DSO Sub-PR Review Enforcement" ruleset payload. We verify
#      every pattern in the source-of-truth file appears in the script.
#
# Without alignment, sub-agent branches matching new patterns could silently
# bypass review-sub-pr enforcement (the ruleset would not require the check
# for those branches; the dispatcher would not force-review them at
# session→main). This test is the deterministic regression guard.
#
# Usage: bash tests/scripts/test-branch-pattern-alignment.sh
# Returns: exit 0 if all assertions hold, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATTERNS_FILE="$REPO_ROOT/plugins/dso/config/sub-pr-branch-patterns.txt"
DISPATCHER="$REPO_ROOT/plugins/dso/scripts/llm-review-dispatch-or-skip.sh"
PROVISIONER="$REPO_ROOT/plugins/dso/scripts/onboarding/provision-ruleset.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-branch-pattern-alignment.sh ==="

# ── Test 1: patterns file exists with non-comment entries ─────────────────────
_snapshot_fail
patterns_file_present="no"
if [[ -f "$PATTERNS_FILE" ]]; then
    pattern_count=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "$PATTERNS_FILE" 2>/dev/null || echo 0)
    if (( pattern_count > 0 )); then
        patterns_file_present="yes"
    fi
fi
assert_eq "test_patterns_file_exists_with_entries: source-of-truth file present with patterns" \
    "yes" "$patterns_file_present"
assert_pass_if_clean "test_patterns_file_exists_with_entries"

# Read the active patterns (non-comment, non-blank lines) into an array
patterns=()
while IFS= read -r _line; do
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [[ -z "$_line" || "$_line" == \#* ]] && continue
    patterns+=("$_line")
done < "$PATTERNS_FILE"

# ── Test 2: dispatcher references the patterns file ───────────────────────────
# The dispatcher must READ the file at runtime (not hardcode patterns).
_snapshot_fail
dispatcher_reads_file="no"
if grep -qF 'sub-pr-branch-patterns.txt' "$DISPATCHER" 2>/dev/null; then
    dispatcher_reads_file="yes"
fi
assert_eq "test_dispatcher_references_patterns_file: dispatcher reads source-of-truth file" \
    "yes" "$dispatcher_reads_file"
assert_pass_if_clean "test_dispatcher_references_patterns_file"

# ── Test 3: provisioner references the patterns file ─────────────────────────
# The provisioner must READ the file at runtime to build its ruleset payload.
_snapshot_fail
provisioner_reads_file="no"
if grep -qF 'sub-pr-branch-patterns.txt' "$PROVISIONER" 2>/dev/null; then
    provisioner_reads_file="yes"
fi
assert_eq "test_provisioner_references_patterns_file: provisioner reads source-of-truth file" \
    "yes" "$provisioner_reads_file"
assert_pass_if_clean "test_provisioner_references_patterns_file"

# ── Test 4: dry-run produces payload containing every pattern ─────────────────
# Behavioral test: run provision-ruleset.sh --dry-run and extract the
# sub-PR ruleset's include array. Assert every source-of-truth pattern
# (prefixed with refs/heads/) appears in the dry-run output.
_snapshot_fail
dryrun_output=$(DSO_DRY_RUN=1 bash "$PROVISIONER" 2>&1 || true)
all_in_payload="yes"
missing_from_payload=""
for p in "${patterns[@]}"; do
    expected="refs/heads/$p"
    if ! echo "$dryrun_output" | grep -qF "$expected"; then
        all_in_payload="no"
        missing_from_payload="${missing_from_payload}${p} "
    fi
done
if [[ "$all_in_payload" == "no" ]]; then
    echo "MISSING from dry-run payload: $missing_from_payload" >&2
fi
assert_eq "test_dryrun_payload_contains_all_patterns: every source-of-truth pattern in ruleset payload" \
    "yes" "$all_in_payload"
assert_pass_if_clean "test_dryrun_payload_contains_all_patterns"

# ── Test 5: dry-run payload doesn't emit patterns NOT in source-of-truth ──────
# Extract patterns from the sub-PR ruleset's include array in the dry-run
# output, then verify each is in the source-of-truth file.
#
# Approach: find the "DSO Sub-PR Review Enforcement" section and extract
# refs/heads/<pattern> entries.
_snapshot_fail
# Pull just the sub-PR payload portion (between "Session-branch ruleset" header
# and the next "--- " line).
subpr_section=$(echo "$dryrun_output" | awk '/Session-branch ruleset/,/^---/')
unexpected_patterns=""
while IFS= read -r _candidate; do
    [[ -z "$_candidate" ]] && continue
    _found="no"
    for p in "${patterns[@]}"; do
        if [[ "$_candidate" == "$p" ]]; then
            _found="yes"
            break
        fi
    done
    if [[ "$_found" == "no" ]]; then
        unexpected_patterns="${unexpected_patterns}${_candidate} "
    fi
done < <(echo "$subpr_section" | grep -oE 'refs/heads/[^"]+' | sed 's|refs/heads/||' | sort -u)

drift_check="yes"
if [[ -n "$unexpected_patterns" ]]; then
    echo "Patterns in dry-run payload but NOT in source-of-truth file: $unexpected_patterns" >&2
    drift_check="no"
fi
assert_eq "test_no_drift_in_dryrun_payload: every ruleset pattern is also in source-of-truth" \
    "yes" "$drift_check"
assert_pass_if_clean "test_no_drift_in_dryrun_payload"

print_summary
