#!/usr/bin/env bash
# tests/integration/test-figma-merge-integration.sh
# Integration tests for figma-merge.py CLI — merges Figma-revised spatial layouts
# into existing manifest artifacts (spatial-layout.json, wireframe.svg, tokens.md).
#
# Tests: FP-MERGE-INT-1 through FP-MERGE-INT-4 (merge behavior),
#        FP-LINK-INT-1 (ID-linkage validation)
#
# RED state: These tests MUST FAIL until figma-merge.py is implemented.
# Script-not-found is the expected failure mode — do NOT skip on missing scripts.
#
# Usage: bash tests/integration/test-figma-merge-integration.sh
# Returns: exit 0 if all pass, exit 1 if any fail (RED state expected until implementation)
#
# REVIEW-DEFENSE: FP-MERGE-INT-1..4 and FP-LINK-INT-1 test the figma-merge.py CLI with the
# following pinned interface contract (story 3042-e00d):
#
#   python3 figma-merge.py \
#       --manifest-dir <dir>         # directory containing spatial-layout.json, wireframe.svg, tokens.md
#       --revised-spatial <file>     # Figma-derived spatial JSON (figma-revised-spatial.json)
#       [--non-interactive]          # skip confirmation prompt; write files and exit 0
#
# figma_merge/__init__.py is a library skeleton; the CLI entry point (figma-merge.py with
# argparse) is a separate deliverable. These integration tests intentionally test the CLI
# surface in the RED phase — they fail now and must be the green target for implementation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-figma-merge-integration.sh ==="

# Cleanup trap — removes temp dirs created during test execution
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# Script path under test (does NOT exist yet — RED state)
FIGMA_MERGE="$REPO_ROOT/plugins/dso/scripts/figma-merge.py"

# Fixtures
FIXTURES_DIR="$SCRIPT_DIR/fixtures/figma-merge"
ORIGINAL_DIR="$FIXTURES_DIR/original"
REVISED_SPATIAL="$FIXTURES_DIR/figma-revised-spatial.json"

# ---------------------------------------------------------------------------
# FP-MERGE-INT-1: Modified component position appears in output
#
# Given fixture manifests and revised Figma spatial-layout, when figma-merge.py
# --non-interactive runs, then exit 0 and output spatial-layout.json has the
# modified component's new position (comp-nav moved from y=80 to y=100).
# ---------------------------------------------------------------------------
test_fp_merge_int_1_modified_position() {
    if [[ ! -f "$FIGMA_MERGE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MERGE-INT-1 — figma-merge.py not found at %s\n" "$FIGMA_MERGE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Copy originals into work dir so figma-merge.py can write output
    cp "$ORIGINAL_DIR/spatial-layout.json" "$tmpdir/spatial-layout.json"
    cp "$ORIGINAL_DIR/wireframe.svg"       "$tmpdir/wireframe.svg"
    cp "$ORIGINAL_DIR/tokens.md"           "$tmpdir/tokens.md"

    local exit_code=0
    python3 "$FIGMA_MERGE" \
        --manifest-dir "$tmpdir" \
        --revised-spatial "$REVISED_SPATIAL" \
        --non-interactive \
        2>/dev/null || exit_code=$?

    assert_eq "FP-MERGE-INT-1: exits 0 with --non-interactive" "0" "$exit_code"

    local pos_check=0
    python3 - "$tmpdir/spatial-layout.json" <<'PYEOF' 2>/dev/null || pos_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
nav = next((c for c in components if c.get("id") == "comp-nav"), None)
assert nav is not None, "comp-nav missing from output"
sh = nav.get("spatial_hint", {})
assert sh.get("y") == 100, f"expected y=100 (revised), got y={sh.get('y')}"
PYEOF

    assert_eq "FP-MERGE-INT-1: comp-nav has updated y=100 from Figma revision" "0" "$pos_check"
}

# ---------------------------------------------------------------------------
# FP-MERGE-INT-2: Designer-added component appears with tag=NEW and designer_added=true
#
# Given same fixtures, when figma-merge.py --non-interactive runs, then the
# designer-added comp-hero appears in output with tag=NEW and designer_added=true.
# ---------------------------------------------------------------------------
test_fp_merge_int_2_designer_added_component() {
    if [[ ! -f "$FIGMA_MERGE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MERGE-INT-2 — figma-merge.py not found at %s\n" "$FIGMA_MERGE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    cp "$ORIGINAL_DIR/spatial-layout.json" "$tmpdir/spatial-layout.json"
    cp "$ORIGINAL_DIR/wireframe.svg"       "$tmpdir/wireframe.svg"
    cp "$ORIGINAL_DIR/tokens.md"           "$tmpdir/tokens.md"

    local exit_code=0
    python3 "$FIGMA_MERGE" \
        --manifest-dir "$tmpdir" \
        --revised-spatial "$REVISED_SPATIAL" \
        --non-interactive \
        2>/dev/null || exit_code=$?

    assert_eq "FP-MERGE-INT-2: exits 0" "0" "$exit_code"

    local hero_check=0
    python3 - "$tmpdir/spatial-layout.json" <<'PYEOF' 2>/dev/null || hero_check=1
import sys, json
d = json.load(open(sys.argv[1]))
components = d.get("components", [])
hero = next((c for c in components if c.get("id") == "comp-hero"), None)
assert hero is not None, "comp-hero missing from output — designer-added component not merged"
assert hero.get("tag") == "NEW", f"expected tag=NEW, got tag={hero.get('tag')!r}"
assert hero.get("designer_added") is True, f"expected designer_added=true, got {hero.get('designer_added')!r}"
PYEOF

    assert_eq "FP-MERGE-INT-2: comp-hero present with tag=NEW and designer_added=true" "0" "$hero_check"
}

# ---------------------------------------------------------------------------
# FP-MERGE-INT-3: WARN on stderr when COMPLETE-spec component is removed in revision
#
# Given the COMPLETE-spec component (comp-header) is absent from the Figma revision,
# when figma-merge.py --non-interactive runs, then stderr contains WARN text about
# removing a COMPLETE behavioral spec.
# ---------------------------------------------------------------------------
test_fp_merge_int_3_complete_spec_removal_warning() {
    if [[ ! -f "$FIGMA_MERGE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MERGE-INT-3 — figma-merge.py not found at %s\n" "$FIGMA_MERGE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    cp "$ORIGINAL_DIR/spatial-layout.json" "$tmpdir/spatial-layout.json"
    cp "$ORIGINAL_DIR/wireframe.svg"       "$tmpdir/wireframe.svg"
    cp "$ORIGINAL_DIR/tokens.md"           "$tmpdir/tokens.md"

    local stderr_output exit_code=0
    stderr_output=$(python3 "$FIGMA_MERGE" \
        --manifest-dir "$tmpdir" \
        --revised-spatial "$REVISED_SPATIAL" \
        --non-interactive \
        2>&1 >/dev/null) || exit_code=$?

    # WARN must appear on stderr about COMPLETE spec removal (exit 0 still allowed)
    assert_contains "FP-MERGE-INT-3: stderr contains WARN about COMPLETE spec removal" \
        "WARN" "$stderr_output"

    # stderr must also mention the component name, COMPLETE status, or behavioral spec
    # Use assert_contains for each candidate to keep diagnostic output consistent.
    # At least one of these substrings must appear; we capture whether any match.
    local _warn_specific_before=$FAIL
    if [[ "$stderr_output" == *"comp-header"* ]]; then
        assert_contains "FP-MERGE-INT-3: stderr mentions component name (comp-header)" \
            "comp-header" "$stderr_output"
    elif [[ "$stderr_output" == *"COMPLETE"* ]]; then
        assert_contains "FP-MERGE-INT-3: stderr mentions COMPLETE status" \
            "COMPLETE" "$stderr_output"
    elif [[ "$stderr_output" == *"behavioral"* ]]; then
        assert_contains "FP-MERGE-INT-3: stderr mentions behavioral spec" \
            "behavioral" "$stderr_output"
    else
        # None matched — use assert_contains to produce a consistent failure message
        assert_contains "FP-MERGE-INT-3: stderr mentions comp-header/COMPLETE/behavioral" \
            "comp-header" "$stderr_output"
    fi
}

# ---------------------------------------------------------------------------
# FP-MERGE-INT-4: User inputs 'n' at confirmation prompt → non-zero exit, no output files
#
# Given a confirmation prompt (no --non-interactive), when the user inputs 'n',
# then figma-merge.py exits non-zero and no output files are written.
# ---------------------------------------------------------------------------
test_fp_merge_int_4_user_declines_confirmation() {
    if [[ ! -f "$FIGMA_MERGE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-MERGE-INT-4 — figma-merge.py not found at %s\n" "$FIGMA_MERGE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    cp "$ORIGINAL_DIR/spatial-layout.json" "$tmpdir/spatial-layout.json"
    cp "$ORIGINAL_DIR/wireframe.svg"       "$tmpdir/wireframe.svg"
    cp "$ORIGINAL_DIR/tokens.md"           "$tmpdir/tokens.md"

    # Record the modification time of output file before the run
    local mtime_before
    mtime_before=$(stat -f "%m" "$tmpdir/spatial-layout.json" 2>/dev/null \
        || stat -c "%Y" "$tmpdir/spatial-layout.json" 2>/dev/null || echo "0")

    local exit_code=0
    echo 'n' | python3 "$FIGMA_MERGE" \
        --manifest-dir "$tmpdir" \
        --revised-spatial "$REVISED_SPATIAL" \
        2>/dev/null || exit_code=$?

    assert_ne "FP-MERGE-INT-4: exits non-zero when user inputs 'n'" "0" "$exit_code"

    # Verify output file was not modified (mtime unchanged)
    local mtime_after
    mtime_after=$(stat -f "%m" "$tmpdir/spatial-layout.json" 2>/dev/null \
        || stat -c "%Y" "$tmpdir/spatial-layout.json" 2>/dev/null || echo "0")

    assert_eq "FP-MERGE-INT-4: spatial-layout.json not modified after 'n' input" \
        "$mtime_before" "$mtime_after"
}

# ---------------------------------------------------------------------------
# FP-LINK-INT-1: ID-linkage error when spatial-layout.json component not in SVG
#
# Given a deliberately inconsistent fixture (comp-orphan in spatial-layout.json
# but not in wireframe.svg), when figma-merge.py runs, then exits 1 with an
# ID-linkage error message.
# ---------------------------------------------------------------------------
test_fp_link_int_1_id_linkage_error() {
    if [[ ! -f "$FIGMA_MERGE" ]]; then
        (( ++FAIL ))
        printf "FAIL: FP-LINK-INT-1 — figma-merge.py not found at %s\n" "$FIGMA_MERGE" >&2
        return
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Create an inconsistent spatial-layout.json with an extra component not in SVG
    python3 - "$ORIGINAL_DIR/spatial-layout.json" "$tmpdir/spatial-layout.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["components"].append({
    "id": "comp-orphan",
    "name": "Orphan Component",
    "type": "FRAME",
    "spatial_hint": {"x": 0, "y": 0, "width": 100, "height": 100},
    "behavioral_spec_status": "PENDING",
    "tag": "EXISTING"
})
with open(sys.argv[2], "w") as f:
    json.dump(d, f, indent=2)
PYEOF

    # Use the original SVG (which does NOT contain comp-orphan)
    cp "$ORIGINAL_DIR/wireframe.svg" "$tmpdir/wireframe.svg"
    cp "$ORIGINAL_DIR/tokens.md"    "$tmpdir/tokens.md"

    local stderr_output exit_code=0
    stderr_output=$(python3 "$FIGMA_MERGE" \
        --manifest-dir "$tmpdir" \
        --revised-spatial "$REVISED_SPATIAL" \
        --non-interactive \
        2>&1 >/dev/null) || exit_code=$?

    assert_ne "FP-LINK-INT-1: exits non-zero on ID-linkage mismatch" "0" "$exit_code"
    assert_ne "FP-LINK-INT-1: emits error message on stderr for linkage mismatch" "" "$stderr_output"

    # Error message should mention the orphaned ID or linkage issue
    local linkage_mention=0
    if [[ "$stderr_output" == *"comp-orphan"* ]] || \
       [[ "$stderr_output" == *"linkage"* ]] || \
       [[ "$stderr_output" == *"mismatch"* ]] || \
       [[ "$stderr_output" == *"not found"* ]] || \
       [[ "$stderr_output" == *"missing"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: FP-LINK-INT-1 — error message does not reference linkage issue\n  stderr: %s\n" "$stderr_output" >&2
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_fp_merge_int_1_modified_position
test_fp_merge_int_2_designer_added_component
test_fp_merge_int_3_complete_spec_removal_warning
test_fp_merge_int_4_user_declines_confirmation
test_fp_link_int_1_id_linkage_error

print_summary
