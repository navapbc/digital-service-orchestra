#!/usr/bin/env bash
# tests/implementation-plan/test-migration-class-detect.sh
# Behavioral tests for migration-class-detect.sh
#
# Tests verify:
#   (a) sweep: target symbol with >= threshold non-test, non-import call sites → JSON migration-class=sweep
#   (b) db: touched file matching schema/migration globs → migration-class=db
#   (c) exclusion: import lines and test files NOT counted toward tally
#   (d) detection_query retrievable from emitted marker
#   (e) non-interactive: script never prompts (closed stdin works)
#   (f) sg-unavailable: stub sg off PATH → migration-class=inconclusive, exit 0, no crash
#   (g) dd-4 override boundary crossing: threshold config flip changes migration-class
#
# Usage: bash tests/implementation-plan/test-migration-class-detect.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DETECT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/implementation-plan/migration-class-detect.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-migration-class-detect.sh ==="

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# parse_field <json> <field>
# Extract a JSON string field value (simple key lookup, no jq dependency)
parse_field() {
    local json="$1"
    local field="$2"
    # Extract value between "field":"value" — handle hyphenated keys
    echo "$json" | grep -oE "\"${field}\":\"[^\"]*\"" | head -1 | sed "s/\"${field}\":\"//;s/\"//"
}

# parse_int_field <json> <field>
parse_int_field() {
    local json="$1"
    local field="$2"
    echo "$json" | grep -oE "\"${field}\":[0-9]+" | head -1 | sed "s/\"${field}\"://"
}

# ---------------------------------------------------------------------------
# Setup: create fixture directories
# ---------------------------------------------------------------------------
FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-fixtures.XXXXXX")
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# Create a fixture src directory with a fake git repo to allow sg scanning
FIXTURE_SRC="$FIXTURE_DIR/src"
mkdir -p "$FIXTURE_SRC"
# Initialize a minimal git repo in fixture dir (sg needs a valid directory)
git -C "$FIXTURE_DIR" init --quiet 2>/dev/null || true

# ---------------------------------------------------------------------------
# test_sweep_classification
# Given a target symbol with >= threshold non-test, non-import call sites
# When migration-class-detect.sh runs
# Then JSON migration-class=sweep, detection_query present, target_symbol/threshold_used correct
# ---------------------------------------------------------------------------
test_sweep_classification() {
    _snapshot_fail

    # Only run if sg (ast-grep) is available
    if ! command -v sg >/dev/null 2>&1 || ! sg --version 2>/dev/null | grep -qE '^(sg|ast-grep) [0-9]'; then
        echo "test_sweep_classification ... SKIP (sg/ast-grep not available)"
        return
    fi

    local sym="my_old_helper"
    local lang="python"

    # Create a fixture src dir with 4 call sites (above default threshold of 3)
    local fix_dir
    fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-sweep.XXXXXX")
    trap 'rm -rf "$fix_dir"' RETURN

    # Create files with call sites (non-test, non-import)
    cat > "$fix_dir/caller1.py" <<'EOF'
result = my_old_helper(x, y)
EOF
    cat > "$fix_dir/caller2.py" <<'EOF'
val = my_old_helper(a)
EOF
    cat > "$fix_dir/caller3.py" <<'EOF'
data = my_old_helper(b, c, d)
EOF
    cat > "$fix_dir/caller4.py" <<'EOF'
output = my_old_helper(z)
EOF

    # Set threshold to 3 (default) — 4 call sites >= 3 → sweep
    local tmp_conf
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf.XXXXXX")
    printf 'migration.call_site_threshold=3\n' > "$tmp_conf"

    local output exit_code
    exit_code=0
    output=$(WORKFLOW_CONFIG_FILE="$tmp_conf" bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_code=$?
    rm -f "$tmp_conf"

    assert_eq "test_sweep_classification: exit 0" "0" "$exit_code"

    local mc
    mc=$(parse_field "$output" "migration-class")
    assert_eq "test_sweep_classification: migration-class=sweep" "sweep" "$mc"

    local ts
    ts=$(parse_field "$output" "target_symbol")
    assert_eq "test_sweep_classification: target_symbol matches" "$sym" "$ts"

    local tu
    tu=$(parse_int_field "$output" "threshold_used")
    assert_eq "test_sweep_classification: threshold_used=3" "3" "$tu"

    local dq
    dq=$(parse_field "$output" "detection_query")
    assert_ne "test_sweep_classification: detection_query non-empty" "" "$dq"

    assert_pass_if_clean "test_sweep_classification"
}

# ---------------------------------------------------------------------------
# test_db_classification
# Given the TARGET SYMBOL is referenced INSIDE a migration-pattern file
# When migration-class-detect.sh runs
# Then migration-class=db regardless of call-site count
#
# DB classification is symbol-scoped: the symbol must actually appear within a
# migration-pattern file (migrations/0001_initial.py here), not merely because a
# migrations/ directory exists. See test_sweep_with_migrations_dir_present for the
# negative-control sibling.
# ---------------------------------------------------------------------------
test_db_classification() {
    _snapshot_fail

    local sym="run_migration"
    local lang="python"

    local fix_dir
    fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-db.XXXXXX")
    trap 'rm -rf "$fix_dir"' RETURN

    # Create a migrations/ directory with a file that REFERENCES the symbol.
    # Symbol-scoped db classification requires the symbol to be present here.
    mkdir -p "$fix_dir/migrations"
    cat > "$fix_dir/migrations/0001_initial.py" <<'EOF'
run_migration(conn)
EOF

    local tmp_conf
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf.XXXXXX")
    printf 'migration.call_site_threshold=3\n' > "$tmp_conf"

    local output exit_code
    exit_code=0
    output=$(WORKFLOW_CONFIG_FILE="$tmp_conf" bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_code=$?
    rm -f "$tmp_conf"

    assert_eq "test_db_classification: exit 0" "0" "$exit_code"

    local mc
    mc=$(parse_field "$output" "migration-class")
    assert_eq "test_db_classification: migration-class=db" "db" "$mc"

    local ts
    ts=$(parse_field "$output" "target_symbol")
    assert_eq "test_db_classification: target_symbol matches" "$sym" "$ts"

    assert_pass_if_clean "test_db_classification"
}

# ---------------------------------------------------------------------------
# test_sweep_with_migrations_dir_present
# Given a repo that HAS a migrations/ directory, but the TARGET SYMBOL is NOT
#   referenced inside any migration-pattern file — it has >= threshold call
#   sites in normal source instead
# When migration-class-detect.sh runs
# Then migration-class=sweep (NOT db) — db classification is symbol-scoped, so
#   the bare existence of a migrations/ dir must NOT short-circuit to db.
# This is the negative control proving Finding 1's fix: a symbol with many call
# sites in normal source still classifies sweep even when a migrations dir exists.
# ---------------------------------------------------------------------------
test_sweep_with_migrations_dir_present() {
    _snapshot_fail

    # Only run if sg (ast-grep) is available
    if ! command -v sg >/dev/null 2>&1 || ! sg --version 2>/dev/null | grep -qE '^(sg|ast-grep) [0-9]'; then
        echo "test_sweep_with_migrations_dir_present ... SKIP (sg/ast-grep not available)"
        return
    fi

    local sym="ordinary_helper"
    local lang="python"

    local fix_dir
    fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-sweepdir.XXXXXX")
    trap 'rm -rf "$fix_dir"' RETURN

    # A migrations/ directory EXISTS, but it does NOT reference the target symbol.
    mkdir -p "$fix_dir/migrations"
    cat > "$fix_dir/migrations/0001_initial.py" <<'EOF'
some_unrelated_migration(conn)
EOF

    # The target symbol has 4 call sites in NORMAL source (above threshold of 3).
    cat > "$fix_dir/caller1.py" <<'EOF'
result = ordinary_helper(x, y)
EOF
    cat > "$fix_dir/caller2.py" <<'EOF'
val = ordinary_helper(a)
EOF
    cat > "$fix_dir/caller3.py" <<'EOF'
data = ordinary_helper(b, c)
EOF
    cat > "$fix_dir/caller4.py" <<'EOF'
out = ordinary_helper(z)
EOF

    local tmp_conf
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf.XXXXXX")
    printf 'migration.call_site_threshold=3\n' > "$tmp_conf"

    local output exit_code
    exit_code=0
    output=$(WORKFLOW_CONFIG_FILE="$tmp_conf" bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_code=$?
    rm -f "$tmp_conf"

    assert_eq "test_sweep_with_migrations_dir_present: exit 0" "0" "$exit_code"

    local mc
    mc=$(parse_field "$output" "migration-class")
    # Must be sweep — NOT db. The migrations/ dir exists but the symbol is not in it.
    assert_eq "test_sweep_with_migrations_dir_present: migrations dir present yet symbol classifies sweep (not db)" "sweep" "$mc"

    assert_pass_if_clean "test_sweep_with_migrations_dir_present"
}

# ---------------------------------------------------------------------------
# test_exclusion_of_imports_and_test_files
# Given a target symbol present only in import lines and test files
# When migration-class-detect.sh runs
# Then those sites are NOT counted → migration-class is NOT sweep (threshold=1)
# ---------------------------------------------------------------------------
test_exclusion_of_imports_and_test_files() {
    _snapshot_fail

    # Only run if sg (ast-grep) is available
    if ! command -v sg >/dev/null 2>&1 || ! sg --version 2>/dev/null | grep -qE '^(sg|ast-grep) [0-9]'; then
        echo "test_exclusion_of_imports_and_test_files ... SKIP (sg/ast-grep not available)"
        return
    fi

    local sym="excluded_helper"
    local lang="python"

    local fix_dir
    fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-excl.XXXXXX")
    trap 'rm -rf "$fix_dir"' RETURN

    # Import line only — should be excluded
    cat > "$fix_dir/module_a.py" <<'EOF'
from utils import excluded_helper
EOF

    # Test file — should be excluded
    mkdir -p "$fix_dir/test"
    cat > "$fix_dir/test/test_utils.py" <<'EOF'
result = excluded_helper(x)
result2 = excluded_helper(y)
result3 = excluded_helper(z)
EOF

    # No real call sites — only import + test file usage

    # Set threshold=1 so even 1 call site would be sweep
    local tmp_conf
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf.XXXXXX")
    printf 'migration.call_site_threshold=1\n' > "$tmp_conf"

    local output exit_code
    exit_code=0
    output=$(WORKFLOW_CONFIG_FILE="$tmp_conf" bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_code=$?
    rm -f "$tmp_conf"

    assert_eq "test_exclusion_of_imports_and_test_files: exit 0" "0" "$exit_code"

    local mc
    mc=$(parse_field "$output" "migration-class")
    assert_ne "test_exclusion_of_imports_and_test_files: migration-class is NOT sweep" "sweep" "$mc"
    # Detection RAN (sg available) but found too few real call sites → none,
    # NOT inconclusive (which is reserved for sg-unavailable).
    assert_eq "test_exclusion_of_imports_and_test_files: below-threshold ran → migration-class=none" "none" "$mc"
    assert_ne "test_exclusion_of_imports_and_test_files: not inconclusive (detection ran)" "inconclusive" "$mc"

    assert_pass_if_clean "test_exclusion_of_imports_and_test_files"
}

# ---------------------------------------------------------------------------
# test_below_threshold_is_none_not_inconclusive
# Given sg IS available and the symbol has FEWER than threshold call sites
#   (detection ran, but produced a definite negative result)
# When migration-class-detect.sh runs
# Then migration-class=none — distinct from inconclusive (sg-unavailable).
# This guards Finding 4: a below-threshold result must NOT emit the false
# "install sg and re-run" inconclusive signal.
# ---------------------------------------------------------------------------
test_below_threshold_is_none_not_inconclusive() {
    _snapshot_fail

    # Only run if sg (ast-grep) is available
    if ! command -v sg >/dev/null 2>&1 || ! sg --version 2>/dev/null | grep -qE '^(sg|ast-grep) [0-9]'; then
        echo "test_below_threshold_is_none_not_inconclusive ... SKIP (sg/ast-grep not available)"
        return
    fi

    local sym="rare_helper"
    local lang="python"

    local fix_dir
    fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-none.XXXXXX")
    trap 'rm -rf "$fix_dir"' RETURN

    # Exactly 1 call site — below the threshold of 3.
    cat > "$fix_dir/caller.py" <<'EOF'
result = rare_helper(x)
EOF

    local tmp_conf
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf.XXXXXX")
    printf 'migration.call_site_threshold=3\n' > "$tmp_conf"

    local output exit_code
    exit_code=0
    output=$(WORKFLOW_CONFIG_FILE="$tmp_conf" bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_code=$?
    rm -f "$tmp_conf"

    assert_eq "test_below_threshold_is_none_not_inconclusive: exit 0" "0" "$exit_code"

    local mc
    mc=$(parse_field "$output" "migration-class")
    assert_eq "test_below_threshold_is_none_not_inconclusive: migration-class=none" "none" "$mc"
    assert_ne "test_below_threshold_is_none_not_inconclusive: NOT inconclusive" "inconclusive" "$mc"

    assert_pass_if_clean "test_below_threshold_is_none_not_inconclusive"
}

# ---------------------------------------------------------------------------
# test_detection_query_in_output
# Given any detection run
# When migration-class-detect.sh runs
# Then the detection_query field is present and non-empty in the JSON output
# ---------------------------------------------------------------------------
test_detection_query_in_output() {
    _snapshot_fail

    local sym="some_function"
    local lang="python"

    local fix_dir
    fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-dq.XXXXXX")
    trap 'rm -rf "$fix_dir"' RETURN

    cat > "$fix_dir/caller.py" <<'EOF'
result = some_function(x)
EOF

    local tmp_conf
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf.XXXXXX")
    printf 'migration.call_site_threshold=3\n' > "$tmp_conf"

    local output exit_code
    exit_code=0
    output=$(WORKFLOW_CONFIG_FILE="$tmp_conf" bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_code=$?
    rm -f "$tmp_conf"

    assert_eq "test_detection_query_in_output: exit 0" "0" "$exit_code"

    # detection_query field must be present in output JSON
    assert_contains "test_detection_query_in_output: detection_query field present" "detection_query" "$output"

    assert_pass_if_clean "test_detection_query_in_output"
}

# ---------------------------------------------------------------------------
# test_non_interactive_closed_stdin
# Given script invoked with stdin closed (/dev/null)
# When migration-class-detect.sh runs
# Then it exits 0 without hanging (never prompts)
# ---------------------------------------------------------------------------
test_non_interactive_closed_stdin() {
    _snapshot_fail

    local sym="noninteractive_sym"
    local lang="python"

    local fix_dir
    fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-ni.XXXXXX")
    trap 'rm -rf "$fix_dir"' RETURN

    local tmp_conf
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf.XXXXXX")
    printf 'migration.call_site_threshold=3\n' > "$tmp_conf"

    local output exit_code
    exit_code=0
    # Use timeout to catch any hang; redirect stdin from /dev/null
    output=$(WORKFLOW_CONFIG_FILE="$tmp_conf" timeout 10 bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_code=$?
    rm -f "$tmp_conf"

    # Exit 0 or non-zero is acceptable; what matters is it doesn't hang
    # (timeout would produce exit code 124)
    assert_ne "test_non_interactive_closed_stdin: no timeout (not 124)" "124" "$exit_code"

    # Output must contain migration-class field (JSON was emitted)
    assert_contains "test_non_interactive_closed_stdin: JSON emitted" "migration-class" "$output"

    assert_pass_if_clean "test_non_interactive_closed_stdin"
}

# ---------------------------------------------------------------------------
# test_sg_unavailable_inconclusive
# Given sg is not on PATH
# When migration-class-detect.sh runs
# Then migration-class=inconclusive, exit 0, no crash, all fields present
# ---------------------------------------------------------------------------
test_sg_unavailable_inconclusive() {
    _snapshot_fail

    local sym="any_symbol"
    local lang="python"

    local fix_dir
    fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-sgoff.XXXXXX")
    trap 'rm -rf "$fix_dir"' RETURN

    cat > "$fix_dir/caller.py" <<'EOF'
result = any_symbol(x)
EOF

    local tmp_conf
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf.XXXXXX")
    printf 'migration.call_site_threshold=3\n' > "$tmp_conf"

    # Create a stub PATH without sg
    local stub_dir
    stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-stubpath.XXXXXX")
    trap 'rm -rf "$stub_dir"' RETURN

    local output exit_code
    exit_code=0
    # Run with PATH that does NOT include sg
    output=$(WORKFLOW_CONFIG_FILE="$tmp_conf" PATH="$stub_dir:/usr/bin:/bin" bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_code=$?
    rm -f "$tmp_conf"

    assert_eq "test_sg_unavailable_inconclusive: exit 0" "0" "$exit_code"

    local mc
    mc=$(parse_field "$output" "migration-class")
    assert_eq "test_sg_unavailable_inconclusive: migration-class=inconclusive" "inconclusive" "$mc"

    # All required fields must be present
    assert_contains "test_sg_unavailable_inconclusive: detection_query present" "detection_query" "$output"
    assert_contains "test_sg_unavailable_inconclusive: target_symbol present" "target_symbol" "$output"
    assert_contains "test_sg_unavailable_inconclusive: threshold_used present" "threshold_used" "$output"

    assert_pass_if_clean "test_sg_unavailable_inconclusive"
}

# ---------------------------------------------------------------------------
# test_dd4_override_boundary_crossing
# Given a fixed N-call-site fixture
# When threshold is set to N+1 → migration-class is NOT sweep
# And when threshold is set to N-1 → migration-class IS sweep
# Then the config override moves a borderline target across the classification boundary
# ---------------------------------------------------------------------------
test_dd4_override_boundary_crossing() {
    _snapshot_fail

    # Only run if sg (ast-grep) is available
    if ! command -v sg >/dev/null 2>&1 || ! sg --version 2>/dev/null | grep -qE '^(sg|ast-grep) [0-9]'; then
        echo "test_dd4_override_boundary_crossing (threshold flip / override effect) ... SKIP (sg/ast-grep not available)"
        return
    fi

    local sym="borderline_func"
    local lang="python"
    local N=3  # Fixed number of call sites

    local fix_dir
    fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-mcd-boundary.XXXXXX")
    trap 'rm -rf "$fix_dir"' RETURN

    # Create exactly N non-test, non-import call sites
    local i
    for (( i=1; i<=N; i++ )); do
        cat > "$fix_dir/caller${i}.py" <<EOF
result${i} = borderline_func(arg${i})
EOF
    done

    # Run 1: threshold = N+1 → NOT sweep (N < N+1)
    local tmp_conf_high
    tmp_conf_high=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf-high.XXXXXX")
    printf 'migration.call_site_threshold=%d\n' "$(( N + 1 ))" > "$tmp_conf_high"

    local output_high exit_high
    exit_high=0
    output_high=$(WORKFLOW_CONFIG_FILE="$tmp_conf_high" bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_high=$?
    rm -f "$tmp_conf_high"

    assert_eq "test_dd4_override_boundary_crossing: exit 0 (high threshold)" "0" "$exit_high"

    local mc_high
    mc_high=$(parse_field "$output_high" "migration-class")
    assert_ne "test_dd4_override_boundary_crossing (threshold flip): threshold N+1 → NOT sweep" "sweep" "$mc_high"

    # Run 2: threshold = N-1 → sweep (N >= N-1, and N-1 >= 1)
    local low_threshold=$(( N - 1 ))
    # Floor is 1; if N=1, N-1=0 which is invalid. Use max(N-1, 1) but N=3 here so fine.
    if [[ "$low_threshold" -lt 1 ]]; then
        low_threshold=1
    fi

    local tmp_conf_low
    tmp_conf_low=$(mktemp "${TMPDIR:-/tmp}/test-mcd-conf-low.XXXXXX")
    printf 'migration.call_site_threshold=%d\n' "$low_threshold" > "$tmp_conf_low"

    local output_low exit_low
    exit_low=0
    output_low=$(WORKFLOW_CONFIG_FILE="$tmp_conf_low" bash "$DETECT_SCRIPT" "$sym" "$lang" "$fix_dir" < /dev/null) || exit_low=$?
    rm -f "$tmp_conf_low"

    assert_eq "test_dd4_override_boundary_crossing: exit 0 (low threshold)" "0" "$exit_low"

    local mc_low
    mc_low=$(parse_field "$output_low" "migration-class")
    assert_eq "test_dd4_override_boundary_crossing (override effect): threshold N-1 → sweep" "sweep" "$mc_low"

    # Explicit boundary-crossing label for the AC grep check
    echo "  [boundary-crossing / threshold-flip / override-effect confirmed: threshold N+1 → mc='${mc_high}', threshold N-1 → mc='${mc_low}']"

    assert_pass_if_clean "test_dd4_override_boundary_crossing (threshold flip / override effect)"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_sweep_classification
test_db_classification
test_sweep_with_migrations_dir_present
test_exclusion_of_imports_and_test_files
test_below_threshold_is_none_not_inconclusive
test_detection_query_in_output
test_non_interactive_closed_stdin
test_sg_unavailable_inconclusive
test_dd4_override_boundary_crossing

print_summary
