#!/usr/bin/env bash
# tests/integration/test-conflict-data-schema-parity.sh
#
# Behavioral regression test asserting CONFLICT_DATA schema parity between
# merge-to-main-direct.sh and merge-to-main-pr.sh.
#
# Both modes share the _emit_conflict_data helper from
# plugins/dso/hooks/lib/merge-helpers.sh, which emits a single-line contract:
#
#   CONFLICT_DATA {"branch":"...", "base_branch":"...",
#                  "conflicted_files":[...], "resolution_strategy":"..."}
#
# This test locks in the parity as a regression guard. If either script
# diverges (different keys, missing fields, different types), it fails.
#
# Test cases:
#   1. test_direct_mode_emits_canonical_conflict_data_schema
#   2. test_pr_mode_emits_canonical_conflict_data_schema
#   3. test_both_modes_emit_identical_key_sets
#
# Strategy:
#   - Direct mode: source merge-helpers.sh and drive a real git conflict
#     fixture into _emit_conflict_data (the same helper merge-to-main-direct.sh
#     wires into its exit-1 paths).
#   - PR mode: PATH-shim `gh` to return mergeable=CONFLICTING and let the
#     real merge-to-main-pr.sh emit CONFLICT_DATA via its top-level error
#     handler (which calls _emit_conflict_data).
#
# Assertions parse the emitted JSON with python3 and compare key sets and
# value types — no source-file greps as the primary assertion.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
MERGE_HELPERS="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# Canonical schema: the four keys both modes must emit, sorted.
CANONICAL_KEYS="base_branch,branch,conflicted_files,resolution_strategy"

# ---------------------------------------------------------------------------
# Helper: extract the JSON payload from a `CONFLICT_DATA <json>` line in a
# blob of stdout/stderr. Returns the JSON string on stdout. Empty if not
# found. Strips any trailing lines.
# ---------------------------------------------------------------------------
_extract_conflict_data_json() {
    local _blob="$1"
    # Find the line beginning with "CONFLICT_DATA " and emit everything after.
    echo "$_blob" | awk '
        /^CONFLICT_DATA / {
            # Strip the "CONFLICT_DATA " prefix, then print the rest of the line.
            sub(/^CONFLICT_DATA /, "")
            print
            exit
        }
    '
}

# Helper: given a JSON string, print the comma-joined sorted set of top-level keys.
_json_top_level_keys() {
    local _json="$1"
    JSON="$_json" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ.get("JSON", ""))
    if not isinstance(d, dict):
        sys.exit(0)
    print(",".join(sorted(d.keys())))
except Exception:
    pass
'
}

# Helper: given a JSON string and a key, print "type:<typename>" of the value.
# Type names: str, list, int, float, bool, null, dict.
_json_value_type() {
    local _json="$1" _key="$2"
    JSON="$_json" KEY="$_key" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ.get("JSON", ""))
    v = d[os.environ["KEY"]]
    if v is None:
        print("null"); sys.exit(0)
    if isinstance(v, bool):
        print("bool"); sys.exit(0)
    print(type(v).__name__)
except Exception:
    pass
'
}

# ---------------------------------------------------------------------------
# Fixture: build a git repo with two unmerged paths so _emit_conflict_data's
# `git diff --name-only --diff-filter=U` reports real conflicted files.
# ---------------------------------------------------------------------------
_build_direct_conflict_repo() {
    local _T="$1"
    (
        cd "$_T" || exit 1
        git init -q -b main >/dev/null 2>&1
        git config user.email "test@test.local"
        git config user.name "test"
        echo "base" > a.txt
        echo "base" > b.txt
        git add a.txt b.txt
        git commit -q -m "base" >/dev/null
        git checkout -q -b feature
        echo "feature-a" > a.txt
        echo "feature-b" > b.txt
        git commit -aq -m "feature" >/dev/null
        git checkout -q main
        echo "main-a" > a.txt
        echo "main-b" > b.txt
        git commit -aq -m "main" >/dev/null
        # Trigger a real conflict that leaves unmerged paths in the index.
        git merge feature -q >/dev/null 2>&1 || true
    )
}

# ---------------------------------------------------------------------------
# Fixture: build a tmpdir with `gh` and `git` shims that drive PR mode into
# the CONFLICTING path, plus a minimal git repo on `branch`.
# ---------------------------------------------------------------------------
_build_pr_conflict_fixture() {
    local _T="$1" _branch="$2"
    local _bin="$_T/bin"
    mkdir -p "$_bin"

    cat > "$_bin/gh" <<'GH_SHIM'
#!/usr/bin/env bash
# Stubbed gh for CONFLICTING-path PR-mode test.
case "$1" in
    --version)
        echo "gh version 2.40.1 (2024-01-01)"
        exit 0
        ;;
    pr)
        case "$2" in
            list)
                # Duplicate-PR guard — empty output → no existing PR.
                exit 0
                ;;
            create)
                echo "https://github.com/x/y/pull/42"
                exit 0
                ;;
            view)
                # Force CONFLICTING for the mergeable check.
                echo '{"mergeable":"CONFLICTING","number":42,"url":"https://github.com/x/y/pull/42"}'
                exit 0
                ;;
            merge)
                exit 0
                ;;
            *) exit 0 ;;
        esac
        ;;
    *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$_bin/gh"

    # git shim: pass-through except for `git push` (don't hit a real remote).
    local _real_git
    _real_git=$(command -v git)
    cat > "$_bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  exit 0
fi
exec "$_real_git" "\$@"
GIT_SHIM
    chmod +x "$_bin/git"

    # Minimal git repo so `git rev-parse --show-toplevel` and `git branch --show-current` work.
    (
        cd "$_T" || exit 1
        "$_real_git" init -q -b main >/dev/null 2>&1
        "$_real_git" config user.email "test@test.local"
        "$_real_git" config user.name "test"
        echo "seed" > seed.txt
        "$_real_git" add seed.txt
        "$_real_git" commit -q -m "seed" >/dev/null
        "$_real_git" checkout -q -b "$_branch"
        echo "feature" > feature.txt
        "$_real_git" add feature.txt
        "$_real_git" commit -q -m "feature work" >/dev/null
    )
}

# Capture both JSON payloads at module level so all tests (including the
# parity test) can compare them. Populated by tests 1 and 2.
DIRECT_JSON=""
PR_JSON=""

# ---------------------------------------------------------------------------
# Test 1: direct mode emits the canonical CONFLICT_DATA schema.
# Sources merge-helpers.sh and invokes _emit_conflict_data inside a real
# conflicted git repo. Asserts:
#   - a single CONFLICT_DATA line is emitted
#   - the JSON top-level key set is exactly {branch, base_branch,
#     conflicted_files, resolution_strategy}
#   - conflicted_files is a JSON array (python type list)
#   - branch / base_branch / resolution_strategy are strings
# ---------------------------------------------------------------------------
test_direct_mode_emits_canonical_conflict_data_schema() {
    local _T _out _line_count _json _keys
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-conflict-parity-direct.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_direct_conflict_repo "$_T"

    _out="$(
        cd "$_T" || exit 1
        # shellcheck source=/dev/null
        BRANCH="feature" source "$MERGE_HELPERS"
        _emit_conflict_data "feature" "main" "git-merge-no-ff" 2>&1
    )"

    # Expect exactly ONE CONFLICT_DATA line.
    _line_count=$(echo "$_out" | grep -c '^CONFLICT_DATA ' || true)
    assert_eq "direct_mode_single_conflict_data_line" "1" "$_line_count"

    _json="$(_extract_conflict_data_json "$_out")"
    assert_ne "direct_mode_json_payload_nonempty" "" "$_json"

    _keys="$(_json_top_level_keys "$_json")"
    assert_eq "direct_mode_canonical_key_set" "$CANONICAL_KEYS" "$_keys"

    # Field shapes
    assert_eq "direct_mode_conflicted_files_is_array" "list"  "$(_json_value_type "$_json" "conflicted_files")"
    assert_eq "direct_mode_branch_is_string"          "str"   "$(_json_value_type "$_json" "branch")"
    assert_eq "direct_mode_base_branch_is_string"     "str"   "$(_json_value_type "$_json" "base_branch")"
    assert_eq "direct_mode_resolution_strategy_is_string" "str" "$(_json_value_type "$_json" "resolution_strategy")"

    # Stash for cross-mode parity comparison in test 3.
    DIRECT_JSON="$_json"
}
test_direct_mode_emits_canonical_conflict_data_schema

# ---------------------------------------------------------------------------
# Test 2: PR mode emits the canonical CONFLICT_DATA schema.
# Drives merge-to-main-pr.sh into the CONFLICTING path via stubbed gh.
# The script's top-level error handler calls _emit_conflict_data with
# resolution_strategy="pr-auto-merge" and exits 1.
# ---------------------------------------------------------------------------
test_pr_mode_emits_canonical_conflict_data_schema() {
    local _T _out _ec _line_count _json _keys _branch _branch_safe _state_file
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-conflict-parity-pr.XXXXXX")"
    _branch="feature-pr-conflict-parity"
    _branch_safe="${_branch//\//-}"
    _state_file="/tmp/merge-to-main-state-${_branch_safe}.json"
    rm -f "$_state_file"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'; rm -f '$_state_file'" RETURN

    _build_pr_conflict_fixture "$_T" "$_branch"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        bash "$PR_SCRIPT" 2>&1
    )"
    _ec=$?

    # PR mode must exit non-zero on conflict.
    local _exits_nonzero="false"
    [[ "$_ec" -ne 0 ]] && _exits_nonzero="true"
    assert_eq "pr_mode_exits_nonzero_on_conflict" "true" "$_exits_nonzero"

    _line_count=$(echo "$_out" | grep -c '^CONFLICT_DATA ' || true)
    assert_eq "pr_mode_single_conflict_data_line" "1" "$_line_count"

    _json="$(_extract_conflict_data_json "$_out")"
    assert_ne "pr_mode_json_payload_nonempty" "" "$_json"

    _keys="$(_json_top_level_keys "$_json")"
    assert_eq "pr_mode_canonical_key_set" "$CANONICAL_KEYS" "$_keys"

    # Field shapes (same as direct mode).
    assert_eq "pr_mode_conflicted_files_is_array" "list" "$(_json_value_type "$_json" "conflicted_files")"
    assert_eq "pr_mode_branch_is_string"          "str"  "$(_json_value_type "$_json" "branch")"
    assert_eq "pr_mode_base_branch_is_string"     "str"  "$(_json_value_type "$_json" "base_branch")"
    assert_eq "pr_mode_resolution_strategy_is_string" "str" "$(_json_value_type "$_json" "resolution_strategy")"

    PR_JSON="$_json"
}
test_pr_mode_emits_canonical_conflict_data_schema

# ---------------------------------------------------------------------------
# Test 3: both modes emit identical key sets and field-type signatures.
# This is the cross-mode parity assertion. We compare:
#   - sorted top-level key sets (must be identical)
#   - per-field python type names (must match field-by-field)
# We deliberately do NOT compare values: branch / resolution_strategy differ
# by design between the two modes.
# ---------------------------------------------------------------------------
test_both_modes_emit_identical_key_sets() {
    # Sanity: both fixtures must have populated their JSON.
    assert_ne "parity_direct_json_present" "" "$DIRECT_JSON"
    assert_ne "parity_pr_json_present"     "" "$PR_JSON"

    if [[ -z "$DIRECT_JSON" || -z "$PR_JSON" ]]; then
        # Skip downstream comparisons — they would assert against empty strings.
        return
    fi

    local _direct_keys _pr_keys
    _direct_keys="$(_json_top_level_keys "$DIRECT_JSON")"
    _pr_keys="$(_json_top_level_keys "$PR_JSON")"

    # Both must equal the canonical set, AND must equal each other.
    assert_eq "parity_direct_keys_canonical" "$CANONICAL_KEYS" "$_direct_keys"
    assert_eq "parity_pr_keys_canonical"     "$CANONICAL_KEYS" "$_pr_keys"
    assert_eq "parity_key_sets_identical"    "$_direct_keys"   "$_pr_keys"

    # Field-by-field type parity.
    local _k _dt _pt
    for _k in branch base_branch conflicted_files resolution_strategy; do
        _dt="$(_json_value_type "$DIRECT_JSON" "$_k")"
        _pt="$(_json_value_type "$PR_JSON"     "$_k")"
        assert_eq "parity_field_type_${_k}" "$_dt" "$_pt"
    done
}
test_both_modes_emit_identical_key_sets

# ---------------------------------------------------------------------------
# Test 4: recovery-failed fallback path emits CONFLICT_DATA from
# _SQUASH_REBASE_CONFLICTS when live git state has no unmerged paths.
#
# This models the merge-to-main-direct.sh _phase_merge recovery-failed branch:
#   - _squash_rebase_recovery returns non-zero, having exported
#     _SQUASH_REBASE_CONFLICTS before calling `git rebase --abort`
#   - _phase_merge then `cd "$_MERGE_SAVED_DIR"` (a clean git repo), so live
#     `git diff --diff-filter=U` returns empty
#   - _emit_conflict_data must fall back to _SQUASH_REBASE_CONFLICTS and still
#     emit CONFLICT_DATA with the correct conflicted_files list and
#     resolution_strategy
#
# Asserts:
#   - exactly one CONFLICT_DATA line is emitted
#   - the JSON key set equals the canonical set
#   - conflicted_files is a non-empty list containing the simulated conflict files
#   - resolution_strategy is the value passed to _emit_conflict_data
# ---------------------------------------------------------------------------
test_recovery_failed_fallback_uses_squash_rebase_conflicts() {
    local _T _out _json _keys _line_count _files_type _branch
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-conflict-parity-recovery.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    # Build a minimal clean git repo (no unmerged paths) to simulate _MERGE_SAVED_DIR.
    # _build_direct_conflict_repo leaves the repo with an in-progress merge.
    # We abort the merge to leave a clean working tree — so live `git diff
    # --diff-filter=U` returns empty, forcing _emit_conflict_data to use
    # the _SQUASH_REBASE_CONFLICTS fallback.
    _build_direct_conflict_repo "$_T"
    (
        cd "$_T" || exit 1
        git merge --abort 2>/dev/null || true
        git checkout -q main 2>/dev/null || true
    )

    _branch="recovery-failed-branch"
    _out="$(
        cd "$_T" || exit 1
        # Simulate what _squash_rebase_recovery exports before rebase --abort.
        export _SQUASH_REBASE_CONFLICTS="src/foo.sh
src/bar.sh"
        # Source helpers (which defines _emit_conflict_data).
        # shellcheck source=/dev/null
        BRANCH="$_branch" source "$MERGE_HELPERS"
        # Call _emit_conflict_data in the same environment where:
        #   - live git diff --diff-filter=U returns empty (clean repo)
        #   - _SQUASH_REBASE_CONFLICTS is set (from recovery helper)
        _emit_conflict_data "$_branch" "main" "git-merge-no-ff" 2>&1
    )"

    # Must emit exactly one CONFLICT_DATA line.
    _line_count=$(echo "$_out" | grep -c '^CONFLICT_DATA ' || true)
    assert_eq "recovery_fallback_single_conflict_data_line" "1" "$_line_count"

    _json="$(_extract_conflict_data_json "$_out")"
    assert_ne "recovery_fallback_json_payload_nonempty" "" "$_json"

    # Key set must match the canonical schema.
    _keys="$(_json_top_level_keys "$_json")"
    assert_eq "recovery_fallback_canonical_key_set" "$CANONICAL_KEYS" "$_keys"

    # conflicted_files must be a non-empty list (populated from _SQUASH_REBASE_CONFLICTS).
    _files_type="$(_json_value_type "$_json" "conflicted_files")"
    assert_eq "recovery_fallback_conflicted_files_is_array" "list" "$_files_type"

    local _files_count
    _files_count=$(JSON="$_json" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ.get("JSON", ""))
    print(len(d.get("conflicted_files", [])))
except Exception:
    print(0)
')
    # The fallback must have populated conflicted_files from _SQUASH_REBASE_CONFLICTS
    # (2 files: src/foo.sh and src/bar.sh), not an empty list.
    assert_eq "recovery_fallback_conflicted_files_nonempty" "2" "$_files_count"

    # resolution_strategy must be the value passed to _emit_conflict_data.
    local _strategy
    _strategy=$(JSON="$_json" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ.get("JSON", ""))
    print(d.get("resolution_strategy", ""))
except Exception:
    pass
')
    assert_eq "recovery_fallback_resolution_strategy" "git-merge-no-ff" "$_strategy"

    # branch must match what was passed.
    local _actual_branch
    _actual_branch=$(JSON="$_json" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ.get("JSON", ""))
    print(d.get("branch", ""))
except Exception:
    pass
')
    assert_eq "recovery_fallback_branch_field" "$_branch" "$_actual_branch"
}
test_recovery_failed_fallback_uses_squash_rebase_conflicts

print_summary
