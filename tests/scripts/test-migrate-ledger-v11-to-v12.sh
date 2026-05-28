#!/usr/bin/env bash
# shellcheck source=tests/lib/assert.sh
# tests/scripts/test-migrate-ledger-v11-to-v12.sh
# RED-phase behavioral tests for plugins/dso/scripts/migrate-ledger-v11-to-v12.sh
#
# All tests FAIL until the script is implemented (RED gate confirmed by task b611-c854-a2a7-412d).
#
# .test-index marker: [test_migrate_ledger_v11_to_v12]
#
# The script migrates existing cycle-ledger.json files from v1.1.0 → v1.2.0:
#   1. Reads a v1.1.0 ledger (schema_version="1.1.0", no pr_number field on cycles)
#   2. Writes back schema_version="1.2.0" with pr_number=0 (sentinel) on each cycle entry
#   3. Is idempotent: re-running on an already-migrated v1.2.0 ledger is a no-op
#   4. Preserves all existing v1.2.0 cycle entries unchanged (mixed-format safety)
#   5. Logs malformed entries but does NOT abort migration
#
# Usage: bash tests/scripts/test-migrate-ledger-v11-to-v12.sh
# Returns: exit 0 if all tests PASS, exit 1 if any FAIL

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/migrate-ledger-v11-to-v12.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-migrate-ledger-v11-to-v12.sh ==="

# ── Shared tmpdir registry — all cleaned up on EXIT ──────────────────────────
_TMP_DIRS=()
trap 'rm -rf "${_TMP_DIRS[@]:-}"' EXIT

_make_tmpdir() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/test-migrate-ledger-v11-to-v12.XXXXXX")"
    _TMP_DIRS+=("$d")
    echo "$d"
}

# ── Fixture builders ─────────────────────────────────────────────────────────

# Write a v1.1.0 ledger (no pr_number field) to $1/cycle-ledger.json
_write_v11_ledger() {
    local dir="$1"
    cat > "$dir/cycle-ledger.json" <<'JSON'
{
  "schema_version": "1.1.0",
  "epic_id": "test-epic-abc",
  "cycles": [
    {
      "cycle_num": 1,
      "timestamp_utc": "2026-05-16T10:00:00Z",
      "commit_sha": "aabbccddee1122334455667788990011aabbccdd",
      "findings": [["src/foo.py", "10-20", "correctness"]],
      "findings_hash": "h1hash",
      "halt_reason": null
    },
    {
      "cycle_num": 2,
      "timestamp_utc": "2026-05-16T12:00:00Z",
      "commit_sha": "bbccddee11223344556677889900aabbccddee11",
      "findings": [],
      "findings_hash": "h2hash",
      "halt_reason": "STABLE_HALT"
    }
  ]
}
JSON
}

# Write a v1.2.0 ledger (pr_number present) to $1/cycle-ledger.json
_write_v12_ledger() {
    local dir="$1"
    cat > "$dir/cycle-ledger.json" <<'JSON'
{
  "schema_version": "1.2.0",
  "epic_id": "test-epic-xyz",
  "cycles": [
    {
      "cycle_num": 1,
      "timestamp_utc": "2026-05-17T09:00:00Z",
      "commit_sha": "ccddee11223344556677889900aabbccddee1122",
      "findings": [["src/bar.py", "5-10", "security"]],
      "findings_hash": "h3hash",
      "pr_number": 99,
      "halt_reason": null
    }
  ]
}
JSON
}

# ── Test 1: script exists ────────────────────────────────────────────────────
# RED: migrate-ledger-v11-to-v12.sh does not exist yet.
# This test fails until task S_mig.T2 implements the script.
_snapshot_fail
if [[ -f "$SCRIPT" ]]; then _exists="yes"; else _exists="no"; fi
assert_eq \
    "test_migrate_ledger_v11_to_v12: migrate-ledger-v11-to-v12.sh script exists" \
    "yes" "$_exists"
assert_pass_if_clean "test_migrate_ledger_v11_to_v12"

# ── Test 2: v1.1.0 ledger migrated to v1.2.0 with sentinel pr_number=0 ──────
# Given a v1.1.0 cycle-ledger.json, after migration:
#   - schema_version == "1.2.0"
#   - every cycle entry has pr_number == 0  (the sentinel for "pre-v1.2.0 origin")
#   - all existing fields (cycle_num, commit_sha, findings, findings_hash, halt_reason)
#     are preserved
#
# RED: script does not exist → bash call fails → all sub-assertions fail.
_snapshot_fail
_dir_t2="$(_make_tmpdir)"
_write_v11_ledger "$_dir_t2"
_ledger_path_t2="$_dir_t2/cycle-ledger.json"

_exit_t2=0
bash "$SCRIPT" "$_ledger_path_t2" >/dev/null 2>&1 || _exit_t2=$?
assert_eq \
    "test_migrate_ledger_v11_to_v12: exits 0 on v1.1.0 input" \
    "0" "$_exit_t2"

# schema_version bumped to 1.2.0
_schema_t2=""
_schema_t2=$(python3 -c "
import json, sys
try:
    print(json.load(open('$_ledger_path_t2'))['schema_version'])
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: schema_version is 1.2.0 after migration" \
    "1.2.0" "$_schema_t2"

# cycle 1 gets pr_number=0 sentinel
_pr_num_c1=""
_pr_num_c1=$(python3 -c "
import json, sys
try:
    c = json.load(open('$_ledger_path_t2'))['cycles']
    entry = next((e for e in c if e['cycle_num'] == 1), None)
    if entry is None:
        print('__MISSING_CYCLE__')
    else:
        print(entry.get('pr_number', '__MISSING__'))
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: cycle 1 pr_number=0 sentinel assigned" \
    "0" "$_pr_num_c1"

# cycle 2 also gets pr_number=0 sentinel
_pr_num_c2=""
_pr_num_c2=$(python3 -c "
import json, sys
try:
    c = json.load(open('$_ledger_path_t2'))['cycles']
    entry = next((e for e in c if e['cycle_num'] == 2), None)
    if entry is None:
        print('__MISSING_CYCLE__')
    else:
        print(entry.get('pr_number', '__MISSING__'))
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: cycle 2 pr_number=0 sentinel assigned" \
    "0" "$_pr_num_c2"

# commit_sha preserved for cycle 1
_sha_c1=""
_sha_c1=$(python3 -c "
import json
try:
    c = json.load(open('$_ledger_path_t2'))['cycles']
    entry = next((e for e in c if e['cycle_num'] == 1), None)
    print(entry.get('commit_sha', '__MISSING__') if entry else '__MISSING_CYCLE__')
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: commit_sha preserved after migration" \
    "aabbccddee1122334455667788990011aabbccdd" "$_sha_c1"

# halt_reason preserved for cycle 2
_halt_c2=""
_halt_c2=$(python3 -c "
import json
try:
    c = json.load(open('$_ledger_path_t2'))['cycles']
    entry = next((e for e in c if e['cycle_num'] == 2), None)
    print(entry.get('halt_reason', '__MISSING__') if entry else '__MISSING_CYCLE__')
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: halt_reason preserved for cycle 2" \
    "STABLE_HALT" "$_halt_c2"

assert_pass_if_clean "test_migrate_ledger_v11_to_v12_sentinel_assignment"

# ── Test 3: idempotency — second run on already-migrated v1.2.0 ledger ───────
# Re-running migrate-ledger-v11-to-v12.sh on a v1.2.0 ledger is a no-op:
#   - exits 0
#   - does not change schema_version (stays "1.2.0")
#   - does not change pr_number values (stays 99, not overwritten to 0)
#   - does not add duplicate cycle entries
#
# RED: script does not exist → bash call fails → all assertions fail.
_snapshot_fail
_dir_t3="$(_make_tmpdir)"
_write_v12_ledger "$_dir_t3"
_ledger_path_t3="$_dir_t3/cycle-ledger.json"

# Capture mtime before first run (via content hash — mtime is platform-specific)
_content_before=""
_content_before=$(python3 -c "import json; print(json.dumps(json.load(open('$_ledger_path_t3')), sort_keys=True))" 2>&1)

# First idempotent run
_exit_t3_r1=0
bash "$SCRIPT" "$_ledger_path_t3" >/dev/null 2>&1 || _exit_t3_r1=$?
assert_eq \
    "test_migrate_ledger_v11_to_v12: idempotent first run exits 0 on v1.2.0 input" \
    "0" "$_exit_t3_r1"

# Second idempotent run
_exit_t3_r2=0
bash "$SCRIPT" "$_ledger_path_t3" >/dev/null 2>&1 || _exit_t3_r2=$?
assert_eq \
    "test_migrate_ledger_v11_to_v12: re-run second-run exits 0 (idempotent)" \
    "0" "$_exit_t3_r2"

# pr_number not overwritten to sentinel (must stay 99)
_pr_after_rerun=""
_pr_after_rerun=$(python3 -c "
import json
try:
    c = json.load(open('$_ledger_path_t3'))['cycles']
    entry = next((e for e in c if e['cycle_num'] == 1), None)
    print(entry.get('pr_number', '__MISSING__') if entry else '__MISSING_CYCLE__')
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: idempotent re-run preserves existing pr_number=99 (not overwritten to 0)" \
    "99" "$_pr_after_rerun"

# cycle count unchanged (no duplicates added)
_cycle_count=""
_cycle_count=$(python3 -c "
import json
try:
    print(len(json.load(open('$_ledger_path_t3'))['cycles']))
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: idempotent re-run does not add duplicate cycle entries" \
    "1" "$_cycle_count"

# schema_version still 1.2.0 after re-run
_schema_after_rerun=""
_schema_after_rerun=$(python3 -c "
import json
try:
    print(json.load(open('$_ledger_path_t3'))['schema_version'])
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: idempotent re-run schema_version stays 1.2.0" \
    "1.2.0" "$_schema_after_rerun"

assert_pass_if_clean "test_migrate_ledger_v11_to_v12_idempotency"

# ── Test 4: sentinel rule — v1.1.0 entries readable as legacy via pr_number=0 ─
# After migration, the sentinel pr_number=0 marks entries as originating before
# v1.2.0 PR-keying. Consumers (e.g. arbiter) can detect legacy entries by
# checking pr_number == 0.  This test verifies the observable contract:
#   - migrated entries have pr_number == 0 (readable as legacy via sentinel)
#   - entries with pr_number > 0 are native v1.2.0 (non-sentinel)
#
# This test uses a mixed-format ledger: one v1.1.0 entry AND one pre-existing
# v1.2.0 entry with pr_number=42. After migration:
#   - v1.1.0-origin entry → pr_number=0 (sentinel; legacy-readable)
#   - v1.2.0-origin entry → pr_number=42 (untouched; natively-keyed)
#
# RED: script does not exist → assertions fail.
_snapshot_fail
_dir_t4="$(_make_tmpdir)"

# Write a mixed-format ledger: one pre-existing v1.2.0 entry (cycle 2, pr_number=42)
# alongside one v1.1.0-style entry (cycle 1, no pr_number).
cat > "$_dir_t4/cycle-ledger.json" <<'JSON'
{
  "schema_version": "1.1.0",
  "epic_id": "test-epic-mixed",
  "cycles": [
    {
      "cycle_num": 1,
      "timestamp_utc": "2026-05-16T08:00:00Z",
      "commit_sha": "aaaa1111bbbb2222cccc3333dddd4444eeee5555",
      "findings": [],
      "findings_hash": "oldhash",
      "halt_reason": null
    },
    {
      "cycle_num": 2,
      "timestamp_utc": "2026-05-17T14:00:00Z",
      "commit_sha": "ffff6666aaaa1111bbbb2222cccc3333dddd4444",
      "findings": [["src/baz.py", "30-35", "correctness"]],
      "findings_hash": "newhash",
      "pr_number": 42,
      "halt_reason": null
    }
  ]
}
JSON
_ledger_path_t4="$_dir_t4/cycle-ledger.json"

_exit_t4=0
bash "$SCRIPT" "$_ledger_path_t4" >/dev/null 2>&1 || _exit_t4=$?
assert_eq \
    "test_migrate_ledger_v11_to_v12: mixed-format migration exits 0" \
    "0" "$_exit_t4"

# Cycle 1 (no prior pr_number) → gets sentinel 0
_pr_mixed_c1=""
_pr_mixed_c1=$(python3 -c "
import json
try:
    c = json.load(open('$_ledger_path_t4'))['cycles']
    entry = next((e for e in c if e['cycle_num'] == 1), None)
    print(entry.get('pr_number', '__MISSING__') if entry else '__MISSING_CYCLE__')
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: sentinel rule — v1.1.0 entry gets pr_number=0" \
    "0" "$_pr_mixed_c1"

# Cycle 2 (already has pr_number=42) → preserved unchanged
_pr_mixed_c2=""
_pr_mixed_c2=$(python3 -c "
import json
try:
    c = json.load(open('$_ledger_path_t4'))['cycles']
    entry = next((e for e in c if e['cycle_num'] == 2), None)
    print(entry.get('pr_number', '__MISSING__') if entry else '__MISSING_CYCLE__')
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: sentinel rule — v1.2.0 entry pr_number=42 preserved" \
    "42" "$_pr_mixed_c2"

# schema_version bumped to 1.2.0 even when the ledger had mixed entries
_schema_t4=""
_schema_t4=$(python3 -c "
import json
try:
    print(json.load(open('$_ledger_path_t4'))['schema_version'])
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: mixed-format — schema_version bumped to 1.2.0" \
    "1.2.0" "$_schema_t4"

assert_pass_if_clean "test_migrate_ledger_v11_to_v12_sentinel_rule"

# ── Test 5: malformed entry — logged but does not abort migration ────────────
# A cycle entry that is not a JSON object (or has missing required fields) must
# be logged to stderr but must NOT cause the script to exit non-zero or skip
# the remaining valid entries.
#
# RED: script does not exist → bash call fails → assertions fail.
_snapshot_fail
_dir_t5="$(_make_tmpdir)"

cat > "$_dir_t5/cycle-ledger.json" <<'JSON'
{
  "schema_version": "1.1.0",
  "epic_id": "test-epic-malformed",
  "cycles": [
    {
      "cycle_num": 1,
      "timestamp_utc": "2026-05-16T10:00:00Z",
      "commit_sha": "aaaa1111bbbb2222cccc3333dddd4444eeee5555",
      "findings": [],
      "findings_hash": "h1",
      "halt_reason": null
    },
    "this-is-not-an-object",
    {
      "cycle_num": 3,
      "timestamp_utc": "2026-05-16T11:00:00Z",
      "commit_sha": "bbbb2222cccc3333dddd4444eeee5555ffff6666",
      "findings": [],
      "findings_hash": "h3",
      "halt_reason": null
    }
  ]
}
JSON
_ledger_path_t5="$_dir_t5/cycle-ledger.json"

_exit_t5=0
_stderr_t5=""
_stderr_t5=$(bash "$SCRIPT" "$_ledger_path_t5" 2>&1 >/dev/null) || _exit_t5=$?

# Must still exit 0 despite the malformed entry
assert_eq \
    "test_migrate_ledger_v11_to_v12: malformed entry does not abort migration (exits 0)" \
    "0" "$_exit_t5"

# Valid entries must still be migrated (cycle 1 and 3 get pr_number=0)
_pr_t5_c1=""
_pr_t5_c1=$(python3 -c "
import json
try:
    d = json.load(open('$_ledger_path_t5'))
    c = [e for e in d['cycles'] if isinstance(e, dict) and e.get('cycle_num') == 1]
    print(c[0].get('pr_number', '__MISSING__') if c else '__MISSING_CYCLE__')
except Exception as e:
    print('__ERROR__: ' + str(e))
" 2>&1)
assert_eq \
    "test_migrate_ledger_v11_to_v12: malformed entry — valid cycle 1 still migrated (pr_number=0)" \
    "0" "$_pr_t5_c1"

assert_pass_if_clean "test_migrate_ledger_v11_to_v12_malformed_entry"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
