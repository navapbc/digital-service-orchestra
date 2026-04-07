#!/usr/bin/env bash
# tests/scripts/test-check-referential-integrity.sh
# Behavioral tests for check-referential-integrity.sh — file-existence linting
# for path references in skill/agent/workflow markdown files.
#
# Tests:
#  1. test_valid_reference            — ref to existing script → exit 0
#  2. test_broken_reference           — ref to nonexistent script → exit 1
#  3. test_broken_reference_reported  — exit 1 AND output contains broken ref name
#  4. test_shim_exempt_skipped        — broken ref + # shim-exempt: → exit 0
#  5. test_broken_agent_reference     — ref to nonexistent agent .md → exit 1
#  6. test_broken_contract_reference  — ref to nonexistent docs/contracts file → exit 1
#  7. test_no_references              — clean .md with no path patterns → exit 0
#  8. test_code_fence_skipped         — broken ref inside fenced code block → exit 0
#  9. test_real_files_pass            — run against actual skill/agent files → exit 0
#
# Usage: bash tests/scripts/test-check-referential-integrity.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# REVIEW-DEFENSE: '-e' is intentionally omitted. The test harness captures
# non-zero exit codes from script invocations via || assignment. With '-e',
# expected non-zero exits would abort the script before assertions run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-referential-integrity.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-referential-integrity.sh ==="

_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap '_cleanup' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── test_valid_reference ───────────────────────────────────────────────────────
# A markdown file referencing a path that actually exists in the repo must cause
# check-referential-integrity.sh to exit 0.
test_valid_reference() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/valid-ref.md"
    # check-shim-refs.sh is a real file in the repo
    printf '# My Skill\n\nSee plugins/dso/scripts/check-shim-refs.sh for details.\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --repo-root "$PLUGIN_ROOT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_valid_reference: exit 0 for existing reference" "0" "$_exit"
    assert_pass_if_clean "test_valid_reference"
}

# ── test_broken_reference ──────────────────────────────────────────────────────
# A markdown file referencing a path that does NOT exist must cause the script
# to exit 1.
test_broken_reference() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/broken-ref.md"
    printf '# My Skill\n\nRun plugins/dso/scripts/nonexistent-script.sh to proceed.\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --repo-root "$PLUGIN_ROOT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_broken_reference: exit non-zero for missing file" "0" "$_exit"
    assert_pass_if_clean "test_broken_reference"
}

# ── test_broken_reference_reported ────────────────────────────────────────────
# When a broken reference is found, the script must report the referenced path
# in its output so the user knows what is missing.
test_broken_reference_reported() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/broken-ref-reported.md"
    printf '# My Skill\n\nSee plugins/dso/scripts/nonexistent-script.sh for usage.\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --repo-root "$PLUGIN_ROOT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_broken_reference_reported: exit non-zero" "0" "$_exit"
    assert_contains "test_broken_reference_reported: broken path reported in output" "nonexistent-script.sh" "$_out"
    assert_pass_if_clean "test_broken_reference_reported"
}

# ── test_shim_exempt_skipped ──────────────────────────────────────────────────
# A line containing a broken reference but also carrying # shim-exempt: must be
# skipped — the script must exit 0 for that file.
test_shim_exempt_skipped() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/shim-exempt.md"
    printf '# My Skill\n\nSee plugins/dso/scripts/nonexistent-script.sh for details. # shim-exempt: intentional example\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --repo-root "$PLUGIN_ROOT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_shim_exempt_skipped: exit 0 when shim-exempt comment present" "0" "$_exit"
    assert_pass_if_clean "test_shim_exempt_skipped"
}

# ── test_broken_agent_reference ───────────────────────────────────────────────
# A markdown file referencing a nonexistent agent .md file must cause the script
# to exit 1 — the pattern applies to agents/ paths as well as scripts/.
test_broken_agent_reference() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/broken-agent-ref.md"
    printf '# My Skill\n\nDispatches to plugins/dso/agents/nonexistent.md at runtime.\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --repo-root "$PLUGIN_ROOT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_broken_agent_reference: exit non-zero for missing agent .md" "0" "$_exit"
    assert_pass_if_clean "test_broken_agent_reference"
}

# ── test_broken_contract_reference ────────────────────────────────────────────
# A markdown file referencing a nonexistent docs/contracts file must cause the
# script to exit 1.
test_broken_contract_reference() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/broken-contract-ref.md"
    printf '# My Skill\n\nSee plugins/dso/docs/contracts/nonexistent.md for the schema.\n' > "$_file"
    _exit=0
    _out=$(bash "$SCRIPT" --repo-root "$PLUGIN_ROOT" "$_file" 2>&1) || _exit=$?
    assert_ne "test_broken_contract_reference: exit non-zero for missing docs/contracts file" "0" "$_exit"
    assert_pass_if_clean "test_broken_contract_reference"
}

# ── test_no_references ────────────────────────────────────────────────────────
# A markdown file containing no path pattern matches must exit 0 — no references
# means no violations.
test_no_references() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/no-refs.md"
    cat > "$_file" << 'EOF'
# My Skill

Use `/dso:sprint` to run epics.
Use `.claude/scripts/dso ticket list` to view tickets.
No plugins/dso path references here of the linted type.
EOF
    _exit=0
    _out=$(bash "$SCRIPT" --repo-root "$PLUGIN_ROOT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_no_references: exit 0 for file with no path patterns" "0" "$_exit"
    assert_pass_if_clean "test_no_references"
}

# ── test_code_fence_skipped ───────────────────────────────────────────────────
# A broken path reference that appears inside a triple-backtick fenced code block
# must be skipped — the script must exit 0 for that file.
test_code_fence_skipped() {
    _snapshot_fail
    local _dir _file _exit _out
    _dir=$(_make_tmpdir)
    _file="$_dir/code-fence.md"
    cat > "$_file" << 'EOF'
# My Skill

Example of what NOT to do:

```bash
bash plugins/dso/scripts/nonexistent-script.sh
```

The above is shown for illustration only.
EOF
    _exit=0
    _out=$(bash "$SCRIPT" --repo-root "$PLUGIN_ROOT" "$_file" 2>&1) || _exit=$?
    assert_eq "test_code_fence_skipped: exit 0 for reference inside fenced code block" "0" "$_exit"
    assert_pass_if_clean "test_code_fence_skipped"
}

# ── test_real_files_pass ──────────────────────────────────────────────────────
# Running check-referential-integrity.sh against the actual skill and agent files
# in this repository must exit 0 — all referenced paths in those files must exist.
test_real_files_pass() {
    _snapshot_fail
    local _exit _out
    _exit=0
    # Pass the real skill and agent dirs; the script scans them by default when
    # no file args are given, but we pass --repo-root to anchor path resolution.
    _out=$(bash "$SCRIPT" --repo-root "$PLUGIN_ROOT" 2>&1) || _exit=$?
    assert_eq "test_real_files_pass: exit 0 when scanning actual repo files" "0" "$_exit"
    assert_pass_if_clean "test_real_files_pass"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_valid_reference
test_broken_reference
test_broken_reference_reported
test_shim_exempt_skipped
test_broken_agent_reference
test_broken_contract_reference
test_no_references
test_code_fence_skipped
test_real_files_pass

print_summary
