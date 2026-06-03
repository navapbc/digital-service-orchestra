#!/usr/bin/env bash
# test-migration-pair-order.sh
#
# Behavioral suite for the apply-two-pass-ordering.sh sprint helper
#
# This suite exercises the helper by stubbing `dso ticket show`, `dso ticket link`,
# and (for the no-recompute case) an ast-grep / migration-class detector on PATH.
# Assertions are on observable outcomes: ticket link edges written/not-written,
# exit codes, and whether the detector was ever invoked.
#
# All seven cases are driven via --case <name>:
#   no-recompute    : helper reads persisted marker; detector NEVER invoked
#   sweep           : migration-class=sweep → link manual-verification depends_on automated-sweep
#   db-rollback     : migration-class=db    → link rollback-verification depends_on forward-migration
#   flag            : feature-flag pair present → link flag-cleanup depends_on flag-cutover
#   absent-marker   : no MIGRATION_CLASS comment, no flag pair → no edges, exit 0
#   inconclusive    : migration-class=inconclusive, no flag pair → no edges, exit 0
#   idempotent      : depends_on edge already present → no duplicate edge on re-run
#
# RED phase: apply-two-pass-ordering.sh does NOT exist yet — all cases FAIL.
# GREEN phase (task c7fd): helper is implemented, suite passes.
#
# Usage:
#   bash test-migration-pair-order.sh --case <name>
#
# Dependencies:
#   tests/lib/assert.sh (silent on pass, FAIL: on failure, print_summary exits with FAIL count)

set -uo pipefail

# ── Parse --case argument ─────────────────────────────────────────────────────
CASE_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --case)
            CASE_NAME="${2:-}"
            shift 2
            ;;
        *)
            echo "Usage: $0 --case <name>" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$CASE_NAME" ]]; then
    # No --case given (e.g. the test gate invokes suites bare): run every case
    # in an isolated subprocess so per-case PATH stubs and fixtures don't leak,
    # then aggregate exit codes. Any failing case fails the suite.
    _ALL_CASES="no-recompute sweep db-rollback flag absent-marker inconclusive idempotent"
    _AGG_RC=0
    for _c in $_ALL_CASES; do
        bash "${BASH_SOURCE[0]}" --case "$_c" || _AGG_RC=1
    done
    exit "$_AGG_RC"
fi

# ── Path setup ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This test lives at tests/sprint/; resolve the repo root via git for robustness,
# falling back to two-levels-up from the test directory.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
HELPER="$REPO_ROOT/plugins/dso/scripts/sprint/apply-two-pass-ordering.sh"

source "$ASSERT_LIB"

# ── Cleanup on exit ───────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create isolated temp dir ─────────────────────────────────────────
make_tmpdir() {
    local label="${1:-test}"
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-migration-pair-order-${label}.XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Stub builder ─────────────────────────────────────────────────────────────
# Produces a stub bin/ directory on PATH with fake `dso` and optionally `sg`.
# Each stub logs its invocations to a log file for assertion.
#
# stub_dir: directory to put stubs in
# ticket_show_response: what `dso ticket show <id>` prints to stdout
# link_log: file to append `ticket link` args to (one call per line)
# existing_links: space-separated list of "src:rel:tgt" already present.
#   These are returned by the REAL `dso ticket deps <src>` subcommand (the helper
#   reads existing depends_on edges via `deps`, NOT a fictional `list-links`).
#   The deps stub emits the contract JSON shape: {"deps":[{"relation":..,"target_id":..}]}.
#
# IMPORTANT: the `link` stub logs EVERY invocation UNCONDITIONALLY — it performs
# NO duplicate-suppression of its own. This makes the test measure the HELPER's
# idempotency guard (which reads `deps`), not the stub's behavior. If the helper's
# guard failed to fire, the duplicate link WOULD appear in the log.
build_stub_bin() {
    local stub_dir="$1"          # directory for stub executables
    local ticket_show_body="$2"  # JSON body returned by `dso ticket show`
    local link_log="$3"          # file to append link invocations to
    local existing_links="${4:-}" # existing "src:rel:tgt" returned by `ticket deps`

    # Stub dso script
    cat > "$stub_dir/dso" <<STUB_DSO
#!/usr/bin/env bash
# Stub dso CLI for test-migration-pair-order.sh
subcommand="\${1:-}"
shift || true

case "\$subcommand" in
    ticket)
        ticket_sub="\${1:-}"
        shift || true
        case "\$ticket_sub" in
            show)
                # Always return the fixture body regardless of ticket ID
                echo '${ticket_show_body}'
                ;;
            link)
                # Log EVERY invocation unconditionally — no stub-side dedup.
                # Format: <src> <relation> <tgt>
                src="\${1:-}"
                tgt="\${2:-}"
                rel="\${3:-}"
                echo "\$src \$rel \$tgt" >> "${link_log}"
                exit 0
                ;;
            deps)
                # Emit the contract JSON: {"deps":[{"relation":..,"target_id":..}]}
                # for edges whose source == the queried ticket id.
                target_id="\${1:-}"
                existing="${existing_links}"
                entries=""
                for entry in \$existing; do
                    IFS=':' read -r s r t <<< "\$entry"
                    if [[ "\$s" == "\$target_id" ]]; then
                        [[ -n "\$entries" ]] && entries="\${entries},"
                        entries="\${entries}{\"relation\":\"\$r\",\"target_id\":\"\$t\"}"
                    fi
                done
                echo "{\"ticket_id\":\"\$target_id\",\"deps\":[\$entries]}"
                exit 0
                ;;
            *)
                echo "STUB: unknown ticket subcommand: \$ticket_sub" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "STUB: unknown subcommand: \$subcommand" >&2
        exit 1
        ;;
esac
STUB_DSO
    chmod +x "$stub_dir/dso"
}

# Build a stub sg/ast-grep that logs invocations and reports "not called"
build_stub_detector() {
    local stub_dir="$1"
    local detector_log="$2"  # file to record invocation

    # Stub sg (ast-grep)
    cat > "$stub_dir/sg" <<STUB_SG
#!/usr/bin/env bash
# Stub sg (ast-grep) — should NEVER be invoked in no-recompute case
echo "STUB_DETECTOR_INVOKED: sg \$*" >> "${detector_log}"
echo "STUB_DETECTOR_INVOKED: sg \$*" >&2
exit 0
STUB_SG
    chmod +x "$stub_dir/sg"
}

# ── Check helper exists (RED phase: it does not) ──────────────────────────────
if [[ ! -x "$HELPER" ]]; then
    echo "NOTE: $HELPER not found or not executable — all cases FAIL (RED phase)" >&2
fi

# ═══════════════════════════════════════════════════════════════════════════════
# CASE: no-recompute
# Stub a migration-class=sweep marker on the story ticket.
# Put a detector (sg) on PATH and assert it is NEVER invoked.
# The helper reads the persisted marker only — no detection recompute.
# ═══════════════════════════════════════════════════════════════════════════════
test_no_recompute() {
    local tmpdir
    tmpdir=$(make_tmpdir "no-recompute")

    local link_log="$tmpdir/links.log"
    local detector_log="$tmpdir/detector.log"
    touch "$link_log" "$detector_log"

    # Story fixture: has a MIGRATION_CLASS comment with migration-class=sweep
    local story_json
    story_json=$(cat <<'JSON'
{
  "ticket_id": "story-1111",
  "ticket_type": "story",
  "title": "Migration story",
  "status": "open",
  "comments": [
    {
      "body": "MIGRATION_CLASS: {\"migration-class\":\"sweep\",\"detection_query\":\"$A.old_helper($$$B)\",\"threshold_used\":3,\"target_symbol\":\"old_helper\"}",
      "author": "Test",
      "timestamp": 1780000000000000000
    }
  ]
}
JSON
)

    local stub_dir="$tmpdir/bin"
    mkdir -p "$stub_dir"
    build_stub_bin "$stub_dir" "$story_json" "$link_log" ""
    build_stub_detector "$stub_dir" "$detector_log"

    # Run helper with detector stub on PATH (detector MUST NOT be invoked)
    local exit_code=0
    PATH="$stub_dir:$PATH" bash "$HELPER" \
        --story-id "story-1111" \
        --tasks "task-auto-sweep:automated-sweep task-manual-verify:manual-verification" \
        2>/dev/null || exit_code=$?

    # Observable: detector was never invoked
    local detector_calls
    detector_calls=$(wc -l < "$detector_log" 2>/dev/null | tr -d ' ' || echo "0")
    assert_eq "no-recompute: sg detector not invoked" "0" "$detector_calls"

    # Observable: helper exits 0 (marker read successfully)
    assert_eq "no-recompute: helper exits 0" "0" "$exit_code"

    # Observable (positive): the helper READ the persisted migration-class=sweep
    # marker and acted on it — it wrote the sweep-derived depends_on edge
    # (manual-verification depends_on automated-sweep). This proves the persisted
    # marker was consulted, not merely that the detector was skipped. Without
    # reading the marker, no edge would be emitted (mclass would be empty → no-op).
    local link_written
    link_written=$(grep -c "task-manual-verify depends_on task-auto-sweep" "$link_log" 2>/dev/null || echo "0")
    assert_eq "no-recompute: persisted sweep marker drove the depends_on edge" "1" "$link_written"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CASE: sweep
# migration-class=sweep + automated-sweep / manual-verification pair
# Assert: ticket link <manual-verification> <automated-sweep> depends_on
# ═══════════════════════════════════════════════════════════════════════════════
test_sweep() {
    local tmpdir
    tmpdir=$(make_tmpdir "sweep")

    local link_log="$tmpdir/links.log"
    touch "$link_log"

    local story_json
    story_json=$(cat <<'JSON'
{
  "ticket_id": "story-2222",
  "ticket_type": "story",
  "title": "Sweep migration story",
  "status": "open",
  "comments": [
    {
      "body": "MIGRATION_CLASS: {\"migration-class\":\"sweep\",\"detection_query\":\"$A.old_fn($$$B)\",\"threshold_used\":3,\"target_symbol\":\"old_fn\"}",
      "author": "Test",
      "timestamp": 1780000000000000000
    }
  ]
}
JSON
)

    local stub_dir="$tmpdir/bin"
    mkdir -p "$stub_dir"
    build_stub_bin "$stub_dir" "$story_json" "$link_log" ""

    local exit_code=0
    PATH="$stub_dir:$PATH" bash "$HELPER" \
        --story-id "story-2222" \
        --tasks "task-auto:automated-sweep task-manual:manual-verification" \
        2>/dev/null || exit_code=$?

    assert_eq "sweep: helper exits 0" "0" "$exit_code"

    # Observable: link log contains "task-manual depends_on task-auto"
    local link_written
    link_written=$(grep -c "task-manual depends_on task-auto" "$link_log" 2>/dev/null || echo "0")
    assert_eq "sweep: manual-verification depends_on automated-sweep edge written" "1" "$link_written"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CASE: db-rollback
# migration-class=db + forward-migration / rollback-verification pair
# Assert: rollback-verification depends_on forward-migration
# ═══════════════════════════════════════════════════════════════════════════════
test_db_rollback() {
    local tmpdir
    tmpdir=$(make_tmpdir "db-rollback")

    local link_log="$tmpdir/links.log"
    touch "$link_log"

    local story_json
    story_json=$(cat <<'JSON'
{
  "ticket_id": "story-3333",
  "ticket_type": "story",
  "title": "DB migration story",
  "status": "open",
  "comments": [
    {
      "body": "MIGRATION_CLASS: {\"migration-class\":\"db\",\"detection_query\":\"$A.legacy_query($$$B)\",\"threshold_used\":3,\"target_symbol\":\"legacy_query\"}",
      "author": "Test",
      "timestamp": 1780000000000000000
    }
  ]
}
JSON
)

    local stub_dir="$tmpdir/bin"
    mkdir -p "$stub_dir"
    build_stub_bin "$stub_dir" "$story_json" "$link_log" ""

    local exit_code=0
    PATH="$stub_dir:$PATH" bash "$HELPER" \
        --story-id "story-3333" \
        --tasks "task-fwd:forward-migration task-rollback:rollback-verification" \
        2>/dev/null || exit_code=$?

    assert_eq "db-rollback: helper exits 0" "0" "$exit_code"

    # Observable: rollback-verification depends_on forward-migration
    local link_written
    link_written=$(grep -c "task-rollback depends_on task-fwd" "$link_log" 2>/dev/null || echo "0")
    assert_eq "db-rollback: rollback-verification depends_on forward-migration edge written" "1" "$link_written"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CASE: flag
# Feature-flag pair present (flag-cutover + flag-cleanup roles) — no migration-class marker
# Assert: flag-cleanup depends_on flag-cutover
# The AC amendment clarifies: flag is detected via task-role presence (FEATURE_FLAGS),
# NOT via a migration-class=flag fixture (flag is not a valid migration-class value).
# ═══════════════════════════════════════════════════════════════════════════════
test_flag() {
    local tmpdir
    tmpdir=$(make_tmpdir "flag")

    local link_log="$tmpdir/links.log"
    touch "$link_log"

    # Story has NO migration-class marker (flag pair detected by role presence)
    local story_json
    story_json=$(cat <<'JSON'
{
  "ticket_id": "story-4444",
  "ticket_type": "story",
  "title": "Feature flag story",
  "status": "open",
  "comments": []
}
JSON
)

    local stub_dir="$tmpdir/bin"
    mkdir -p "$stub_dir"
    build_stub_bin "$stub_dir" "$story_json" "$link_log" ""

    local exit_code=0
    PATH="$stub_dir:$PATH" bash "$HELPER" \
        --story-id "story-4444" \
        --tasks "task-cutover:flag-cutover task-cleanup:flag-cleanup" \
        2>/dev/null || exit_code=$?

    assert_eq "flag: helper exits 0" "0" "$exit_code"

    # Observable: flag-cleanup depends_on flag-cutover
    local link_written
    link_written=$(grep -c "task-cleanup depends_on task-cutover" "$link_log" 2>/dev/null || echo "0")
    assert_eq "flag: flag-cleanup depends_on flag-cutover edge written" "1" "$link_written"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CASE: absent-marker
# No MIGRATION_CLASS comment and no feature-flag pair
# Assert: no edges written, exit 0
# ═══════════════════════════════════════════════════════════════════════════════
test_absent_marker() {
    local tmpdir
    tmpdir=$(make_tmpdir "absent-marker")

    local link_log="$tmpdir/links.log"
    touch "$link_log"

    # Story: no migration-class marker, no flag pair
    local story_json
    story_json=$(cat <<'JSON'
{
  "ticket_id": "story-5555",
  "ticket_type": "story",
  "title": "Plain story (no migration marker)",
  "status": "open",
  "comments": []
}
JSON
)

    local stub_dir="$tmpdir/bin"
    mkdir -p "$stub_dir"
    build_stub_bin "$stub_dir" "$story_json" "$link_log" ""

    local exit_code=0
    PATH="$stub_dir:$PATH" bash "$HELPER" \
        --story-id "story-5555" \
        --tasks "task-a:implementation task-b:review" \
        2>/dev/null || exit_code=$?

    assert_eq "absent-marker: helper exits 0" "0" "$exit_code"

    # Observable: no edges written
    local link_count
    link_count=$(wc -l < "$link_log" 2>/dev/null | tr -d ' ' || echo "0")
    assert_eq "absent-marker: no edges written" "0" "$link_count"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CASE: inconclusive
# migration-class=inconclusive, no feature-flag pair
# Assert: no edges written, exit 0
# ═══════════════════════════════════════════════════════════════════════════════
test_inconclusive() {
    local tmpdir
    tmpdir=$(make_tmpdir "inconclusive")

    local link_log="$tmpdir/links.log"
    touch "$link_log"

    local story_json
    story_json=$(cat <<'JSON'
{
  "ticket_id": "story-6666",
  "ticket_type": "story",
  "title": "Inconclusive migration story",
  "status": "open",
  "comments": [
    {
      "body": "MIGRATION_CLASS: {\"migration-class\":\"inconclusive\",\"detection_query\":\"$A.some_fn($$$B)\",\"threshold_used\":3,\"target_symbol\":\"some_fn\"}",
      "author": "Test",
      "timestamp": 1780000000000000000
    }
  ]
}
JSON
)

    local stub_dir="$tmpdir/bin"
    mkdir -p "$stub_dir"
    build_stub_bin "$stub_dir" "$story_json" "$link_log" ""

    local exit_code=0
    PATH="$stub_dir:$PATH" bash "$HELPER" \
        --story-id "story-6666" \
        --tasks "task-x:implementation task-y:review" \
        2>/dev/null || exit_code=$?

    assert_eq "inconclusive: helper exits 0" "0" "$exit_code"

    # Observable: no edges written for inconclusive class
    local link_count
    link_count=$(wc -l < "$link_log" 2>/dev/null | tr -d ' ' || echo "0")
    assert_eq "inconclusive: no edges written" "0" "$link_count"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CASE: idempotent
# depends_on edge already present → no duplicate edge on re-run
# ═══════════════════════════════════════════════════════════════════════════════
test_idempotent() {
    local tmpdir
    tmpdir=$(make_tmpdir "idempotent")

    local link_log="$tmpdir/links.log"
    touch "$link_log"

    local story_json
    story_json=$(cat <<'JSON'
{
  "ticket_id": "story-7777",
  "ticket_type": "story",
  "title": "Idempotent sweep story",
  "status": "open",
  "comments": [
    {
      "body": "MIGRATION_CLASS: {\"migration-class\":\"sweep\",\"detection_query\":\"$A.old_fn($$$B)\",\"threshold_used\":3,\"target_symbol\":\"old_fn\"}",
      "author": "Test",
      "timestamp": 1780000000000000000
    }
  ]
}
JSON
)

    local stub_dir="$tmpdir/bin"
    mkdir -p "$stub_dir"
    # Pre-populate the REAL `ticket deps` query: the depends_on edge already
    # exists on the dependent task (task-manual depends_on task-auto). The link
    # stub does NO dedup of its own, so a duplicate would be logged if the
    # HELPER's guard failed to read this edge via `ticket deps`.
    build_stub_bin "$stub_dir" "$story_json" "$link_log" "task-manual:depends_on:task-auto"

    local exit_code=0
    PATH="$stub_dir:$PATH" bash "$HELPER" \
        --story-id "story-7777" \
        --tasks "task-auto:automated-sweep task-manual:manual-verification" \
        2>/dev/null || exit_code=$?

    assert_eq "idempotent: helper exits 0 on re-run" "0" "$exit_code"

    # Observable: no new link written — the helper's guard read the existing
    # depends_on edge via `ticket deps` and skipped the duplicate link call.
    local link_count
    link_count=$(wc -l < "$link_log" 2>/dev/null | tr -d ' ' || echo "0")
    assert_eq "idempotent: no duplicate edge written on re-run" "0" "$link_count"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatch to the named case
# ═══════════════════════════════════════════════════════════════════════════════
case "$CASE_NAME" in
    no-recompute)
        test_no_recompute
        ;;
    sweep)
        test_sweep
        ;;
    db-rollback)
        test_db_rollback
        ;;
    flag)
        test_flag
        ;;
    absent-marker)
        test_absent_marker
        ;;
    inconclusive)
        test_inconclusive
        ;;
    idempotent)
        test_idempotent
        ;;
    *)
        echo "ERROR: unknown case '$CASE_NAME'" >&2
        echo "Valid cases: no-recompute sweep db-rollback flag absent-marker inconclusive idempotent" >&2
        exit 1
        ;;
esac

print_summary
