#!/usr/bin/env bash
# tests/scripts/test-reversal-check.sh
# RED-phase behavioral tests for plugins/dso/scripts/fix-bug/reversal-check.sh
#
# Each test creates an isolated temp git repo with controlled commit history,
# then calls reversal-check.sh and asserts on the JSON output.
#
# RED STATE: All tests currently fail because reversal-check.sh does
# not yet exist. They will pass (GREEN) after the script is implemented.
#
# Usage: bash tests/scripts/test-reversal-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/fix-bug/reversal-check.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_TEST_TMPDIRS=()
_cleanup_all() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup_all EXIT

echo "=== test-reversal-check.sh ==="
echo ""

# ── Shared helpers ─────────────────────────────────────────────────────────────

# _make_git_repo — create an isolated git repo in a new temp dir; prints path
_make_git_repo() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@example.com"
    git -C "$tmpdir" config user.name "Test User"
    echo "$tmpdir"
}

# _json_field json field — extract a JSON field value via python3
_json_field() {
    local json="$1" field="$2"
    python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('$field',''))" "$json" 2>/dev/null || echo ""
}

# _json_field_bool json field — extract a JSON boolean as "true" or "false"
_json_field_bool() {
    local json="$1" field="$2"
    python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(str(d.get('$field',False)).lower())" "$json" 2>/dev/null || echo "false"
}

# ── test_detects_reversal ──────────────────────────────────────────────────────
# Scenario: commit a change to a file, then propose a fix that undoes it.
# The working tree diff (git diff) restores the original content.
# Expected: triggered=true
test_detects_reversal() {
    _snapshot_fail

    local repo
    repo="$(_make_git_repo)"

    # Commit an initial version
    echo "value=1" > "$repo/config.sh"
    git -C "$repo" add config.sh
    git -C "$repo" commit -q -m "set value to 1"

    # Commit a deliberate change (the "bug fix" applied earlier)
    echo "value=2" > "$repo/config.sh"
    git -C "$repo" add config.sh
    git -C "$repo" commit -q -m "change value to 2"

    # Now propose a fix that undoes the change — restore original content
    echo "value=1" > "$repo/config.sh"

    # Run gate from within the repo so git diff works correctly
    local output exit_code=0
    output=$(cd "$repo" && bash "$GATE_SCRIPT" config.sh 2>/dev/null) || exit_code=$?

    assert_eq "test_detects_reversal: gate exits 0" "0" "$exit_code"

    local triggered
    triggered="$(_json_field_bool "$output" "triggered")"
    assert_eq "test_detects_reversal: triggered=true when fix reverses a committed change" "true" "$triggered"

    assert_pass_if_clean "test_detects_reversal"
}

# ── test_no_reversal ───────────────────────────────────────────────────────────
# Scenario: commit a change, then propose an additive fix that does NOT revert it.
# Expected: triggered=false
test_no_reversal() {
    _snapshot_fail

    local repo
    repo="$(_make_git_repo)"

    # Commit an initial version
    echo "value=1" > "$repo/config.sh"
    git -C "$repo" add config.sh
    git -C "$repo" commit -q -m "initial commit"

    # Commit a change
    echo "value=2" > "$repo/config.sh"
    git -C "$repo" add config.sh
    git -C "$repo" commit -q -m "change value to 2"

    # Propose a fix that makes a different, forward change (not a reversal)
    echo "value=3" > "$repo/config.sh"

    local output exit_code=0
    output=$(cd "$repo" && bash "$GATE_SCRIPT" config.sh 2>/dev/null) || exit_code=$?

    assert_eq "test_no_reversal: gate exits 0" "0" "$exit_code"

    local triggered
    triggered="$(_json_field_bool "$output" "triggered")"
    assert_eq "test_no_reversal: triggered=false for a normal forward fix" "false" "$triggered"

    assert_pass_if_clean "test_no_reversal"
}

# ── test_revert_of_revert ──────────────────────────────────────────────────────
# Scenario: commit a change, revert it (so current HEAD has original), then
# propose a fix that re-applies the original change (revert-of-revert).
# Expected: triggered=false (revert-of-revert is not a problematic reversal),
#           and the evidence string mentions "revert-of-revert"
test_revert_of_revert() {
    _snapshot_fail

    local repo
    repo="$(_make_git_repo)"

    # Commit initial content
    echo "feature=enabled" > "$repo/feature.sh"
    git -C "$repo" add feature.sh
    git -C "$repo" commit -q -m "enable feature"

    # Commit a revert of that change
    echo "feature=disabled" > "$repo/feature.sh"
    git -C "$repo" add feature.sh
    git -C "$repo" commit -q -m "Revert: disable feature"

    # Propose fix that re-enables (revert-of-revert) — restores original enabled state
    echo "feature=enabled" > "$repo/feature.sh"

    local output exit_code=0
    output=$(cd "$repo" && bash "$GATE_SCRIPT" feature.sh 2>/dev/null) || exit_code=$?

    assert_eq "test_revert_of_revert: gate exits 0" "0" "$exit_code"

    local triggered
    triggered="$(_json_field_bool "$output" "triggered")"
    assert_eq "test_revert_of_revert: triggered=false for revert-of-revert scenario" "false" "$triggered"

    local evidence
    evidence="$(_json_field "$output" "evidence")"
    assert_contains "test_revert_of_revert: evidence mentions revert-of-revert" "revert" "$evidence"

    assert_pass_if_clean "test_revert_of_revert"
}

# ── test_intent_aligned_suppression ───────────────────────────────────────────
# Scenario: working tree diff would normally trigger reversal detection,
#           but --intent-aligned flag is passed.
# Expected: triggered=false regardless of diff content
test_intent_aligned_suppression() {
    _snapshot_fail

    local repo
    repo="$(_make_git_repo)"

    # Commit a change
    echo "x=10" > "$repo/settings.sh"
    git -C "$repo" add settings.sh
    git -C "$repo" commit -q -m "set x to 10"

    # Commit another change
    echo "x=20" > "$repo/settings.sh"
    git -C "$repo" add settings.sh
    git -C "$repo" commit -q -m "set x to 20"

    # Working tree reverts to x=10 (would trigger without --intent-aligned)
    echo "x=10" > "$repo/settings.sh"

    local output exit_code=0
    output=$(cd "$repo" && bash "$GATE_SCRIPT" --intent-aligned settings.sh 2>/dev/null) || exit_code=$?

    assert_eq "test_intent_aligned_suppression: gate exits 0" "0" "$exit_code"

    local triggered
    triggered="$(_json_field_bool "$output" "triggered")"
    assert_eq "test_intent_aligned_suppression: triggered=false when --intent-aligned is passed" "false" "$triggered"

    assert_pass_if_clean "test_intent_aligned_suppression"
}

# ── test_emits_gate_signal_json ────────────────────────────────────────────────
# Scenario: run gate on any file with git history.
# Expected: output is valid JSON conforming to gate-signal-schema.md —
#           gate_id="reversal", signal_type="primary", non-empty evidence,
#           confidence in {high,medium,low}
test_emits_gate_signal_json() {
    _snapshot_fail

    local repo
    repo="$(_make_git_repo)"

    echo "msg=hello" > "$repo/msg.sh"
    git -C "$repo" add msg.sh
    git -C "$repo" commit -q -m "initial msg"

    echo "msg=world" > "$repo/msg.sh"
    git -C "$repo" add msg.sh
    git -C "$repo" commit -q -m "update msg"

    # No working-tree change — clean diff
    local output exit_code=0
    output=$(cd "$repo" && bash "$GATE_SCRIPT" msg.sh 2>/dev/null) || exit_code=$?

    assert_eq "test_emits_gate_signal_json: gate exits 0" "0" "$exit_code"

    # gate_id must be "reversal"
    local gate_id
    gate_id="$(_json_field "$output" "gate_id")"
    assert_eq "test_emits_gate_signal_json: gate_id is reversal" "reversal" "$gate_id"

    # signal_type must be "primary"
    local signal_type
    signal_type="$(_json_field "$output" "signal_type")"
    assert_eq "test_emits_gate_signal_json: signal_type is primary" "primary" "$signal_type"

    # evidence must be non-empty
    local evidence
    evidence="$(_json_field "$output" "evidence")"
    assert_ne "test_emits_gate_signal_json: evidence is non-empty" "" "$evidence"

    # confidence must be one of: high, medium, low
    local confidence
    confidence="$(_json_field "$output" "confidence")"
    local valid_confidence
    valid_confidence=$(python3 -c "print('yes' if '$confidence' in ('high','medium','low') else 'no')" 2>/dev/null) || valid_confidence="no"
    assert_eq "test_emits_gate_signal_json: confidence is valid enum (high/medium/low)" "yes" "$valid_confidence"

    assert_pass_if_clean "test_emits_gate_signal_json"
}

# ── test_no_git_history ────────────────────────────────────────────────────────
# Scenario: file exists in git repo but has no prior commits (untracked or newly
#           staged with no history for comparison).
# Expected: triggered=false (cannot determine reversal without history)
test_no_git_history() {
    _snapshot_fail

    local repo
    repo="$(_make_git_repo)"

    # Write a file but never commit it
    echo "brand=new" > "$repo/newfile.sh"

    local output exit_code=0
    output=$(cd "$repo" && bash "$GATE_SCRIPT" newfile.sh 2>/dev/null) || exit_code=$?

    assert_eq "test_no_git_history: gate exits 0" "0" "$exit_code"

    local triggered
    triggered="$(_json_field_bool "$output" "triggered")"
    assert_eq "test_no_git_history: triggered=false for file with no git history" "false" "$triggered"

    assert_pass_if_clean "test_no_git_history"
}

# ── test_outside_git_repo ──────────────────────────────────────────────────────
# Scenario: gate is invoked from a non-git directory.
# Expected: exits 0 gracefully, emits triggered=false JSON (not a crash)
test_outside_git_repo() {
    _snapshot_fail

    local non_git_dir
    non_git_dir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$non_git_dir")

    echo "data=123" > "$non_git_dir/somefile.sh"

    local output exit_code=0
    output=$(cd "$non_git_dir" && bash "$GATE_SCRIPT" somefile.sh 2>/dev/null) || exit_code=$?

    assert_eq "test_outside_git_repo: gate exits 0 outside git repo" "0" "$exit_code"

    local triggered
    triggered="$(_json_field_bool "$output" "triggered")"
    assert_eq "test_outside_git_repo: triggered=false outside git repo" "false" "$triggered"

    assert_pass_if_clean "test_outside_git_repo"
}

# ── test_multi_file_partial_reversal ──────────────────────────────────────────
# Scenario: 2 files passed as args; only one is reversed in working tree.
# Expected: triggered=true because at least one file shows a reversal
test_multi_file_partial_reversal() {
    _snapshot_fail

    local repo
    repo="$(_make_git_repo)"

    # File A: will be reversed
    echo "a=1" > "$repo/file_a.sh"
    git -C "$repo" add file_a.sh
    git -C "$repo" commit -q -m "init file_a"

    echo "a=2" > "$repo/file_a.sh"
    git -C "$repo" add file_a.sh
    git -C "$repo" commit -q -m "change file_a to 2"

    # File B: will receive a normal forward change
    echo "b=start" > "$repo/file_b.sh"
    git -C "$repo" add file_b.sh
    git -C "$repo" commit -q -m "init file_b"

    echo "b=v2" > "$repo/file_b.sh"
    git -C "$repo" add file_b.sh
    git -C "$repo" commit -q -m "update file_b"

    # Working tree: reverse file_a (back to a=1), advance file_b (to b=v3)
    echo "a=1" > "$repo/file_a.sh"
    echo "b=v3" > "$repo/file_b.sh"

    local output exit_code=0
    output=$(cd "$repo" && bash "$GATE_SCRIPT" file_a.sh file_b.sh 2>/dev/null) || exit_code=$?

    assert_eq "test_multi_file_partial_reversal: gate exits 0" "0" "$exit_code"

    local triggered
    triggered="$(_json_field_bool "$output" "triggered")"
    assert_eq "test_multi_file_partial_reversal: triggered=true when any file is reversed" "true" "$triggered"

    assert_pass_if_clean "test_multi_file_partial_reversal"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_detects_reversal
test_no_reversal
test_revert_of_revert
test_intent_aligned_suppression
test_emits_gate_signal_json
test_no_git_history
test_outside_git_repo
test_multi_file_partial_reversal

print_summary
