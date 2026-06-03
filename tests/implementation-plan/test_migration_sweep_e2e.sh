#!/usr/bin/env bash
# tests/implementation-plan/test_migration_sweep_e2e.sh
#
# End-to-end migration-sweep test (story 2bd4, epic dso-uvyl, task 8803).
#
# Drives the REAL deterministic detector
#   plugins/dso/scripts/implementation-plan/migration-class-detect.sh
# against the committed synthetic fixture
#   tests/implementation-plan/fixtures/migration-sweep/
# It does NOT invoke any LLM-driven decomposition path (dd-5 determinism) and
# creates NO new production sweep helper — the completeness re-query reuses the
# detection_query carried in the emitted marker, run inline via `sg`.
#
# Determinism contract (dd-5): no network, no clock, no randomness in the
# assertions. mktemp is used for isolated working copies (path differs per run
# but never appears in the asserted output). Two full runs produce byte-identical
# detector output (asserted by --case determinism).
#
# Stack-generic: the only language-specific input is the fixture (Python) plus
# the pinned `--lang python` used to reconstruct the sg invocation; the harness
# itself makes no assumption about the host project's stack (the DSO plugin repo
# has no app/ and no pytest).
#
# ---------------------------------------------------------------------------
# CASES (run one with --case <name>; bare invocation runs them all):
#   marker       dd-2 (schema level): the detector run on the fixture emits a
#                migration-class:sweep marker carrying the detection_query
#                structural-contract field (the field from which the
#                automated-sweep / manual-verification pair is generated). We
#                assert the SCHEMA-LEVEL field, NOT live LLM pair-emission prose;
#                the live pair-emission consumer (1c2b) need not be live.
#   missed-site  dd-3: simulate the sweep on an mktemp copy leaving the single
#                OMITTED-SITE; an independent `sg` completeness COUNT finds
#                count>=1 remaining → exit NON-ZERO and surface the missed
#                file:line. The completeness rule is "ANY remaining site (>=1)
#                is INCOMPLETE" — it deliberately does NOT reuse detect.sh's
#                >=threshold sweep-classification comparison.
#   clean-sweep  the complement of missed-site: when the sweep ALSO removes the
#                omitted site, the completeness count is 0 → complete → exit 0.
#   baseline     dd-4: POSITIVE DIFFERENTIAL. The current migration-aware run
#                carries the marker + detection_query field; the committed
#                hand-authored baseline-expected.txt carries NEITHER. Asserts
#                the current output is a superset of (differs from) the baseline.
#   determinism  dd-5: two full detector runs on the fixture are byte-identical,
#                AND the sweep-simulation re-query is idempotent / repeatable.
#   sg-skip      dd-7 graceful degradation: with sg removed from PATH the
#                detector emits migration-class:inconclusive; the harness prints
#                the loud token 'SWEEP-E2E-SKIPPED: sg unavailable' and asserts
#                the inconclusive path. (Self-driven: this case stubs PATH so it
#                exercises the skip branch even when sg IS installed.)
#
# ---------------------------------------------------------------------------
# BASELINE REGENERATION (baseline-expected.txt):
#   baseline-expected.txt is HAND-AUTHORED and must NOT be regenerated from tool
#   output — the migration-class feature is already landed, so the live detector
#   ALWAYS emits a marker now and cannot produce a "no-marker baseline". To
#   change the baseline, edit it by hand keeping it free of every token listed
#   in its own INVARIANT header (no migration-class:sweep marker, no
#   automated-sweep, no manual-verification, no "detection_query" field), then
#   re-run this suite and confirm FAILED: 0. See the baseline file header for the
#   full provenance + invariant.
#
# Usage:
#   bash tests/implementation-plan/test_migration_sweep_e2e.sh [--case <name>]
# Exit code: 0 if all asserted invariants hold, non-zero otherwise.
# ---------------------------------------------------------------------------

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DETECT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/implementation-plan/migration-class-detect.sh"
FIXTURE_DIR="$REPO_ROOT/tests/implementation-plan/fixtures/migration-sweep"
FIXTURE_CONFIG="$FIXTURE_DIR/fixture-config.conf"
BASELINE_FILE="$FIXTURE_DIR/baseline-expected.txt"

# Target symbol + language are pinned: the marker's detection_query is a BARE
# ast-grep pattern with no --lang and no path, and lang is NOT recorded in the
# marker, so the completeness re-query must supply --lang explicitly.
TARGET_SYMBOL="legacy_call"
PIN_LANG="python"

# ── Parse --case ──────────────────────────────────────────────────────────────
CASE_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --case)
            CASE_NAME="${2:-}"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--case <name>]" >&2
            exit 2
            ;;
    esac
done

# ── Minimal assertion plumbing (self-contained; no external assert.sh) ────────
_FAILED=0
fail() { echo "FAIL: $*" >&2; _FAILED=$((_FAILED + 1)); }
ok()   { echo "  ok: $*"; }

# ── sg availability ───────────────────────────────────────────────────────────
_have_sg() { command -v sg >/dev/null 2>&1 && sg --version 2>/dev/null | grep -qE '^(sg|ast-grep) [0-9]'; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# parse_field <json> <field> — extract a JSON string field (no jq dependency).
parse_field() {
    echo "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | sed "s/\"$2\":\"//;s/\"$//"
}

# run_detector — run the real detector against the committed fixture with the
# pinned fixture config. Deterministic: same args, same config, same output.
run_detector() {
    WORKFLOW_CONFIG_FILE="$FIXTURE_CONFIG" \
        bash "$DETECT_SCRIPT" "$TARGET_SYMBOL" "$PIN_LANG" "$FIXTURE_DIR" < /dev/null
}

# make_swept_copy <leave_omitted:0|1> — copy the fixture app/ tree into an
# mktemp dir and simulate the sweep:
#   - every legacy_call( call line WITHOUT a '# OMITTED-SITE' marker is rewritten
#     to a migrated_call( line (removing it as a legacy_call match);
#   - the OMITTED-SITE line is preserved when leave_omitted=1, or also rewritten
#     when leave_omitted=0 (clean sweep).
# The rewrite is deterministic and idempotent (re-running on already-swept output
# changes nothing), which is what dd-5 double-run determinism relies on.
# Prints the path to the swept tree on stdout.
make_swept_copy() {
    local leave_omitted="$1"
    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/migration-sweep-e2e.XXXXXX")
    cp -R "$FIXTURE_DIR/app" "$work/app"

    local f
    for f in "$work"/app/*.py; do
        # Rewrite non-omitted call sites: any line containing legacy_call( that
        # does NOT contain the OMITTED-SITE marker becomes migrated_call(.
        # Idempotent: a line already rewritten contains no legacy_call( to match.
        if [[ "$leave_omitted" == "1" ]]; then
            # Preserve the omitted line; rewrite all others.
            sed -i.bak -E '/# OMITTED-SITE/!s/legacy_call\(/migrated_call(/g' "$f"
        else
            # Clean sweep: rewrite every call site including the omitted one.
            sed -i.bak -E 's/legacy_call\(/migrated_call(/g' "$f"
        fi
        rm -f "$f.bak"
    done

    echo "$work"
}

# count_remaining_sites <swept_tree> — independent completeness count. Runs sg
# directly (reconstructing the full invocation: pattern + --lang + path) and
# COUNTS surviving legacy_call( call expressions, replicating detect.sh's
# scope-relative test-file path exclusion so the counts stay aligned. The rule
# is "any remaining site (count>=1) is INCOMPLETE" — NOT >=threshold. Prints the
# count on stdout; prints surviving file:line sites on fd 3 if open.
count_remaining_sites() {
    local swept="$1"
    local raw
    raw=$(sg --pattern "${TARGET_SYMBOL}(\$\$\$)" --lang "$PIN_LANG" "$swept" 2>/dev/null || true)

    local root_norm="${swept%/}"
    local count=0 line file_part rel_part
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        file_part="${line%%:*}"
        rel_part="$file_part"
        if [[ "$file_part" == "$root_norm/"* ]]; then
            rel_part="${file_part#"$root_norm"/}"
        fi
        # Scope-relative test-file exclusion (mirrors detect.sh).
        if echo "$rel_part" | grep -qE '(^|/)(test[s]?)/|_test\.|\.test\.' 2>/dev/null; then
            continue
        fi
        count=$((count + 1))
        # Surface the surviving site (file:line) for the missed-site report.
        echo "MISSED-SITE: $line" >&2
    done <<< "$raw"
    echo "$count"
}

# ── Case: marker (dd-2 schema level) ──────────────────────────────────────────
case_marker() {
    if ! _have_sg; then case_sg_skip; return; fi
    local out
    out=$(run_detector)
    local mc dq
    mc=$(parse_field "$out" "migration-class")
    dq=$(parse_field "$out" "detection_query")

    if [[ "$mc" == "sweep" ]]; then
        ok "marker: migration-class=sweep"
    else
        fail "marker: expected migration-class=sweep, got '$mc' (out=$out)"
    fi

    # Schema-level pair binding: the marker carries a non-empty detection_query
    # structural-contract field — the field the automated-sweep/manual-verification
    # pair is generated from. We assert the field, NOT live pair prose.
    if echo "$out" | grep -qE '"detection_query":"[^"]+"'; then
        ok "marker: carries non-empty detection_query field (dq='$dq')"
    else
        fail "marker: detection_query structural-contract field missing/empty (out=$out)"
    fi
}

# ── Case: missed-site (dd-3) ──────────────────────────────────────────────────
case_missed_site() {
    if ! _have_sg; then case_sg_skip; return; fi
    local swept count missed_lines
    swept=$(make_swept_copy 1)   # leave the OMITTED-SITE in place

    # count_remaining_sites prints the count on stdout and the surviving
    # MISSED-SITE: file:line lines on stderr. Capture them separately.
    local errf
    errf=$(mktemp "${TMPDIR:-/tmp}/migration-sweep-e2e-err.XXXXXX")
    count=$(count_remaining_sites "$swept" 2>"$errf")
    missed_lines=$(cat "$errf")
    rm -f "$errf"
    rm -rf "$swept"

    # Completeness rule: any remaining site (>=1) is INCOMPLETE.
    if [[ "$count" -ge 1 ]]; then
        ok "missed-site: completeness count=$count (>=1) → INCOMPLETE"
    else
        fail "missed-site: expected >=1 surviving site, got count=$count"
    fi

    # The surviving site must surface a concrete file:line.
    if echo "$missed_lines" | grep -qE 'MISSED-SITE:.*:[0-9]+'; then
        ok "missed-site: surfaced surviving file:line"
        echo "$missed_lines" | grep -E 'MISSED-SITE:.*:[0-9]+' | head -3
    else
        fail "missed-site: no file:line surfaced (got: $missed_lines)"
    fi

    # The surviving site must be the OMITTED-SITE (deactivate_user).
    if echo "$missed_lines" | grep -q 'users.py'; then
        ok "missed-site: surviving site is the OMITTED-SITE (users.py)"
    else
        fail "missed-site: surviving site is not the expected users.py OMITTED-SITE"
    fi

    # dd-3 AC binds exit code to incompleteness: when sites remain, exit non-zero.
    if [[ "$count" -ge 1 ]]; then
        _MISSED_SITE_EXIT=1
    fi
}

# ── Case: clean-sweep (complement of missed-site) ─────────────────────────────
case_clean_sweep() {
    if ! _have_sg; then case_sg_skip; return; fi
    local swept count
    swept=$(make_swept_copy 0)   # remove ALL sites including the omitted one
    count=$(count_remaining_sites "$swept" 2>/dev/null)
    rm -rf "$swept"

    if [[ "$count" -eq 0 ]]; then
        ok "clean-sweep: zero remaining sites → COMPLETE (exit 0)"
    else
        fail "clean-sweep: expected 0 remaining sites, got count=$count"
    fi
}

# ── Case: baseline (dd-4 positive differential) ───────────────────────────────
case_baseline() {
    if ! _have_sg; then case_sg_skip; return; fi
    local current
    current=$(run_detector)

    # Current migration-aware run MUST carry the marker + detection_query field.
    if echo "$current" | grep -qE '"migration-class":"sweep"'; then
        ok "baseline: current run carries migration-class:sweep marker"
    else
        fail "baseline: current run missing migration-class:sweep marker (out=$current)"
    fi
    if echo "$current" | grep -qE '"detection_query":"[^"]+"'; then
        ok "baseline: current run carries detection_query field"
    else
        fail "baseline: current run missing detection_query field"
    fi

    # Committed baseline MUST carry NEITHER marker NOR pair tokens.
    if grep -qE 'migration-class.{0,3}sweep|automated-sweep|manual-verification|"detection_query":' "$BASELINE_FILE"; then
        fail "baseline: committed baseline-expected.txt unexpectedly contains a marker/pair token"
    else
        ok "baseline: committed baseline carries NO marker/pair token"
    fi

    # Positive differential: current output differs from (is a superset of) the
    # baseline — the marker is present now and absent in the baseline.
    if ! grep -qF "$current" "$BASELINE_FILE" 2>/dev/null; then
        ok "baseline: current marker line is NOT present in the baseline (differential holds)"
    else
        fail "baseline: current marker line unexpectedly found in the baseline"
    fi
}

# ── Case: determinism (dd-5) ──────────────────────────────────────────────────
case_determinism() {
    if ! _have_sg; then case_sg_skip; return; fi
    # Two full detector runs must be byte-identical.
    local run1 run2
    run1=$(run_detector)
    run2=$(run_detector)
    if [[ "$run1" == "$run2" ]]; then
        ok "determinism: two detector runs are byte-identical"
    else
        fail "determinism: detector output differs between runs (run1=$run1 run2=$run2)"
    fi

    # The sweep simulation must be idempotent: count of surviving sites is the
    # same across two independent swept copies (no clock/random in the path).
    local s1 s2 c1 c2
    s1=$(make_swept_copy 1); c1=$(count_remaining_sites "$s1" 2>/dev/null); rm -rf "$s1"
    s2=$(make_swept_copy 1); c2=$(count_remaining_sites "$s2" 2>/dev/null); rm -rf "$s2"
    if [[ "$c1" == "$c2" && "$c1" == "1" ]]; then
        ok "determinism: sweep simulation idempotent, exactly 1 site remains ($c1==$c2)"
    else
        fail "determinism: swept-copy counts differ or != 1 (c1=$c1 c2=$c2)"
    fi
}

# ── Case: sg-skip (dd-7 graceful degradation) ─────────────────────────────────
# Drive the detector with sg removed from PATH; assert the loud skip token and
# the inconclusive classification. Self-driven so it runs even where sg exists.
case_sg_skip() {
    local stub out mc
    stub=$(mktemp -d "${TMPDIR:-/tmp}/migration-sweep-e2e-nopath.XXXXXX")
    out=$(WORKFLOW_CONFIG_FILE="$FIXTURE_CONFIG" \
          PATH="$stub:/usr/bin:/bin" \
          bash "$DETECT_SCRIPT" "$TARGET_SYMBOL" "$PIN_LANG" "$FIXTURE_DIR" < /dev/null)
    rm -rf "$stub"

    mc=$(parse_field "$out" "migration-class")
    if [[ "$mc" == "inconclusive" ]]; then
        echo "SWEEP-E2E-SKIPPED: sg unavailable"
        ok "sg-skip: detector emitted migration-class=inconclusive under sg-unavailable"
    else
        fail "sg-skip: expected inconclusive under sg-unavailable, got '$mc' (out=$out)"
    fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
_MISSED_SITE_EXIT=0
run_case() {
    case "$1" in
        marker)      case_marker ;;
        missed-site) case_missed_site ;;
        clean-sweep) case_clean_sweep ;;
        baseline)    case_baseline ;;
        determinism) case_determinism ;;
        sg-skip)     case_sg_skip ;;
        *) echo "Unknown case: $1" >&2; exit 2 ;;
    esac
}

ALL_CASES="marker missed-site clean-sweep baseline determinism sg-skip"

if [[ -n "$CASE_NAME" ]]; then
    echo "=== test_migration_sweep_e2e.sh --case $CASE_NAME ==="
    run_case "$CASE_NAME"
    # dd-3: the missed-site case must exit NON-ZERO when a site survives.
    if [[ "$CASE_NAME" == "missed-site" && "$_MISSED_SITE_EXIT" -ne 0 && "$_FAILED" -eq 0 ]]; then
        echo "TOTAL FAILED: 0 (missed-site: incomplete sweep → non-zero exit)"
        exit 1
    fi
    echo "TOTAL FAILED: $_FAILED"
    [[ "$_FAILED" -eq 0 ]] && exit 0 || exit 1
fi

# Bare invocation: run every case in its own subprocess so per-case exit
# semantics (notably missed-site's intentional non-zero) do not abort the suite.
echo "=== test_migration_sweep_e2e.sh (all cases) ==="
SUITE_FAILED=0
for c in $ALL_CASES; do
    echo "--- case: $c ---"
    if [[ "$c" == "missed-site" ]]; then
        # missed-site intentionally exits non-zero on a SUCCESSFUL incompleteness
        # detection; a REAL failure prints FAIL: lines. Distinguish via output.
        co=$(bash "${BASH_SOURCE[0]}" --case "$c" 2>&1); crc=$?
        echo "$co"
        if echo "$co" | grep -qE '^FAIL:'; then
            SUITE_FAILED=$((SUITE_FAILED + 1))
        elif [[ "$crc" -ne 1 ]]; then
            # Expected the intentional rc=1 (incomplete). Any other rc is wrong.
            echo "FAIL: missed-site expected intentional exit 1, got $crc" >&2
            SUITE_FAILED=$((SUITE_FAILED + 1))
        fi
    else
        if ! bash "${BASH_SOURCE[0]}" --case "$c"; then
            SUITE_FAILED=$((SUITE_FAILED + 1))
        fi
    fi
done

echo "=========================================="
echo "FAILED: $SUITE_FAILED"
[[ "$SUITE_FAILED" -eq 0 ]] && exit 0 || exit 1
