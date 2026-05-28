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
# Approach: parse JSON payloads from the dry-run output via jq. The dry-run
# emits two JSON ruleset payloads; the second one is the sub-PR ruleset. We
# isolate JSON blocks and find the one named "DSO Sub-PR Review Enforcement",
# then extract its include array. This avoids the previous awk-based section
# matching which would silently yield zero patterns (false pass) if the
# section header text changed.
_snapshot_fail
# Extract every well-formed JSON object from the dry-run output via Python
# (more robust than awk text matching). Find the one with the sub-PR ruleset
# name, then return its include array members.
sub_pr_patterns=$(echo "$dryrun_output" | python3 -c '
import sys, json, re
text = sys.stdin.read()
# Find all top-level JSON object start positions (lines starting with "{").
# For each candidate "{", attempt incremental JSON parse to find a complete object.
start_positions = [i for i, line in enumerate(text.split("\n")) if line.strip() == "{"]
lines = text.split("\n")
patterns = []
for start in start_positions:
    # Find matching closing brace by counting depth
    depth = 0
    for j in range(start, len(lines)):
        for ch in lines[j]:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    candidate = "\n".join(lines[start:j+1])
                    try:
                        obj = json.loads(candidate)
                        if isinstance(obj, dict) and obj.get("name") == "DSO Sub-PR Review Enforcement":
                            inc = obj.get("conditions", {}).get("ref_name", {}).get("include", [])
                            patterns.extend(p.replace("refs/heads/", "") for p in inc if isinstance(p, str))
                            print("\n".join(patterns))
                            sys.exit(0)
                    except json.JSONDecodeError:
                        pass
                    break
        if depth == 0 and j > start:
            break
' 2>/dev/null)

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
done <<< "$sub_pr_patterns"

# Drift-check robustness guard: extraction returned non-empty content (proving
# we actually parsed the sub-PR ruleset, not silently matching nothing).
extraction_worked="yes"
if [[ -z "$sub_pr_patterns" ]]; then
    extraction_worked="no"
    echo "ERROR: failed to extract sub-PR ruleset patterns from dry-run output" >&2
fi
assert_eq "test_no_drift_extraction_worked: sub-PR payload extracted from dry-run JSON" \
    "yes" "$extraction_worked"

drift_check="yes"
if [[ -n "$unexpected_patterns" ]]; then
    echo "Patterns in dry-run payload but NOT in source-of-truth file: $unexpected_patterns" >&2
    drift_check="no"
fi
assert_eq "test_no_drift_in_dryrun_payload: every ruleset pattern is also in source-of-truth" \
    "yes" "$drift_check"
assert_pass_if_clean "test_no_drift_in_dryrun_payload"

# ── Test 6: workflow trigger covers every source-of-truth pattern ─────────────
# GAP-1 hardening: the review-sub-pr.yml workflow's pull_request.branches
# trigger MUST include every pattern in the source-of-truth file. Otherwise
# PRs targeting branches matching only the file would never trigger
# review-sub-pr — but the GitHub ruleset (also derived from the file) would
# require the check to pass. Result: merge deadlock.
#
# Caught by the llm-review on PR #432 — adding this assertion prevents
# future regressions of this exact drift class.
_snapshot_fail
workflow_file="$REPO_ROOT/.github/workflows/review-sub-pr.yml"
workflow_covers_all="yes"
missing_from_workflow=""
for p in "${patterns[@]}"; do
    # Check for "'<pattern>'" with single quotes (YAML list item style)
    if ! grep -qF "'$p'" "$workflow_file"; then
        workflow_covers_all="no"
        missing_from_workflow="${missing_from_workflow}${p} "
    fi
done
if [[ "$workflow_covers_all" == "no" ]]; then
    echo "MISSING from review-sub-pr.yml workflow trigger: $missing_from_workflow" >&2
fi
assert_eq "test_workflow_trigger_covers_all_patterns: every source-of-truth pattern in workflow trigger" \
    "yes" "$workflow_covers_all"
assert_pass_if_clean "test_workflow_trigger_covers_all_patterns"

# ── Test 7: empty patterns file fails closed (critical finding regression) ────
# Caught by the llm-review on PR #432: an empty (or comments-only) patterns
# file would cause the provisioner to emit an empty include array, silently
# disabling sub-PR review enforcement (an empty include matches no branches).
# The provisioner must fail closed when zero active patterns are present.
_snapshot_fail
ephemeral_patterns_dir=$(mktemp -d)
cat > "$ephemeral_patterns_dir/sub-pr-branch-patterns.txt" <<'EOF'
# Only comments — zero active patterns
# This file must trigger the provisioner's empty-patterns guard
EOF
# Override the plugin root path via env (provisioner honors CLAUDE_PLUGIN_ROOT).
# Build a fake plugin root that has the comments-only patterns file at the
# expected path.
fake_plugin_root=$(mktemp -d)
mkdir -p "$fake_plugin_root/config"
cp "$ephemeral_patterns_dir/sub-pr-branch-patterns.txt" "$fake_plugin_root/config/sub-pr-branch-patterns.txt"
empty_run_exit=0
empty_run_output=$(CLAUDE_PLUGIN_ROOT="$fake_plugin_root" DSO_DRY_RUN=1 bash "$PROVISIONER" 2>&1) || empty_run_exit=$?
fail_closed="no"
if [[ "$empty_run_exit" -ne 0 ]] && echo "$empty_run_output" | grep -qE "zero active patterns|empty include"; then
    fail_closed="yes"
fi
assert_eq "test_empty_patterns_file_fails_closed: empty/comments-only file triggers provisioner error" \
    "yes" "$fail_closed"
rm -rf "$ephemeral_patterns_dir" "$fake_plugin_root"
assert_pass_if_clean "test_empty_patterns_file_fails_closed"

print_summary
