#!/usr/bin/env bash
# tests/scripts/test-scan-config-keys.sh
# Behavioral test for plugins/dso/scripts/scan-config-keys.sh
#
# Contract under test:
#   scan-config-keys.sh <repo-root>
#     - Scans 4 locations for config key usages:
#         (1) read-config.sh calls (e.g., `read-config.sh some.key`)
#         (2) inline _read_config_key calls (e.g., `_read_config_key "other.key"`)
#         (3) inline grep patterns (e.g., `grep '^namespace.example=' .claude/dso-config.conf`)
#         (4) keys present in .claude/dso-config.conf
#     - Outputs a gap list of keys used in code but NOT documented in
#       plugins/dso/docs/CONFIGURATION-REFERENCE.md
#     - Exits 0 on success
#
# RED state: scan-config-keys.sh does not exist yet. Tests fail until implementation
#            is provided (task following e4cf-92a3 in epic 91f5-0aec).
#
# Usage: bash tests/scripts/test-scan-config-keys.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/scan-config-keys.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-scan-config-keys.sh ==="

# ── Fixture setup ──────────────────────────────────────────────────────────────
# Use mktemp -d for isolation; clean up on EXIT.
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
}
trap '_cleanup_tmpdirs' EXIT

_FIXTURE_REPO="$(mktemp -d)"
_TEST_TMPDIRS+=("$_FIXTURE_REPO")

# Create the directory structure the script will scan.
mkdir -p "$_FIXTURE_REPO/plugins/dso/scripts"
mkdir -p "$_FIXTURE_REPO/plugins/dso/docs"
mkdir -p "$_FIXTURE_REPO/.claude"

# (a) Script that calls read-config.sh with a key.
cat > "$_FIXTURE_REPO/plugins/dso/scripts/caller-a.sh" <<'EOF'
#!/usr/bin/env bash
val=$(bash read-config.sh some.key)
echo "$val"
EOF

# (b) Script that uses inline _read_config_key.
cat > "$_FIXTURE_REPO/plugins/dso/scripts/caller-b.sh" <<'EOF'
#!/usr/bin/env bash
val=$(_read_config_key "other.key")
echo "$val"
EOF

# (c) Script that uses inline grep against dso-config.conf.
cat > "$_FIXTURE_REPO/plugins/dso/scripts/caller-c.sh" <<'EOF'
#!/usr/bin/env bash
val=$(grep '^namespace.example=' .claude/dso-config.conf | cut -d= -f2)
echo "$val"
EOF

# (d) .claude/dso-config.conf — contains a documented key and an undocumented key.
cat > "$_FIXTURE_REPO/.claude/dso-config.conf" <<'EOF'
documented.key=value
namespace.example=val
EOF

# (e) CONFIGURATION-REFERENCE.md — documents only documented.key.
cat > "$_FIXTURE_REPO/plugins/dso/docs/CONFIGURATION-REFERENCE.md" <<'EOF'
# Configuration Reference

## Keys

### documented.key

Description of documented.key.
EOF

# ── test_scan_config_keys_gap_list ─────────────────────────────────────────────
# Given: fixture repo with 3 undocumented keys and 1 documented key (above)
# When: scan-config-keys.sh is invoked with the fixture repo root
# Then: exits 0, prints gap list containing some.key / other.key / namespace.example,
#       does NOT contain documented.key
test_scan_config_keys_gap_list() {
    local exit_code=0
    local output=""

    output=$(_PLUGIN_GIT_PATH=plugins/dso bash "$SCRIPT" "$_FIXTURE_REPO" 2>&1) || exit_code=$?

    # (1) Script must exit 0
    assert_eq "test_scan_config_keys_gap_list: exits 0" "0" "$exit_code"

    # (2) Gap list must include all 3 undocumented keys
    assert_contains "test_scan_config_keys_gap_list: gap list includes some.key" \
        "some.key" "$output"

    assert_contains "test_scan_config_keys_gap_list: gap list includes other.key" \
        "other.key" "$output"

    assert_contains "test_scan_config_keys_gap_list: gap list includes namespace.example" \
        "namespace.example" "$output"

    # (3) Gap list must NOT include documented.key
    if [[ "$output" == *"documented.key"* ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  documented.key must NOT appear in gap list\n  actual output: %s\n" \
            "test_scan_config_keys_gap_list: documented.key absent from gap list" "$output" >&2
    else
        (( ++PASS ))
    fi
}

test_scan_config_keys_gap_list

# ── test_scan_config_keys_excludes_worktrees ────────────────────────────────────
# Given: fixture repo with a .claude/worktrees/ subdir containing files that
#        reference config keys (simulating a stale test worktree left by a prior run)
# When: scan-config-keys.sh is invoked
# Then: keys from .claude/worktrees/ are NOT included in the gap list
test_scan_config_keys_excludes_worktrees() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    mkdir -p "$tmpdir/plugins/dso/scripts"
    mkdir -p "$tmpdir/plugins/dso/docs"
    mkdir -p "$tmpdir/.claude"
    mkdir -p "$tmpdir/.claude/worktrees/test-99999/tests/scripts"

    # No real plugin code — only documented.key is used in the plugin tree
    cat > "$tmpdir/plugins/dso/scripts/real-caller.sh" <<'EOF'
#!/usr/bin/env bash
val=$(_read_config_key "documented.key")
EOF

    # Stale worktree contains a test file that uses an undocumented key
    cat > "$tmpdir/.claude/worktrees/test-99999/tests/scripts/fixture.sh" <<'EOF'
#!/usr/bin/env bash
val=$(grep '^stale.worktree.key=' .claude/dso-config.conf | cut -d= -f2)
EOF

    cat > "$tmpdir/plugins/dso/docs/CONFIGURATION-REFERENCE.md" <<'EOF'
# Configuration Reference

### documented.key

Description.
EOF

    local exit_code=0
    local output=""
    output=$(_PLUGIN_GIT_PATH=plugins/dso bash "$SCRIPT" "$tmpdir" 2>&1) || exit_code=$?

    assert_eq "test_scan_config_keys_excludes_worktrees: exits 0" "0" "$exit_code"

    if [[ "$output" == *"stale.worktree.key"* ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  stale.worktree.key from .claude/worktrees/ must NOT appear in gap list\n  actual output: %s\n" \
            "test_scan_config_keys_excludes_worktrees: worktree keys excluded" "$output" >&2
    else
        (( ++PASS ))
        printf "test_scan_config_keys_excludes_worktrees: worktree keys excluded ... PASS\n"
    fi
}

test_scan_config_keys_excludes_worktrees

print_summary
