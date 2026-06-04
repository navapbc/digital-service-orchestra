#!/usr/bin/env bash
# tests/scripts/test-coverage-ledger-cache-key.sh — story 7b77 (CF-6) DD1/DD3
#
# Config-invariant guard: the review-coverage-ledger cache must be RESTORABLE across
# re-runs (warm-hit), which requires the restore-keys to be run_id-FREE (a run_id in
# the restore path makes every re-run cold-start — the CF-6 wedge risk). The SAVE
# `key` may carry run_id (Actions caches are immutable per key); only the restore
# path must be stable. Asserts the workflow config, not runtime behavior.
#
#   C1  the cache step exists with a restore-keys block
#   C2  NO restore-keys line contains github.run_id (stable restore)
#   C3  the restore-keys are branch-scoped (github.base_ref) so a re-run resolves a
#       prior ledger for the same base

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
YML="$REPO_ROOT/.github/workflows/review-coverage-invariant.yml"  # shim-exempt: test reads the workflow config

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

[[ -f "$YML" ]] || { echo "FAIL: workflow not found: $YML"; exit 1; }

# Extract the restore-keys block: lines after 'restore-keys:' that are deeper-indented
# list/scalar continuations (the review-coverage-ledger-* entries).
_restore_block="$(awk '
    /restore-keys:/ {inblk=1; next}
    inblk {
        if ($0 ~ /review-coverage-ledger-/) { print; next }
        else { inblk=0 }
    }
' "$YML")"

# ── C1: a restore-keys block exists ──────────────────────────────────────────
if [[ -n "$_restore_block" ]]; then _pass "C1_restore_keys_present"; else _fail "C1_restore_keys_present" "no review-coverage-ledger restore-keys found"; fi

# ── C2: no run_id in the restore path (stable warm-hit) ──────────────────────
if ! grep -q "run_id" <<<"$_restore_block"; then _pass "C2_restore_keys_run_id_free"; else _fail "C2_restore_keys_run_id_free" "a restore-key contains github.run_id -> re-runs cold-start: $_restore_block"; fi

# ── C3: restore-keys are branch-scoped ───────────────────────────────────────
if grep -q 'github.base_ref' <<<"$_restore_block"; then _pass "C3_restore_keys_branch_scoped"; else _fail "C3_restore_keys_branch_scoped" "restore-keys not scoped to github.base_ref"; fi

echo ""
echo "=== test-coverage-ledger-cache-key.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
