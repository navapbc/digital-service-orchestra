#!/usr/bin/env bash
# tests/scripts/test-audit-source-consumers.sh
# Behavioral fixture test for plugins/dso/scripts/audit-closure-checks-source-consumers.sh
#
# Testing Mode: RED — confirms the audit script does not yet exist.
# These tests MUST FAIL until audit-closure-checks-source-consumers.sh is implemented.
#
# Story coverage: 7e2c-2f4c-cd95-4e60 (SC4 + SC5 source-file consumer audit)
#
# DDs validated (failing side; T2 makes them pass):
#   DD1 — script exists at plugins/dso/scripts/audit-closure-checks-source-consumers.sh
#   DD2 — pattern sweep: section-name regex, aliases, variable interpolation
#   DD3 — reverse-dep enumeration: static imports + dynamic-load flagging
#   DD4 — six-bucket classification (with tie-break precedence)
#   DD5 — JSON output at <target>/plugins/dso/.audit-output/closure-checks-migration-<ts>.json
#   DD6 — reconciliation up to 5 iterations with RECONCILIATION_INCOMPLETE on overflow
#
# Behavioral pattern: every test follows Given / When / Then against a tempdir
# of fixture source files. Tests invoke the audit script as a subprocess and
# assert on its outputs (stdout, exit code, JSON artifact). No source-file
# grepping inside test functions.
#
# Usage: bash tests/scripts/test-audit-source-consumers.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
AUDIT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/audit-closure-checks-source-consumers.sh"

# Side-channel for the audit subprocess's exit code. The _run_audit helper
# below is called inside `out=$(_run_audit ...)` — i.e. in a subshell — so a
# plain global assignment inside the helper does not propagate back. We write
# the exit code to a sidecar file and read it after the substitution.
_AUDIT_EXIT_FILE="$(mktemp "${TMPDIR:-/tmp}/test-audit-source-consumers-exit.XXXXXX")"
_AUDIT_EXIT=0
trap 'rm -f "$_AUDIT_EXIT_FILE"' EXIT

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-audit-source-consumers.sh ==="

# ── Suite-runner guard: skip when audit script does not exist ─────────────────
# RED tests fail by design (script not found). When auto-discovered by
# run-script-tests.sh, they would break `bash tests/run-all.sh`. Skip with
# exit 0 when audit-closure-checks-source-consumers.sh is absent AND running
# under the suite runner. See tests/scripts/test-migrate-closure-checks.sh
# lines 33-41 for the canonical pattern.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$AUDIT_SCRIPT" ]; then
    echo "SKIP: audit-closure-checks-source-consumers.sh not yet implemented (RED) — tests deferred"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Helper: create a fresh tempdir scoped for this test ──────────────────────
_make_tempdir() {
    local prefix="$1"
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-audit-source-consumers-${prefix}.XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ── Helper: write a fixture file at the given relative path under tempdir ────
# Usage: _write_fixture <tempdir> <relpath> <content>
_write_fixture() {
    local tempdir="$1"
    local relpath="$2"
    local content="$3"
    local fullpath="$tempdir/$relpath"
    mkdir -p "$(dirname "$fullpath")"
    printf '%s\n' "$content" > "$fullpath"
}

# ── Helper: run the audit script against a target and capture exit ───────────
# Usage: _run_audit <target> [extra args...]
# Echoes the stdout; sets _AUDIT_EXIT global with exit code; stderr → /dev/null
_run_audit() {
    local target="$1"
    shift
    local exit_code=0
    local out
    out=$(bash "$AUDIT_SCRIPT" --target "$target" "$@" 2>/dev/null) || exit_code=$?
    # Sidecar write so the value survives the $(...) subshell wrapping.
    printf '%s' "$exit_code" > "$_AUDIT_EXIT_FILE"
    printf '%s' "$out"
}

# Read the most recent _run_audit exit code into _AUDIT_EXIT for assertion.
_load_audit_exit() {
    if [ -s "$_AUDIT_EXIT_FILE" ]; then
        _AUDIT_EXIT=$(cat "$_AUDIT_EXIT_FILE")
    fi
}

# ── Helper: locate the JSON artifact under <target>/plugins/dso/.audit-output/
_latest_audit_json() {
    local target="$1"
    # Return the most-recently-created JSON file matching the schema name.
    # shellcheck disable=SC2012  # ls -1t sorts by mtime; artifact names are controlled.
    ls -1t "$target/plugins/dso/.audit-output"/closure-checks-migration-*.json 2>/dev/null | head -1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Script exists and is executable (RED gate)
#
# Given: nothing
# When:  query filesystem for plugins/dso/scripts/audit-closure-checks-source-consumers.sh
# Then:  file exists AND has executable bit
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: audit script exists and is executable"
test_script_exists_and_executable() {
    if [ -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit-closure-checks-source-consumers.sh exists" "exists" "exists"
    else
        assert_eq "audit-closure-checks-source-consumers.sh exists" "exists" "missing"
    fi
    if [ -x "$AUDIT_SCRIPT" ]; then
        assert_eq "audit-closure-checks-source-consumers.sh is executable" "executable" "executable"
    else
        assert_eq "audit-closure-checks-source-consumers.sh is executable" "executable" "not-executable"
    fi
}
test_script_exists_and_executable

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: --target flag accepted; script enumerates only in-scope files
#
# Given: tempdir with plugins/foo.md, tests/bar.sh, docs/baz.py, unrelated/qux.txt
# When:  script runs with --target <tempdir>
# Then:  stdout enumerates the 3 in-scope files; qux.txt NOT enumerated; exit 0
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: --target flag accepted and enumerates only in-scope files"
test_target_flag_accepted_and_enumerates_files() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t2-target")

    _write_fixture "$tempdir" "plugins/foo.md" "Some plugin doc — ## Closure Checks heading appears here."
    _write_fixture "$tempdir" "tests/bar.sh" "echo 'closure-chk reference'"
    _write_fixture "$tempdir" "docs/baz.py" "section_name = 'Closure Checks'"
    _write_fixture "$tempdir" "unrelated/qux.txt" "Closure Checks should be ignored — wrong extension AND wrong dir"

    local out
    out=$(_run_audit "$tempdir")
    _load_audit_exit

    assert_eq "exit code is 0 with --target flag" "0" "$_AUDIT_EXIT"
    assert_contains "stdout enumerates plugins/foo.md" "plugins/foo.md" "$out"
    assert_contains "stdout enumerates tests/bar.sh" "tests/bar.sh" "$out"
    assert_contains "stdout enumerates docs/baz.py" "docs/baz.py" "$out"
    assert_not_contains "stdout does NOT enumerate unrelated/qux.txt" "qux.txt" "$out"

    assert_pass_if_clean "test_target_flag_accepted_and_enumerates_files"
}
test_target_flag_accepted_and_enumerates_files

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: Pattern sweep — section-name regex (DD2 sub-condition c)
#
# Sub-condition: section-name regex with whitespace tolerance.
#
# Given: plugins/a.md containing canonical `## Closure Checks`
#        plugins/b.md containing whitespace variant `##  Closure  Checks`
# When:  script runs
# Then:  BOTH files appear in match output (whitespace tolerance)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: pattern sweep — section-name regex with whitespace tolerance"
test_pattern_sweep_section_name_regex() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t3-section-regex")

    _write_fixture "$tempdir" "plugins/a.md" "## Closure Checks"
    _write_fixture "$tempdir" "plugins/b.md" "##  Closure  Checks"

    local out
    out=$(_run_audit "$tempdir")

    assert_contains "canonical '## Closure Checks' matched (plugins/a.md)" "plugins/a.md" "$out"
    assert_contains "multi-space '##  Closure  Checks' matched (plugins/b.md)" "plugins/b.md" "$out"

    assert_pass_if_clean "test_pattern_sweep_section_name_regex"
}
test_pattern_sweep_section_name_regex

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: Pattern sweep — aliases (DD2 sub-condition b)
#
# Sub-condition: shorthand aliases `closure-chk` and `cc-items`.
#
# Given: plugins/a.py containing `closure-chk`
#        plugins/b.sh containing `cc-items`
# When:  script runs
# Then:  BOTH alias references are reported
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: pattern sweep — aliases (closure-chk, cc-items)"
test_pattern_sweep_aliases() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t4-aliases")

    _write_fixture "$tempdir" "plugins/a.py" "# legacy alias: closure-chk"
    _write_fixture "$tempdir" "plugins/b.sh" "# legacy alias: cc-items"

    local out
    out=$(_run_audit "$tempdir")

    assert_contains "alias 'closure-chk' matched (plugins/a.py)" "plugins/a.py" "$out"
    assert_contains "alias 'cc-items' matched (plugins/b.sh)" "plugins/b.sh" "$out"

    assert_pass_if_clean "test_pattern_sweep_aliases"
}
test_pattern_sweep_aliases

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: Pattern sweep — variable interpolation hints (DD2 sub-condition a)
#
# Sub-condition: shell `$VAR='Closure Checks'` and Python f-string interpolations.
#
# Given: plugins/a.sh containing `SECTION='Closure Checks'`
#        plugins/b.py containing `f"...Closure Checks..."`
# When:  script runs
# Then:  BOTH interpolations reported
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: pattern sweep — variable interpolation (shell var, Python f-string)"
test_pattern_sweep_variable_interpolation() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t5-interpolation")

    _write_fixture "$tempdir" "plugins/a.sh" "SECTION='Closure Checks'"
    _write_fixture "$tempdir" "plugins/b.py" 'msg = f"section: Closure Checks for {ticket_id}"'

    local out
    out=$(_run_audit "$tempdir")

    assert_contains "shell var interpolation matched (plugins/a.sh)" "plugins/a.sh" "$out"
    assert_contains "Python f-string interpolation matched (plugins/b.py)" "plugins/b.py" "$out"

    assert_pass_if_clean "test_pattern_sweep_variable_interpolation"
}
test_pattern_sweep_variable_interpolation

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: Reverse-dep enumeration — static imports
#
# Given: plugins/a.py with `from closure_checks_module import X` (Python static import)
#        plugins/b.sh with `source $PLUGIN_ROOT/scripts/audit-closure-checks-migration.sh`
#        plugins/c.md with `[ref](../scripts/audit-closure-checks-migration.sh)`
# When:  script runs
# Then:  all three static reverse-dep references reported
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: reverse-dep — static imports (Python import, shell source, markdown link)"
test_reverse_dep_static_imports() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t6-static-deps")

    _write_fixture "$tempdir" "plugins/a.py" "from closure_checks_module import X"
    # shellcheck disable=SC2016  # Fixture content must literally contain '$PLUGIN_ROOT' — no expansion.
    _write_fixture "$tempdir" "plugins/b.sh" 'source $PLUGIN_ROOT/scripts/audit-closure-checks-migration.sh'
    _write_fixture "$tempdir" "plugins/c.md" "See [ref](../scripts/audit-closure-checks-migration.sh) for details."

    local out
    out=$(_run_audit "$tempdir")

    assert_contains "Python static import matched (plugins/a.py)" "plugins/a.py" "$out"
    assert_contains "shell source matched (plugins/b.sh)" "plugins/b.sh" "$out"
    assert_contains "markdown link matched (plugins/c.md)" "plugins/c.md" "$out"

    assert_pass_if_clean "test_reverse_dep_static_imports"
}
test_reverse_dep_static_imports

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: Reverse-dep — dynamic loads flagged with `dynamic_load: true`
#
# AST-level static/dynamic boundary criterion (gap finding 3):
#   STATIC (NOT counted in dynamic_load_count):
#     * importlib.import_module("closure_checks")   — string-literal arg
#     * source "$PLUGIN_ROOT/audit-closure-checks-migration.sh"
#       (literal-ish path with a single $PLUGIN_ROOT or $CLAUDE_PLUGIN_ROOT
#        prefix and a literal trailing path)
#   DYNAMIC (counted in dynamic_load_count, JSON dynamic_load: true):
#     * importlib.import_module(name)                 — variable arg
#     * importlib.import_module(f"{prefix}_checks")   — f-string arg
#     * source "$PLUGIN_ROOT/$VARIABLE"               — compound variable path
#
# T2 implementer MUST encode the AST-level criterion (literal-string arg vs
# non-literal) — a regex-only heuristic over the surface form is insufficient.
#
# Given: plugins/a.py with `importlib.import_module(variable_name)` (variable, not literal)
#        plugins/b.sh with `source "$PLUGIN_ROOT/$VARIABLE"` (compound variable)
# When:  script runs
# Then:  both matches flagged with `dynamic_load: true` in JSON output
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 7: reverse-dep — dynamic loads flagged with dynamic_load: true"
test_reverse_dep_dynamic_loads_flagged() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t7-dynamic")

    _write_fixture "$tempdir" "plugins/a.py" "importlib.import_module(variable_name)"
    # shellcheck disable=SC2016  # Fixture content must literally contain '$PLUGIN_ROOT/$VARIABLE' — no expansion.
    _write_fixture "$tempdir" "plugins/b.sh" 'source "$PLUGIN_ROOT/$VARIABLE"'

    _run_audit "$tempdir" >/dev/null

    local json_path
    json_path=$(_latest_audit_json "$tempdir")

    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "JSON artifact exists for dynamic-load assertions" "exists" "missing"
        assert_pass_if_clean "test_reverse_dep_dynamic_loads_flagged"
        return
    fi

    # Assert both dynamic-load fixtures present with dynamic_load: true.
    # Use python3 for robust JSON parsing — no jq dependency assumption.
    local py_check
    py_check=$(python3 - "$json_path" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
flagged = set()
dl_count = data.get("dynamic_load_count", 0)
for bucket_name, items in (data.get("buckets") or {}).items():
    for item in items:
        if item.get("dynamic_load") is True:
            flagged.add(item.get("file", ""))
# Also include unbucketed_matches if the implementation puts dynamic loads there
for item in data.get("unbucketed_matches") or []:
    if item.get("dynamic_load") is True:
        flagged.add(item.get("file", ""))
print("DYN_COUNT=%d" % dl_count)
print("HAS_PY=%s" % ("yes" if any("plugins/a.py" in f for f in flagged) else "no"))
print("HAS_SH=%s" % ("yes" if any("plugins/b.sh" in f for f in flagged) else "no"))
PY
)

    local has_py has_sh
    has_py=$(echo "$py_check" | awk -F= '/^HAS_PY=/ {print $2}')
    has_sh=$(echo "$py_check" | awk -F= '/^HAS_SH=/ {print $2}')

    assert_eq "plugins/a.py flagged with dynamic_load: true" "yes" "$has_py"
    assert_eq "plugins/b.sh flagged with dynamic_load: true" "yes" "$has_sh"

    assert_pass_if_clean "test_reverse_dep_dynamic_loads_flagged"
}
test_reverse_dep_dynamic_loads_flagged

# ═══════════════════════════════════════════════════════════════════════════════
# Test 8: Six-bucket classification
#
# Given: tempdir with one fixture file per bucket:
#   - section-name-reference       — literal `## Closure Checks` heading
#   - file-path-reference          — reference to `migrate-closure-checks.sh`
#   - semantic-consumer            — code parsing/generating section content
#   - test-asserting-on-structure  — test that asserts section is present
#   - user-facing-copy             — prose mentioning the section to end users
#   - migration-in-progress        — temporary migration comment
# When:  script runs
# Then:  JSON `buckets` map has one match in each of the six bucket arrays
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 8: six-bucket classification"
test_six_bucket_classification() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t8-buckets")

    # section-name-reference: literal heading in plain doc
    _write_fixture "$tempdir" "docs/section-name.md" "## Closure Checks"

    # file-path-reference: doc references migrate-closure-checks.sh
    _write_fixture "$tempdir" "docs/file-path.md" "Run \`migrate-closure-checks.sh\` to migrate."

    # semantic-consumer: shell script parses the section content
    _write_fixture "$tempdir" "plugins/semantic.sh" "# Parses ## Closure Checks items from ticket bodies and feeds verifier."

    # test-asserting-on-structure: test file asserts on schema shape
    # shellcheck disable=SC2016  # Fixture content must literally contain '$body' — no expansion.
    _write_fixture "$tempdir" "tests/structure.sh" 'assert_contains "ticket has closure checks section" "## Closure Checks" "$body"'

    # user-facing-copy: error message prose
    _write_fixture "$tempdir" "plugins/copy.md" "Error: ticket is missing the Closure Checks section. Add a ## Closure Checks heading and retry."

    # migration-in-progress: transitional comment
    _write_fixture "$tempdir" "plugins/transitional.sh" "# MIGRATION-IN-PROGRESS: temporary closure-chk alias retained until v2.0 — see ticket a03c-d55e."

    _run_audit "$tempdir" >/dev/null

    local json_path
    json_path=$(_latest_audit_json "$tempdir")

    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "JSON artifact exists for six-bucket assertions" "exists" "missing"
        assert_pass_if_clean "test_six_bucket_classification"
        return
    fi

    local bucket_check
    bucket_check=$(python3 - "$json_path" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
buckets = data.get("buckets") or {}
expected = [
    "section-name-reference",
    "file-path-reference",
    "semantic-consumer",
    "test-asserting-on-structure",
    "user-facing-copy",
    "migration-in-progress",
]
for name in expected:
    items = buckets.get(name) or []
    # Each bucket should have AT LEAST one match from our fixture
    print("BUCKET[%s]=%d" % (name, len(items)))
PY
)

    local b_section b_path b_semantic b_test b_copy b_migration
    b_section=$(echo "$bucket_check" | awk -F= '/^BUCKET\[section-name-reference\]=/ {print $2}')
    b_path=$(echo "$bucket_check" | awk -F= '/^BUCKET\[file-path-reference\]=/ {print $2}')
    b_semantic=$(echo "$bucket_check" | awk -F= '/^BUCKET\[semantic-consumer\]=/ {print $2}')
    b_test=$(echo "$bucket_check" | awk -F= '/^BUCKET\[test-asserting-on-structure\]=/ {print $2}')
    b_copy=$(echo "$bucket_check" | awk -F= '/^BUCKET\[user-facing-copy\]=/ {print $2}')
    b_migration=$(echo "$bucket_check" | awk -F= '/^BUCKET\[migration-in-progress\]=/ {print $2}')

    assert_ne "section-name-reference bucket has matches" "0" "${b_section:-0}"
    assert_ne "file-path-reference bucket has matches" "0" "${b_path:-0}"
    assert_ne "semantic-consumer bucket has matches" "0" "${b_semantic:-0}"
    assert_ne "test-asserting-on-structure bucket has matches" "0" "${b_test:-0}"
    assert_ne "user-facing-copy bucket has matches" "0" "${b_copy:-0}"
    assert_ne "migration-in-progress bucket has matches" "0" "${b_migration:-0}"

    assert_pass_if_clean "test_six_bucket_classification"
}
test_six_bucket_classification

# ═══════════════════════════════════════════════════════════════════════════════
# Test 9: JSON output to <target>/plugins/dso/.audit-output/
#
# Given: tempdir as target with at least one match-producing fixture
# When:  script runs
# Then:  file <target>/plugins/dso/.audit-output/closure-checks-migration-<ts>.json
#        exists and contains schema fields:
#          audit_run_id, started_at, file_count_scanned, buckets,
#          dynamic_load_count, unbucketed_matches, reconciliation_status
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 9: JSON output schema fields written to plugins/dso/.audit-output/"
test_json_output_to_audit_output_dir() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t9-json")

    _write_fixture "$tempdir" "plugins/seed.md" "## Closure Checks"

    _run_audit "$tempdir" >/dev/null

    local json_path
    json_path=$(_latest_audit_json "$tempdir")

    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "JSON artifact written to plugins/dso/.audit-output/" "exists" "missing"
        assert_pass_if_clean "test_json_output_to_audit_output_dir"
        return
    fi

    # Confirm directory location
    assert_contains "JSON path is under plugins/dso/.audit-output/" \
        "/plugins/dso/.audit-output/closure-checks-migration-" "$json_path"

    # Validate schema fields
    local schema_check
    schema_check=$(python3 - "$json_path" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
required = [
    "audit_run_id",
    "started_at",
    "file_count_scanned",
    "buckets",
    "dynamic_load_count",
    "unbucketed_matches",
    "reconciliation_status",
]
for field in required:
    print("HAS[%s]=%s" % (field, "yes" if field in data else "no"))
PY
)

    local f_run_id f_started f_count f_buckets f_dyn f_unb f_recon
    f_run_id=$(echo "$schema_check"      | awk -F= '/^HAS\[audit_run_id\]=/        {print $2}')
    f_started=$(echo "$schema_check"     | awk -F= '/^HAS\[started_at\]=/          {print $2}')
    f_count=$(echo "$schema_check"       | awk -F= '/^HAS\[file_count_scanned\]=/  {print $2}')
    f_buckets=$(echo "$schema_check"     | awk -F= '/^HAS\[buckets\]=/             {print $2}')
    f_dyn=$(echo "$schema_check"         | awk -F= '/^HAS\[dynamic_load_count\]=/  {print $2}')
    f_unb=$(echo "$schema_check"         | awk -F= '/^HAS\[unbucketed_matches\]=/  {print $2}')
    f_recon=$(echo "$schema_check"       | awk -F= '/^HAS\[reconciliation_status\]=/ {print $2}')

    assert_eq "JSON has audit_run_id"          "yes" "${f_run_id:-no}"
    assert_eq "JSON has started_at"            "yes" "${f_started:-no}"
    assert_eq "JSON has file_count_scanned"    "yes" "${f_count:-no}"
    assert_eq "JSON has buckets"               "yes" "${f_buckets:-no}"
    assert_eq "JSON has dynamic_load_count"    "yes" "${f_dyn:-no}"
    assert_eq "JSON has unbucketed_matches"    "yes" "${f_unb:-no}"
    assert_eq "JSON has reconciliation_status" "yes" "${f_recon:-no}"

    assert_pass_if_clean "test_json_output_to_audit_output_dir"
}
test_json_output_to_audit_output_dir

# ═══════════════════════════════════════════════════════════════════════════════
# Test 10: Audit-output directory is created if absent; existing artifacts NOT overwritten
#
# Given: tempdir without .audit-output/ directory
# When:  script runs twice
# Then:  directory created on first run; two distinct timestamped JSON files
#        exist after both runs (existing file from run 1 NOT overwritten by run 2)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 10: audit-output dir created if absent; existing artifacts preserved"
test_audit_output_dir_created_if_absent() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t10-dir-create")

    _write_fixture "$tempdir" "plugins/seed.md" "## Closure Checks"

    # Confirm the dir does NOT exist yet
    if [ -d "$tempdir/plugins/dso/.audit-output" ]; then
        assert_eq "audit-output dir absent before run 1" "absent" "present"
    fi

    # Run 1
    _run_audit "$tempdir" >/dev/null
    local count_after_1
    count_after_1=$(find "$tempdir/plugins/dso/.audit-output" -name 'closure-checks-migration-*.json' 2>/dev/null | wc -l | tr -d ' ')

    assert_eq "exactly 1 JSON artifact after first run" "1" "${count_after_1:-0}"

    # Sleep 1s so the second run's timestamp differs
    sleep 1

    # Run 2
    _run_audit "$tempdir" >/dev/null
    local count_after_2
    count_after_2=$(find "$tempdir/plugins/dso/.audit-output" -name 'closure-checks-migration-*.json' 2>/dev/null | wc -l | tr -d ' ')

    assert_eq "exactly 2 distinct JSON artifacts after second run (no overwrite)" "2" "${count_after_2:-0}"

    assert_pass_if_clean "test_audit_output_dir_created_if_absent"
}
test_audit_output_dir_created_if_absent

# ═══════════════════════════════════════════════════════════════════════════════
# Test 11: Reconciliation terminates at 5 iterations with RECONCILIATION_INCOMPLETE
#
# Given: fixture crafted so each reconciliation pass surfaces a new match
#        (e.g., audit-mutation marker that adds an alias on each pass).
# When:  script runs
# Then:  reconciliation stops after 5 iterations;
#        stdout contains `RECONCILIATION_INCOMPLETE`;
#        JSON `reconciliation_status` is "incomplete"
#
# Implementation note: the fixture uses a marker file `.audit-mutator` that the
# audit script's reconciliation loop reads as a hook. When `.audit-mutator`
# exists with content `inject-on-pass`, the audit creates a new fixture match
# file at the START of each pass after the first. The audit script implementer
# (T2) may choose any reproducible mechanism — what matters is that this test
# observes the 5-iteration cap and the INCOMPLETE signal.
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 11: reconciliation terminates at max 5 iterations (RECONCILIATION_INCOMPLETE)"
test_reconciliation_max_5_iterations() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t11-reconcile-incomplete")

    # Seed match
    _write_fixture "$tempdir" "plugins/seed.md" "## Closure Checks"

    # Mutator hook: signals the audit script to inject one new fixture file at
    # the start of each reconciliation pass (test infra contract documented
    # in the audit script header at T2 implementation).
    _write_fixture "$tempdir" ".audit-mutator" "inject-on-pass"

    local out exit_code
    out=$(bash "$AUDIT_SCRIPT" --target "$tempdir" 2>/dev/null) || exit_code=$?
    : "${exit_code:=0}"

    # Stdout must contain the RECONCILIATION_INCOMPLETE block
    assert_contains "stdout emits RECONCILIATION_INCOMPLETE" "RECONCILIATION_INCOMPLETE" "$out"

    local json_path
    json_path=$(_latest_audit_json "$tempdir")

    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "JSON artifact exists for reconciliation assertions" "exists" "missing"
        assert_pass_if_clean "test_reconciliation_max_5_iterations"
        return
    fi

    local status
    status=$(python3 - "$json_path" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get("reconciliation_status", ""))
PY
)

    assert_eq "JSON reconciliation_status is 'incomplete' after 5-iter cap" "incomplete" "$status"

    assert_pass_if_clean "test_reconciliation_max_5_iterations"
}
test_reconciliation_max_5_iterations

# ═══════════════════════════════════════════════════════════════════════════════
# Test 12: Reconciliation converges on stable fixture
#
# Given: tempdir with stable fixture (no mutator hook)
# When:  script runs
# Then:  reconciliation converges (second pass produces zero new flags);
#        JSON `reconciliation_status` is "complete"
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 12: reconciliation converges on stable fixture (reconciliation_status: complete)"
test_reconciliation_convergence() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t12-reconcile-complete")

    _write_fixture "$tempdir" "plugins/seed.md" "## Closure Checks"

    _run_audit "$tempdir" >/dev/null

    local json_path
    json_path=$(_latest_audit_json "$tempdir")

    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "JSON artifact exists for convergence assertions" "exists" "missing"
        assert_pass_if_clean "test_reconciliation_convergence"
        return
    fi

    local status
    status=$(python3 - "$json_path" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get("reconciliation_status", ""))
PY
)

    assert_eq "JSON reconciliation_status is 'complete' on stable fixture" "complete" "$status"

    assert_pass_if_clean "test_reconciliation_convergence"
}
test_reconciliation_convergence

# ═══════════════════════════════════════════════════════════════════════════════
# Test 13: Tie-breaking bucket precedence (gap finding 2)
#
# When a single match satisfies MULTIPLE bucket criteria, the classifier MUST
# assign it to the MOST-SPECIFIC bucket per the enumerated precedence order:
#
#   migration-in-progress
#     > test-asserting-on-structure
#       > semantic-consumer
#         > user-facing-copy
#           > section-name-reference
#             > file-path-reference
#
# Example: a test file (tests/structure.sh) whose assertion text contains
# user-facing prose mentioning the section name. The match qualifies for
# `test-asserting-on-structure`, `user-facing-copy`, and `section-name-reference`
# simultaneously. Precedence assigns it to `test-asserting-on-structure`
# (the most-specific applicable bucket).
#
# Given: tempdir/tests/structure.sh with a single match qualifying multiple buckets
# When:  script runs
# Then:  match appears in `test-asserting-on-structure` AND NOT in
#        lower-precedence buckets (user-facing-copy, section-name-reference)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 13: tie-breaking bucket precedence (most-specific wins)"
test_tie_breaking_bucket_precedence() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(_make_tempdir "t13-tiebreak")

    # Single test file: assertion text contains user-facing prose mentioning
    # the section name. Qualifies for test-asserting-on-structure (most specific),
    # user-facing-copy (mid), section-name-reference (least specific).
    # shellcheck disable=SC2016  # Fixture content must literally contain '$body' — no expansion.
    _write_fixture "$tempdir" "tests/structure.sh" \
        'assert_contains "ticket body must contain user-facing closure checks section" "## Closure Checks" "$body"'

    _run_audit "$tempdir" >/dev/null

    local json_path
    json_path=$(_latest_audit_json "$tempdir")

    if [ -z "$json_path" ] || [ ! -f "$json_path" ]; then
        assert_eq "JSON artifact exists for tie-break assertions" "exists" "missing"
        assert_pass_if_clean "test_tie_breaking_bucket_precedence"
        return
    fi

    local tiebreak_check
    tiebreak_check=$(python3 - "$json_path" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
buckets = data.get("buckets") or {}

def has_file(bucket_name, needle):
    for item in buckets.get(bucket_name) or []:
        if needle in (item.get("file") or ""):
            return True
    return False

needle = "tests/structure.sh"
print("IN_TEST_BUCKET=%s"   % ("yes" if has_file("test-asserting-on-structure", needle) else "no"))
print("IN_USER_COPY=%s"     % ("yes" if has_file("user-facing-copy", needle) else "no"))
print("IN_SECTION_NAME=%s"  % ("yes" if has_file("section-name-reference", needle) else "no"))
PY
)

    local in_test in_copy in_section
    in_test=$(echo "$tiebreak_check"    | awk -F= '/^IN_TEST_BUCKET=/   {print $2}')
    in_copy=$(echo "$tiebreak_check"    | awk -F= '/^IN_USER_COPY=/     {print $2}')
    in_section=$(echo "$tiebreak_check" | awk -F= '/^IN_SECTION_NAME=/  {print $2}')

    assert_eq "match assigned to test-asserting-on-structure (most specific)" "yes" "${in_test:-no}"
    assert_eq "match NOT in user-facing-copy (lower precedence)"              "no"  "${in_copy:-yes}"
    assert_eq "match NOT in section-name-reference (lowest precedence)"       "no"  "${in_section:-yes}"

    assert_pass_if_clean "test_tie_breaking_bucket_precedence"
}
test_tie_breaking_bucket_precedence

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
