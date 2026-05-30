#!/usr/bin/env bash
# tests/scripts/test-check-mktemp-tmpdir.sh
# Tests for plugins/dso/scripts/check-mktemp-tmpdir.sh
#
# Covers the Finding 6 coverage-gap fix: the linter must now flag the
# `mktemp [-d] /tmp/...` anti-pattern in ANY *.sh under tests/ (not just
# `test-*.sh`), must exclude deliberate fixtures, must honor the
# `# mktemp-tmpdir-ok` suppression marker, and must accept the
# `${TMPDIR:-/tmp}` form.
#
# Usage: bash tests/scripts/test-check-mktemp-tmpdir.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/plugins/dso/scripts/check-mktemp-tmpdir.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-check-mktemp-tmpdir.sh ==="

# Build a self-contained mini "tests/" tree in an isolated workspace so the
# fixtures we feed the linter never live in the real tree (which would trip
# the linter itself / pre-commit). The linter resolves REPO_ROOT via
# `git rev-parse --show-toplevel || "."`; running it with cwd in a non-git
# temp dir makes REPO_ROOT="." so relative `tests/...` paths resolve here.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-mktemp-tmpdir-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tests/sub" "$WORK/tests/sub/fixtures"

# The fixture files below must contain the literal `mktemp .. /tmp/`
# anti-pattern. We assemble those lines with the shared-temp segment held in
# $SL so THIS test's own source never contains the contiguous matchable token
# (otherwise the linter — which now scans all tests/*.sh — would flag this
# very file). The suppression marker can't be used inside the heredocs: it
# would leak into the generated fixtures and defeat the detection cases.
SL='/tmp'

# Underscore-named test file with the anti-pattern (the case the old
# hyphen-only glob silently exempted).
printf '%s\n' '#!/usr/bin/env bash' "d=\$(mktemp -d $SL/bad-thing.XXXXXX)" \
    > "$WORK/tests/sub/test_bad_underscore.sh"

# Support file (run.sh) with the anti-pattern, no quotes.
printf '%s\n' '#!/usr/bin/env bash' "f=\$(mktemp $SL/run-thing.XXXXXX)" \
    > "$WORK/tests/sub/run.sh"

# Compliant file using the ${TMPDIR:-/tmp} form.
cat > "$WORK/tests/sub/test-good.sh" <<'EOF'
#!/usr/bin/env bash
d=$(mktemp -d "${TMPDIR:-/tmp}/good-thing.XXXXXX")
EOF

# Anti-pattern present but suppressed via the marker. Generated (not a heredoc
# literal) so this test's own source stays clean.
printf '%s\n' '#!/usr/bin/env bash' \
    "d=\$(mktemp -d $SL/legit-exception.XXXXXX) # mktemp-tmpdir-ok" \
    > "$WORK/tests/sub/test-suppressed.sh"

# Deliberate anti-pattern fixture under fixtures/ — must be ignored.
printf '%s\n' '#!/usr/bin/env bash' "d=\$(mktemp -d $SL/fixture-thing.XXXXXX)" \
    > "$WORK/tests/sub/fixtures/bad-fixture.sh"

run_check() { ( cd "$WORK" && bash "$CHECK" "$@" >/dev/null 2>&1 ); echo $?; }

# ── test_flags_underscore_named_file ─────────────────────────────────────────
_snapshot_fail
rc="$(run_check tests/sub/test_bad_underscore.sh)"
assert_eq "test_flags_underscore_named_file: exit 1" "1" "$rc"
assert_pass_if_clean "test_flags_underscore_named_file"

# ── test_flags_support_run_sh ────────────────────────────────────────────────
_snapshot_fail
rc="$(run_check tests/sub/run.sh)"
assert_eq "test_flags_support_run_sh: exit 1" "1" "$rc"
assert_pass_if_clean "test_flags_support_run_sh"

# ── test_passes_tmpdir_form ──────────────────────────────────────────────────
_snapshot_fail
rc="$(run_check tests/sub/test-good.sh)"
assert_eq "test_passes_tmpdir_form: exit 0" "0" "$rc"
assert_pass_if_clean "test_passes_tmpdir_form"

# ── test_honors_suppression_marker ───────────────────────────────────────────
_snapshot_fail
rc="$(run_check tests/sub/test-suppressed.sh)"
assert_eq "test_honors_suppression_marker: exit 0" "0" "$rc"
assert_pass_if_clean "test_honors_suppression_marker"

# ── test_excludes_fixtures ───────────────────────────────────────────────────
_snapshot_fail
rc="$(run_check tests/sub/fixtures/bad-fixture.sh)"
assert_eq "test_excludes_fixtures: exit 0" "0" "$rc"
assert_pass_if_clean "test_excludes_fixtures"

# ── test_default_scan_finds_violation ────────────────────────────────────────
# No args → default scan over tests/**/*.sh (excluding fixtures/) must find
# the bad underscore + run.sh files and exit 1.
_snapshot_fail
rc="$(run_check)"
assert_eq "test_default_scan_finds_violation: exit 1" "1" "$rc"
assert_pass_if_clean "test_default_scan_finds_violation"

# ── test_real_tree_is_clean ──────────────────────────────────────────────────
# The actual repository tree must have zero violations after remediation.
_snapshot_fail
real_rc=0
( cd "$REPO_ROOT" && bash "$CHECK" ) >/dev/null 2>&1 || real_rc=$?
assert_eq "test_real_tree_is_clean: exit 0" "0" "$real_rc"
assert_pass_if_clean "test_real_tree_is_clean"

print_summary
