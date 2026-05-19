#!/usr/bin/env bash
# tests/scripts/test-bug-classification-stats.sh
# RED-phase tests for plugins/dso/scripts/bug-classification-stats.sh
# All tests must FAIL until bug-classification-stats.sh is implemented.
#
# Usage: bash tests/scripts/test-bug-classification-stats.sh
# Returns: exit 1 (RED — target script does not exist yet)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/bug-classification-stats.sh"
REGISTRY_JSON="$REPO_ROOT/plugins/dso/docs/bug-classification-registry.json"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bug-classification-stats.sh ==="

# ── Shared temp dir ──────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: script exists
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_script_exists ---"
_snapshot_fail

if [[ -f "$TARGET_SCRIPT" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: %s to exist\n  actual:   file not found\n" \
        "test_script_exists" "$TARGET_SCRIPT" >&2
fi

assert_pass_if_clean "test_script_exists"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: --window-days flag works (empty ticket list → exit 0)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_window_days_flag ---"
_snapshot_fail

MOCK_EMPTY="$TMPDIR_TEST/mock-ticket-empty.sh"
cat > "$MOCK_EMPTY" << 'EOF'
#!/usr/bin/env bash
# Mock TICKET_CMD: accepts any args, returns empty JSON array
echo '[]'
EOF
chmod +x "$MOCK_EMPTY"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: script to exist so --window-days can be tested\n  actual:   script not found at %s\n" \
        "test_window_days_flag" "$TARGET_SCRIPT" >&2
else
    rc=0
    TICKET_CMD="$MOCK_EMPTY" bash "$TARGET_SCRIPT" --window-days 30 >/dev/null 2>&1 || rc=$?
    assert_eq "test_window_days_flag exits 0" "0" "$rc"
fi

assert_pass_if_clean "test_window_days_flag"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: aggregates bug-type tags from tickets
# Two scope-drift bugs and one skill-guidance-gap bug → output shows counts
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_aggregates_bug_type_tags ---"
_snapshot_fail

MOCK_BUGS="$TMPDIR_TEST/mock-ticket-bugs.sh"
cat > "$MOCK_BUGS" << 'EOF'
#!/usr/bin/env bash
# Mock TICKET_CMD: returns 3 bugs with bug-type tags
echo '[
  {"ticket_id":"b1","ticket_type":"bug","status":"closed","tags":["bug-type-scope-drift"]},
  {"ticket_id":"b2","ticket_type":"bug","status":"closed","tags":["bug-type-scope-drift"]},
  {"ticket_id":"b3","ticket_type":"bug","status":"closed","tags":["bug-type-skill-guidance-gap"]}
]'
EOF
chmod +x "$MOCK_BUGS"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: script to exist so tag aggregation can be tested\n  actual:   script not found at %s\n" \
        "test_aggregates_bug_type_tags (scope-drift count)" "$TARGET_SCRIPT" >&2
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: script to exist so tag aggregation can be tested\n  actual:   script not found at %s\n" \
        "test_aggregates_bug_type_tags (skill-guidance-gap count)" "$TARGET_SCRIPT" >&2
else
    output=""
    output=$(TICKET_CMD="$MOCK_BUGS" bash "$TARGET_SCRIPT" --window-days 60 2>/dev/null) || true
    assert_contains "test_aggregates_bug_type_tags scope-drift count 2" "2" "$output"
    assert_contains "test_aggregates_bug_type_tags scope-drift label" "scope-drift" "$output"
    assert_contains "test_aggregates_bug_type_tags skill-guidance-gap label" "skill-guidance-gap" "$output"
    assert_contains "test_aggregates_bug_type_tags skill-guidance-gap count 1" "1" "$output"
fi

assert_pass_if_clean "test_aggregates_bug_type_tags"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: uncategorized reported separately
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_uncategorized_reported ---"
_snapshot_fail

MOCK_UNCAT="$TMPDIR_TEST/mock-ticket-uncat.sh"
cat > "$MOCK_UNCAT" << 'EOF'
#!/usr/bin/env bash
# Mock TICKET_CMD: returns 1 bug tagged uncategorized
echo '[
  {"ticket_id":"b4","ticket_type":"bug","status":"closed","tags":["bug-type-uncategorized"]}
]'
EOF
chmod +x "$MOCK_UNCAT"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: script to exist so uncategorized reporting can be tested\n  actual:   script not found at %s\n" \
        "test_uncategorized_reported (label)" "$TARGET_SCRIPT" >&2
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: script to exist so uncategorized reporting can be tested\n  actual:   script not found at %s\n" \
        "test_uncategorized_reported (count)" "$TARGET_SCRIPT" >&2
else
    output=""
    output=$(TICKET_CMD="$MOCK_UNCAT" bash "$TARGET_SCRIPT" --window-days 30 2>/dev/null) || true
    assert_contains "test_uncategorized_reported label present" "uncategorized" "$output"
    assert_contains "test_uncategorized_reported count present" "1" "$output"
fi

assert_pass_if_clean "test_uncategorized_reported"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: classifier-failed reported
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_classifier_failed_reported ---"
_snapshot_fail

MOCK_CFAIL="$TMPDIR_TEST/mock-ticket-cfail.sh"
cat > "$MOCK_CFAIL" << 'EOF'
#!/usr/bin/env bash
# Mock TICKET_CMD: returns 1 bug tagged classifier-failed-schema
echo '[
  {"ticket_id":"b5","ticket_type":"bug","status":"closed","tags":["bug-type-classifier-failed-schema"]}
]'
EOF
chmod +x "$MOCK_CFAIL"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: script to exist so classifier-failed reporting can be tested\n  actual:   script not found at %s\n" \
        "test_classifier_failed_reported (label)" "$TARGET_SCRIPT" >&2
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: script to exist so classifier-failed reporting can be tested\n  actual:   script not found at %s\n" \
        "test_classifier_failed_reported (count)" "$TARGET_SCRIPT" >&2
else
    output=""
    output=$(TICKET_CMD="$MOCK_CFAIL" bash "$TARGET_SCRIPT" --window-days 30 2>/dev/null) || true
    assert_contains "test_classifier_failed_reported label present" "classifier-failed" "$output"
    assert_contains "test_classifier_failed_reported count present" "1" "$output"
fi

assert_pass_if_clean "test_classifier_failed_reported"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: uses registry JSON (not markdown) — registry file must exist
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_registry_json_exists ---"
_snapshot_fail

if [[ -f "$REGISTRY_JSON" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: %s to exist (stats script depends on it as slug list source)\n  actual:   file not found\n" \
        "test_registry_json_exists" "$REGISTRY_JSON" >&2
fi

assert_pass_if_clean "test_registry_json_exists"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: window filtering — tickets older than window-days are excluded
# Recent ticket (30 days old) with scope-drift tag is counted;
# old ticket (90 days old) with scope-drift tag is excluded.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_window_days_filters_old_tickets ---"
_snapshot_fail

RECENT_TS=$(python3 -c "import time; print(int((time.time() - 30 * 86400) * 1e9))")
OLD_TS=$(python3 -c "import time; print(int((time.time() - 90 * 86400) * 1e9))")

MOCK_WINDOW="$TMPDIR_TEST/mock-ticket-window.sh"
cat > "$MOCK_WINDOW" << EOF
#!/usr/bin/env bash
echo '[
  {"ticket_id":"w1","ticket_type":"bug","status":"closed","created_at":${RECENT_TS},"tags":["bug-type-scope-drift"]},
  {"ticket_id":"w2","ticket_type":"bug","status":"closed","created_at":${OLD_TS},"tags":["bug-type-scope-drift"]}
]'
EOF
chmod +x "$MOCK_WINDOW"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    (( ++FAIL ))
    printf "FAIL: %s\n  expected: script to exist so window filtering can be tested\n  actual:   script not found at %s\n" \
        "test_window_days_filters_old_tickets" "$TARGET_SCRIPT" >&2
else
    output=""
    output=$(TICKET_CMD="$MOCK_WINDOW" bash "$TARGET_SCRIPT" --window-days 60 2>/dev/null) || true
    # With --window-days 60 only the 30-day-old ticket should be counted → count=1
    assert_eq "test_window_days_filters_old_tickets count is 1 (recent only)" "1 scope-drift" \
        "$(echo "$output" | grep scope-drift || echo 'missing')"
fi

assert_pass_if_clean "test_window_days_filters_old_tickets"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
