#!/usr/bin/env bash
# tests/hooks/test-check-tickets-boundary.sh
# Tests for plugins/dso/hooks/check-tickets-boundary.sh (TDD RED phase)
#
# check-tickets-boundary.sh is a pre-commit hook that scans staged files for
# boundary violations:
#   - Direct .tickets-tracker/ references in non-allowlisted files
#   - References to absorbed script names (sprint-next-batch.sh,
#     sprint-list-epics.sh, purge-non-project-tickets.sh)
#
# On violation: exits non-zero with actionable error on stderr
# On clean: exits 0
# Suppression: lines with # tickets-boundary-ok are exempt
#
# RED MARKER:
# tests/hooks/test-check-tickets-boundary.sh [test_direct_tracker_ref_rejected]
#
# Test cases (7 + 6 named-member):
#   1. test_direct_tracker_ref_rejected        — staged file with .tickets-tracker/ ref exits non-zero
#   2. test_absorbed_script_ref_rejected       — staged file with sprint-next-batch.sh ref exits non-zero
#   3. test_allowlisted_file_passes            — ticket-*.sh staged file with .tickets-tracker/ exits 0
#   4. test_docs_path_excluded                 — docs/ staged file with absorbed script name exits 0
#   5. test_clean_file_passes                  — staged file with no violations exits 0
#   6. test_suppression_annotation_exempts     — line with # tickets-boundary-ok is exempt, exits 0
#   7. test_docs_excluded_via_symlink          — docs/ file exits 0 when hook invoked via /tmp symlink
#
# All tests use isolated temp git repos to avoid polluting the real repository.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PLUGIN_ROOT/plugins/dso/hooks/check-tickets-boundary.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create a fresh isolated git repo ─────────────────────────────────
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false
    # Initial commit so the repo has a HEAD
    printf '# test repo\n' > "$tmpdir/README.md"
    git -C "$tmpdir" add README.md
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Helper: stage a file at a given subpath with given content ────────────────
# Usage: stage_file <repo_dir> <relative_subpath> <content>
# Creates parent dirs as needed, then stages the file.
stage_file() {
    local repo_dir="$1"
    local subpath="$2"
    local content="$3"
    local parent_dir
    parent_dir="$(dirname "$repo_dir/$subpath")"
    mkdir -p "$parent_dir"
    printf '%s\n' "$content" > "$repo_dir/$subpath"
    git -C "$repo_dir" add "$subpath"
}

# ── Helper: run the hook in a test repo, return exit code ────────────────────
run_hook() {
    local repo_dir="$1"
    local exit_code=0
    ( cd "$repo_dir" && bash "$HOOK" 2>/dev/null ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: run the hook in a test repo, capture stderr ──────────────────────
run_hook_stderr() {
    local repo_dir="$1"
    # shellcheck disable=SC2069  # intentional: redirect stderr→stdout (captured), then stdout→/dev/null
    ( cd "$repo_dir" && bash "$HOOK" 2>&1 >/dev/null ) || true
}

# ============================================================
# TEST 1: test_direct_tracker_ref_rejected
# A non-allowlisted staged file containing a direct
# .tickets-tracker/ reference must cause the hook to exit
# non-zero with an actionable message on stderr.
# ============================================================
test_direct_tracker_ref_rejected() {
    if [[ ! -f "$HOOK" ]]; then
        echo "  FAIL: check-tickets-boundary.sh not found (RED — not yet implemented)" >&2
        (( FAIL++ ))
        return
    fi

    local _repo
    _repo=$(make_test_repo)

    # Stage a non-allowlisted file containing a .tickets-tracker/ reference
    # tickets-boundary-fixture (intentional violation for test purposes)
    stage_file "$_repo" "src/example.sh" "ls .tickets-tracker/"

    local exit_code
    exit_code=$(run_hook "$_repo")
    assert_ne "test_direct_tracker_ref_rejected: exits non-zero" "0" "$exit_code"

    local stderr_out
    stderr_out=$(run_hook_stderr "$_repo")
    assert_contains "test_direct_tracker_ref_rejected: stderr names violation" \
        ".tickets-tracker" "$stderr_out"
}

# ============================================================
# TEST 2: test_absorbed_script_ref_rejected
# A non-allowlisted staged file referencing the absorbed script
# sprint-next-batch.sh must cause the hook to exit non-zero
# with stderr naming the script and its CLI replacement.
# ============================================================
test_absorbed_script_ref_rejected() {
    if [[ ! -f "$HOOK" ]]; then
        echo "  FAIL: check-tickets-boundary.sh not found (RED — not yet implemented)" >&2
        (( FAIL++ ))
        return
    fi

    local _repo
    _repo=$(make_test_repo)

    # Stage a non-allowlisted file referencing the absorbed script
    # tickets-boundary-fixture (intentional violation for test purposes)
    stage_file "$_repo" "src/deploy.sh" "bash sprint-next-batch.sh"

    local exit_code
    exit_code=$(run_hook "$_repo")
    assert_ne "test_absorbed_script_ref_rejected: exits non-zero" "0" "$exit_code"

    local stderr_out
    stderr_out=$(run_hook_stderr "$_repo")
    assert_contains "test_absorbed_script_ref_rejected: stderr names script" \
        "sprint-next-batch.sh" "$stderr_out"
    assert_contains "test_absorbed_script_ref_rejected: stderr has CLI hint" \
        "ticket next-batch" "$stderr_out"
}

# ============================================================
# TEST 3: test_allowlisted_file_passes
# A ticket system script (ticket-exists.sh under
# plugins/dso/scripts/) may legitimately reference
# .tickets-tracker/ — the hook must exit 0.
# ============================================================
test_allowlisted_file_passes() {
    if [[ ! -f "$HOOK" ]]; then
        echo "  FAIL: check-tickets-boundary.sh not found (RED — not yet implemented)" >&2
        (( FAIL++ ))
        return
    fi

    local _repo
    _repo=$(make_test_repo)

    # Stage an allowlisted ticket script with a .tickets-tracker/ reference
    stage_file "$_repo" "plugins/dso/scripts/ticket-exists.sh" \
        "#!/usr/bin/env bash
# legitimate — ticket scripts access .tickets-tracker/ directly
ls .tickets-tracker/"

    local exit_code
    exit_code=$(run_hook "$_repo")
    assert_eq "test_allowlisted_file_passes: exits 0" "0" "$exit_code"
}

# ============================================================
# TEST 4: test_docs_path_excluded
# A documentation file (under docs/) may reference absorbed
# script names (e.g., in migration notes) — the hook must exit 0.
# ============================================================
test_docs_path_excluded() {
    if [[ ! -f "$HOOK" ]]; then
        echo "  FAIL: check-tickets-boundary.sh not found (RED — not yet implemented)" >&2
        (( FAIL++ ))
        return
    fi

    local _repo
    _repo=$(make_test_repo)

    # Stage a doc file that mentions the absorbed script (legitimate documentation)
    stage_file "$_repo" "plugins/dso/docs/ticket-cli-reference.md" \
        "# Migration Notes
Previously: sprint-next-batch.sh
Now: .claude/scripts/dso ticket next-batch"

    local exit_code
    exit_code=$(run_hook "$_repo")
    assert_eq "test_docs_path_excluded: exits 0" "0" "$exit_code"
}

# ============================================================
# TEST 5: test_clean_file_passes
# A staged file with no boundary violations must cause the hook
# to exit 0.
# ============================================================
test_clean_file_passes() {
    if [[ ! -f "$HOOK" ]]; then
        echo "  FAIL: check-tickets-boundary.sh not found (RED — not yet implemented)" >&2
        (( FAIL++ ))
        return
    fi

    local _repo
    _repo=$(make_test_repo)

    # Stage a clean file with no boundary violations
    stage_file "$_repo" "src/helper.sh" \
        "#!/usr/bin/env bash
echo 'hello world'"

    local exit_code
    exit_code=$(run_hook "$_repo")
    assert_eq "test_clean_file_passes: exits 0" "0" "$exit_code"
}

# ============================================================
# TEST 6: test_suppression_annotation_exempts
# A line ending with # tickets-boundary-ok must be exempted
# even if it contains a .tickets-tracker/ reference — hook
# must exit 0.
# ============================================================
test_suppression_annotation_exempts() {
    if [[ ! -f "$HOOK" ]]; then
        echo "  FAIL: check-tickets-boundary.sh not found (RED — not yet implemented)" >&2
        (( FAIL++ ))
        return
    fi

    local _repo
    _repo=$(make_test_repo)

    # Stage a file where the violation line is suppressed
    stage_file "$_repo" "src/legacy.sh" \
        "#!/usr/bin/env bash
ls .tickets-tracker/  # tickets-boundary-ok"

    local exit_code
    exit_code=$(run_hook "$_repo")
    assert_eq "test_suppression_annotation_exempts: exits 0" "0" "$exit_code"
}

# ============================================================
# TEST 7-12: test_named_allowlist_member_passes_<script>
# Each of the 6 named exclusion-pattern scripts must pass exit 0
# even when the staged content references .tickets-tracker/.
# These scripts classify tracker paths rather than access them.
# ============================================================
_named_member_passes() {
    local _test_name="$1" _member_path="$2"
    if [[ ! -f "$HOOK" ]]; then
        echo "  FAIL: check-tickets-boundary.sh not found (RED — not yet implemented)" >&2
        (( FAIL++ ))
        return
    fi
    local _repo
    _repo=$(make_test_repo)
    mkdir -p "$_repo/$(dirname "$_member_path")"
    # tickets-boundary-fixture (intentional — testing that this allowlisted path passes)
    # shellcheck disable=SC2016  # single quotes intentional: $1 is literal in the generated script
    printf '#!/usr/bin/env bash\ngrep ".tickets-tracker/" "$1"\n' > "$_repo/$_member_path"
    git -C "$_repo" add "$_member_path"
    local _exit
    _exit=$(run_hook "$_repo")
    assert_eq "$_test_name: allowlisted member exits 0" "0" "$_exit"
}

test_compute_diff_hash_passes()    { _named_member_passes "test_compute_diff_hash_passes"    "plugins/dso/scripts/compute-diff-hash.sh"; }
test_emit_review_event_passes()    { _named_member_passes "test_emit_review_event_passes"    "plugins/dso/scripts/emit-review-event.sh"; }
test_suggestion_record_passes()    { _named_member_passes "test_suggestion_record_passes"    "plugins/dso/scripts/suggestion-record.sh"; }
test_retro_gather_passes()         { _named_member_passes "test_retro_gather_passes"         "plugins/dso/scripts/retro-gather.sh"; }
test_capture_review_diff_passes()  { _named_member_passes "test_capture_review_diff_passes"  "plugins/dso/scripts/capture-review-diff.sh"; }
test_skip_review_check_passes()    { _named_member_passes "test_skip_review_check_passes"    "plugins/dso/scripts/skip-review-check.sh"; }

# ============================================================
# TEST 13: test_docs_excluded_via_symlink
# When the hook is invoked via a /tmp symlink (simulating
# pre-commit language:script mode on macOS where /tmp -> /private/tmp),
# a staged file under plugins/dso/docs/ must still be excluded
# and the hook exits 0.
# ============================================================
test_docs_excluded_via_symlink() {
    if [[ ! -f "$HOOK" ]]; then
        echo "  FAIL: check-tickets-boundary.sh not found (RED — not yet implemented)" >&2
        (( FAIL++ ))
        return
    fi

    local _repo _tmplink
    _repo=$(make_test_repo)
    _tmplink=$(mktemp /tmp/check-tickets-boundary-XXXXXX.sh)
    rm -f "$_tmplink"
    ln -s "$HOOK" "$_tmplink"
    _TEST_TMPDIRS+=("$_tmplink")

    mkdir -p "$_repo/plugins/dso/docs"
    # tickets-boundary-fixture (intentional — testing docs/ exclusion via symlink)
    printf 'sprint-next-batch.sh\n' > "$_repo/plugins/dso/docs/ticket-cli-reference.md"
    git -C "$_repo" add "plugins/dso/docs/ticket-cli-reference.md"

    local _exit=0
    ( cd "$_repo" && bash "$_tmplink" 2>/dev/null ) || _exit=$?
    assert_eq "test_docs_excluded_via_symlink: docs/ file exits 0 via symlink invocation" "0" "$_exit"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_direct_tracker_ref_rejected
test_absorbed_script_ref_rejected
test_allowlisted_file_passes
test_docs_path_excluded
test_clean_file_passes
test_suppression_annotation_exempts
test_compute_diff_hash_passes
test_emit_review_event_passes
test_suggestion_record_passes
test_retro_gather_passes
test_capture_review_diff_passes
test_skip_review_check_passes
test_docs_excluded_via_symlink

print_summary
