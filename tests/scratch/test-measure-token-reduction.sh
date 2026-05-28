#!/usr/bin/env bash
# tests/scratch/test-measure-token-reduction.sh
# Tests for plugins/dso/scripts/scratch-measure-token-reduction.py
#
# Covers:
#   Task 98f0 — Config loader foundation
#   Task 6998 — Named, pinned tokenizer with deterministic count()
#   Task ef3d — 5-site return-block capture across pre and post HEAD SHAs
#   Task a9fa — Aggregate gate + JSON report
#   Task e05b — Commit report to epic scratch artifact via --commit-to-epic
#
# Test cases:
#   1. (test_check_config_valid_epic)           --check-config with valid epic id → exit 0
#   2. (test_check_config_missing_epic)         --check-config with non-existent epic id → exit non-zero + clear error
#   3. (test_harness_executable)                Harness script is executable
#   4. (test_example_config_exists)             Example config exists at expected path
#   5. (test_tokenizer_count_deterministic)     Tokenizer.count is deterministic for same input
#   6. (test_unknown_tokenizer_rejected)        Unknown tokenizer name → non-zero exit
#   7. (test_tokenizer_name_matches_config)     Tokenizer name exposed and matches config value
#   8. (test_five_sites_captured)               All 5 sites captured pre and post via snapshot mode
#   9. (test_per_site_record_shas)              Per-site record carries both HEAD SHAs verbatim
#  10. (test_missing_snapshot_nonzero_exit)     Missing snapshot → non-zero exit with clear error
#  11. (test_aggregate_pass_threshold)          >=70% reduction → status=pass, exit 0
#  12. (test_aggregate_partial_threshold)       50-70% reduction → status=partial, exit 0
#  13. (test_aggregate_fail_threshold)          <50% reduction → status=fail, non-zero exit
#  14. (test_report_has_required_fields)        JSON report contains all required fields
#  15. (test_commit_to_epic_invokes_scratch)    --commit-to-epic invokes scratch CLI
#  16. (test_no_commit_without_flag)            Without --commit-to-epic, no scratch write
#
# Usage: bash tests/scratch/test-measure-token-reduction.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

HARNESS="$REPO_ROOT/plugins/dso/scripts/scratch-measure-token-reduction.py"
EXAMPLE_CONFIG="$REPO_ROOT/plugins/dso/scripts/scratch-measure-config.example.yaml"

echo "=== test-measure-token-reduction.sh: config loader + tokenizer + capture ==="

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_CLEANUP_FILES=()
_cleanup() {
    for f in "${_CLEANUP_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f "$f"
    done
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

# make_base_config <file> <tokenizer_name>
# Write a minimal valid config to <file>.
make_base_config() {
    local file="$1" tok="${2:-tiktoken:cl100k_base}"
    cat > "$file" <<EOF
test_epic_id: "98f0-54cf-8bad-467f"
tokenizer: "${tok}"
pre_head_sha: "aaa0000000000000000000000000000000000001"
post_head_sha: "bbb1111111111111111111111111111111111112"
output_path: "/tmp/measure-test-output.json"
EOF
}

# make_snapshot_dir <snapshot_dir> [text_pre] [text_post]
# Populate <snapshot_dir> with all 5 site snapshot files.
# Default text is short but non-empty so token counts are > 0.
make_snapshot_dir() {
    local dir="$1"
    local pre_text="${2:-The quick brown fox jumps over the lazy dog. Pre-migration content here.}"
    local post_text="${3:-The quick brown fox. Post-migration content shorter here.}"
    mkdir -p "$dir"
    local sites=(
        "impl-plan-511"
        "impl-plan-978"
        "impl-plan-1238"
        "preplanning-513"
        "sprint-2332"
    )
    for site in "${sites[@]}"; do
        printf '%s' "$pre_text" > "$dir/${site}-pre.txt"
        printf '%s' "$post_text" > "$dir/${site}-post.txt"
    done
}

# ── Test 1: --check-config with valid epic id → exit 0 ───────────────────────
test_check_config_valid_epic() {
    local cfg
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    _CLEANUP_FILES+=("$cfg")

    # 98f0-54cf-8bad-467f is the task ticket for the harness foundation —
    # guaranteed to exist while this test runs.
    cat > "$cfg" <<EOF
test_epic_id: "98f0-54cf-8bad-467f"
tokenizer: "tiktoken:cl100k_base"
pre_head_sha: "abc0000000000000000000000000000000000000"
post_head_sha: "def1111111111111111111111111111111111111"
output_path: "/tmp/measure-test-output.json"
EOF

    local output exit_code
    output=$(python3 "$HARNESS" --config "$cfg" --check-config 2>&1)
    exit_code=$?

    assert_eq "check-config valid epic: exit 0" "0" "$exit_code"
    assert_contains "check-config valid epic: OK message" "OK" "$output"
}

# ── Test 2: --check-config with missing epic id → exit non-zero ──────────────
test_check_config_missing_epic() {
    local cfg
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    _CLEANUP_FILES+=("$cfg")

    # Use a clearly bogus ticket id that will never exist.
    cat > "$cfg" <<EOF
test_epic_id: "0000-0000-0000-0000"
tokenizer: "tiktoken:cl100k_base"
pre_head_sha: "abc0000000000000000000000000000000000000"
post_head_sha: "def1111111111111111111111111111111111111"
output_path: "/tmp/measure-test-output.json"
EOF

    local stderr_out exit_code
    stderr_out=$(python3 "$HARNESS" --config "$cfg" --check-config 2>&1)
    exit_code=$?

    # Must exit non-zero
    local non_zero=1
    if [ "$exit_code" -ne 0 ]; then
        non_zero=0
    fi
    assert_eq "check-config missing epic: exit non-zero" "0" "$non_zero"
    assert_contains "check-config missing epic: error message mentions ticket id" \
        "0000-0000-0000-0000" "$stderr_out"
}

# ── Test 3: harness script is executable ─────────────────────────────────────
test_harness_executable() {
    local result=1
    test -x "$HARNESS" && result=0
    assert_eq "harness executable" "0" "$result"
}

# ── Test 4: example config exists at expected path ───────────────────────────
test_example_config_exists() {
    local result=1
    test -f "$EXAMPLE_CONFIG" && result=0
    assert_eq "example config exists" "0" "$result"
}

# ── Test 5: Tokenizer.count is deterministic for same input ──────────────────
test_tokenizer_count_deterministic() {
    local cfg snap_dir
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    _CLEANUP_FILES+=("$cfg")
    _CLEANUP_DIRS+=("$snap_dir")

    local test_text="Hello world, this is a determinism test with enough words to be meaningful."
    make_base_config "$cfg" "char4"
    make_snapshot_dir "$snap_dir" "$test_text" "$test_text"

    # Run --capture twice, both with identical snapshot content.
    local out1 out2
    out1=$(python3 "$HARNESS" --config "$cfg" --capture \
        --use-snapshots "$snap_dir" 2>&1 >/dev/null)
    out2=$(python3 "$HARNESS" --config "$cfg" --capture \
        --use-snapshots "$snap_dir" 2>&1 >/dev/null)

    # Extract pre_tokens for first site from each run; must be identical.
    local tok1 tok2
    tok1=$(python3 -c "import sys,json; data=json.loads(sys.stdin.read()); print(data[0]['pre_tokens'])" <<< "$out1" 2>/dev/null || echo "parse_error")
    tok2=$(python3 -c "import sys,json; data=json.loads(sys.stdin.read()); print(data[0]['pre_tokens'])" <<< "$out2" 2>/dev/null || echo "parse_error")

    assert_eq "tokenizer count deterministic: run1 == run2" "$tok1" "$tok2"
    assert_ne "tokenizer count deterministic: count is not parse_error" "parse_error" "$tok1"
}

# ── Test 6: Unknown tokenizer name rejected ───────────────────────────────────
test_unknown_tokenizer_rejected() {
    local cfg snap_dir
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    _CLEANUP_FILES+=("$cfg")
    _CLEANUP_DIRS+=("$snap_dir")

    make_base_config "$cfg" "unknown:foo"
    make_snapshot_dir "$snap_dir"

    local stderr_out exit_code
    stderr_out=$(python3 "$HARNESS" --config "$cfg" --capture \
        --use-snapshots "$snap_dir" 2>&1 >/dev/null)
    exit_code=$?

    local non_zero=1
    if [ "$exit_code" -ne 0 ]; then
        non_zero=0
    fi
    assert_eq "unknown tokenizer: exit non-zero" "0" "$non_zero"
    assert_contains "unknown tokenizer: error mentions name" "unknown:foo" "$stderr_out"
}

# ── Test 7: Tokenizer name exposed and matches config ────────────────────────
test_tokenizer_name_matches_config() {
    local cfg snap_dir
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    _CLEANUP_FILES+=("$cfg")
    _CLEANUP_DIRS+=("$snap_dir")

    # Use char4 — always available without external packages.
    make_base_config "$cfg" "char4"
    make_snapshot_dir "$snap_dir"

    # Invoke a quick inline Python check that builds a Tokenizer and inspects .name
    local tok_name exit_code
    tok_name=$(python3 - <<'PYEOF'
import sys
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__ if '__file__' in dir() else '.')))
PYEOF
    # Use the harness module directly to test .name property
    python3 - "$HARNESS" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("harness", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
tok = mod.Tokenizer("char4")
print(tok.name)
PYEOF
    )
    exit_code=$?

    assert_eq "tokenizer name: exit 0 when constructing char4" "0" "$exit_code"
    assert_eq "tokenizer name: .name == char4" "char4" "$tok_name"

    # Also verify tiktoken:cl100k_base name (falls back to char4 without tiktoken,
    # but the active name should be either tiktoken:cl100k_base or char4).
    local tok_name2
    tok_name2=$(python3 - "$HARNESS" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("harness", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
tok = mod.Tokenizer("tiktoken:cl100k_base")
print(tok.name)
PYEOF
    )
    # name must be either the requested tiktoken name OR the fallback char4
    local name_ok=1
    if [ "$tok_name2" = "tiktoken:cl100k_base" ] || [ "$tok_name2" = "char4" ]; then
        name_ok=0
    fi
    assert_eq "tokenizer name: tiktoken name is tiktoken:cl100k_base or char4 fallback" "0" "$name_ok"
}

# ── Test 8: All 5 sites captured pre and post via snapshot mode ───────────────
test_five_sites_captured() {
    local cfg snap_dir
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    _CLEANUP_FILES+=("$cfg")
    _CLEANUP_DIRS+=("$snap_dir")

    make_base_config "$cfg" "char4"
    make_snapshot_dir "$snap_dir" \
        "pre migration text with many words to produce tokens" \
        "post migration shorter"

    local json_out exit_code
    json_out=$(python3 "$HARNESS" --config "$cfg" --capture \
        --use-snapshots "$snap_dir" 2>&1 >/dev/null)
    exit_code=$?

    assert_eq "5-site capture: exit 0" "0" "$exit_code"

    # Count records in JSON output — should be 5.
    local record_count
    record_count=$(python3 -c "import sys,json; data=json.loads(sys.stdin.read()); print(len(data))" <<< "$json_out" 2>/dev/null || echo "0")
    assert_eq "5-site capture: 5 records" "5" "$record_count"

    # Check all expected site IDs are present.
    local expected_sites=("impl-plan-511" "impl-plan-978" "impl-plan-1238" "preplanning-513" "sprint-2332")
    for site in "${expected_sites[@]}"; do
        assert_contains "5-site capture: site_id ${site} present" "$site" "$json_out"
    done

    # Check pre_tokens and post_tokens are non-zero integers.
    local pre_tok post_tok
    pre_tok=$(python3 -c "import sys,json; data=json.loads(sys.stdin.read()); print(data[0]['pre_tokens'])" <<< "$json_out" 2>/dev/null || echo "0")
    post_tok=$(python3 -c "import sys,json; data=json.loads(sys.stdin.read()); print(data[0]['post_tokens'])" <<< "$json_out" 2>/dev/null || echo "0")
    assert_ne "5-site capture: pre_tokens non-zero" "0" "$pre_tok"
    assert_ne "5-site capture: post_tokens non-zero" "0" "$post_tok"
}

# ── Test 9: Per-site record carries both HEAD SHAs verbatim ──────────────────
test_per_site_record_shas() {
    local cfg snap_dir
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    _CLEANUP_FILES+=("$cfg")
    _CLEANUP_DIRS+=("$snap_dir")

    make_base_config "$cfg" "char4"
    make_snapshot_dir "$snap_dir"

    local pre_sha="aaa0000000000000000000000000000000000001"
    local post_sha="bbb1111111111111111111111111111111111112"

    local json_out
    json_out=$(python3 "$HARNESS" --config "$cfg" --capture \
        --use-snapshots "$snap_dir" 2>&1 >/dev/null)

    # Verify all 5 records carry the exact SHAs from config.
    local record_count_with_pre_sha record_count_with_post_sha
    record_count_with_pre_sha=$(python3 -c "
import sys,json
data=json.loads(sys.stdin.read())
print(sum(1 for r in data if r.get('pre_sha') == '${pre_sha}'))
" <<< "$json_out" 2>/dev/null || echo "0")
    record_count_with_post_sha=$(python3 -c "
import sys,json
data=json.loads(sys.stdin.read())
print(sum(1 for r in data if r.get('post_sha') == '${post_sha}'))
" <<< "$json_out" 2>/dev/null || echo "0")

    assert_eq "per-site SHAs: all 5 records carry pre_sha verbatim" "5" "$record_count_with_pre_sha"
    assert_eq "per-site SHAs: all 5 records carry post_sha verbatim" "5" "$record_count_with_post_sha"
}

# ── Helpers for aggregate / report tests ─────────────────────────────────────

# make_snapshot_dir_with_ratio <dir> <pre_tokens_approx> <post_fraction>
# Builds snapshot files such that post_tokens ≈ pre_tokens * post_fraction.
# We use char4 tokenizer (len // 4), so token count ≈ char_count / 4.
# Produces enough chars so char4 gives a predictable ratio.
make_snapshot_dir_ratio() {
    local dir="$1"
    local pre_chars="${2:-400}"   # pre text length in chars
    local post_chars="${3:-100}"  # post text length in chars
    mkdir -p "$dir"
    local sites=(
        "impl-plan-511"
        "impl-plan-978"
        "impl-plan-1238"
        "preplanning-513"
        "sprint-2332"
    )
    # Generate filler strings of the specified character lengths.
    local pre_text
    local post_text
    pre_text=$(python3 -c "print('x' * ${pre_chars}, end='')")
    post_text=$(python3 -c "print('x' * ${post_chars}, end='')")
    for site in "${sites[@]}"; do
        printf '%s' "$pre_text"  > "$dir/${site}-pre.txt"
        printf '%s' "$post_text" > "$dir/${site}-post.txt"
    done
}

# ── Test 11: compute_aggregate >=70% → status=pass ───────────────────────────
test_aggregate_pass_threshold() {
    local cfg snap_dir output_file
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    output_file=$(mktemp "${TMPDIR:-/tmp}/measure-report-XXXXXX")
    _CLEANUP_FILES+=("$cfg" "$output_file")
    _CLEANUP_DIRS+=("$snap_dir")

    # pre=400 chars → 100 tokens (char4), post=80 chars → 20 tokens → 80% reduction
    make_snapshot_dir_ratio "$snap_dir" 400 80

    cat > "$cfg" <<EOF
test_epic_id: "98f0-54cf-8bad-467f"
tokenizer: "char4"
pre_head_sha: "aaa0000000000000000000000000000000000001"
post_head_sha: "bbb1111111111111111111111111111111111112"
output_path: "${output_file}"
EOF

    local exit_code=0
    python3 "$HARNESS" --config "$cfg" --report --use-snapshots "$snap_dir" 2>/dev/null || exit_code=$?

    assert_eq "aggregate pass: exit 0" "0" "$exit_code"

    local status
    status=$(python3 -c "import json,sys; d=json.load(open('${output_file}')); print(d['status'])" 2>/dev/null || echo "error")
    assert_eq "aggregate pass: status=pass" "pass" "$status"
}

# ── Test 12: compute_aggregate 50-70% → status=partial ───────────────────────
test_aggregate_partial_threshold() {
    local cfg snap_dir output_file
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    output_file=$(mktemp "${TMPDIR:-/tmp}/measure-report-XXXXXX")
    _CLEANUP_FILES+=("$cfg" "$output_file")
    _CLEANUP_DIRS+=("$snap_dir")

    # pre=400 chars → 100 tokens (char4), post=160 chars → 40 tokens → 60% reduction
    make_snapshot_dir_ratio "$snap_dir" 400 160

    cat > "$cfg" <<EOF
test_epic_id: "98f0-54cf-8bad-467f"
tokenizer: "char4"
pre_head_sha: "aaa0000000000000000000000000000000000001"
post_head_sha: "bbb1111111111111111111111111111111111112"
output_path: "${output_file}"
EOF

    local exit_code=0
    python3 "$HARNESS" --config "$cfg" --report --use-snapshots "$snap_dir" 2>/dev/null || exit_code=$?

    assert_eq "aggregate partial: exit 0" "0" "$exit_code"

    local status
    status=$(python3 -c "import json,sys; d=json.load(open('${output_file}')); print(d['status'])" 2>/dev/null || echo "error")
    assert_eq "aggregate partial: status=partial" "partial" "$status"
}

# ── Test 13: compute_aggregate <50% → status=fail, non-zero exit ─────────────
test_aggregate_fail_threshold() {
    local cfg snap_dir output_file
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    output_file=$(mktemp "${TMPDIR:-/tmp}/measure-report-XXXXXX")
    _CLEANUP_FILES+=("$cfg" "$output_file")
    _CLEANUP_DIRS+=("$snap_dir")

    # pre=400 chars → 100 tokens (char4), post=240 chars → 60 tokens → 40% reduction
    make_snapshot_dir_ratio "$snap_dir" 400 240

    cat > "$cfg" <<EOF
test_epic_id: "98f0-54cf-8bad-467f"
tokenizer: "char4"
pre_head_sha: "aaa0000000000000000000000000000000000001"
post_head_sha: "bbb1111111111111111111111111111111111112"
output_path: "${output_file}"
EOF

    local exit_code=0
    python3 "$HARNESS" --config "$cfg" --report --use-snapshots "$snap_dir" 2>/dev/null || exit_code=$?

    local non_zero=1
    if [ "$exit_code" -ne 0 ]; then
        non_zero=0
    fi
    assert_eq "aggregate fail: exit non-zero" "0" "$non_zero"

    local status
    status=$(python3 -c "import json,sys; d=json.load(open('${output_file}')); print(d['status'])" 2>/dev/null || echo "error")
    assert_eq "aggregate fail: status=fail" "fail" "$status"
}

# ── Test 14: JSON report has all required fields ──────────────────────────────
test_report_has_required_fields() {
    local cfg snap_dir output_file
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    output_file=$(mktemp "${TMPDIR:-/tmp}/measure-report-XXXXXX")
    _CLEANUP_FILES+=("$cfg" "$output_file")
    _CLEANUP_DIRS+=("$snap_dir")

    make_snapshot_dir_ratio "$snap_dir" 400 80

    local pre_sha="aaa0000000000000000000000000000000000001"
    local post_sha="bbb1111111111111111111111111111111111112"

    cat > "$cfg" <<EOF
test_epic_id: "98f0-54cf-8bad-467f"
tokenizer: "char4"
pre_head_sha: "${pre_sha}"
post_head_sha: "${post_sha}"
output_path: "${output_file}"
EOF

    python3 "$HARNESS" --config "$cfg" --report --use-snapshots "$snap_dir" 2>/dev/null

    # Check all top-level fields exist.
    local check_fields
    check_fields=$(python3 - "${output_file}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
required = ["per_site", "aggregate_reduction_pct", "pre_head_sha",
            "post_head_sha", "tokenizer_name", "status"]
missing = [k for k in required if k not in d]
print("missing:" + ",".join(missing) if missing else "ok")
PYEOF
    )
    assert_eq "report fields: all top-level keys present" "ok" "$check_fields"

    # Check per_site records have the required sub-fields.
    local per_site_check
    per_site_check=$(python3 - "${output_file}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
required = ["site_id", "pre_tokens", "post_tokens", "reduction_pct"]
issues = []
for i, rec in enumerate(d.get("per_site", [])):
    for k in required:
        if k not in rec:
            issues.append(f"rec[{i}] missing {k}")
print("issues:" + "; ".join(issues) if issues else "ok")
PYEOF
    )
    assert_eq "report fields: per_site records complete" "ok" "$per_site_check"

    # Check SHAs are verbatim from config.
    local pre_sha_check post_sha_check
    pre_sha_check=$(python3 -c "import json; d=json.load(open('${output_file}')); print(d['pre_head_sha'])" 2>/dev/null || echo "error")
    post_sha_check=$(python3 -c "import json; d=json.load(open('${output_file}')); print(d['post_head_sha'])" 2>/dev/null || echo "error")
    assert_eq "report fields: pre_head_sha verbatim" "${pre_sha}" "$pre_sha_check"
    assert_eq "report fields: post_head_sha verbatim" "${post_sha}" "$post_sha_check"

    # tokenizer_name must be "char4" (since we requested char4).
    local tok_name
    tok_name=$(python3 -c "import json; d=json.load(open('${output_file}')); print(d['tokenizer_name'])" 2>/dev/null || echo "error")
    assert_eq "report fields: tokenizer_name=char4" "char4" "$tok_name"
}

# ── Test 15: --commit-to-epic invokes scratch CLI ─────────────────────────────
test_commit_to_epic_invokes_scratch() {
    local cfg snap_dir output_file scratch_base
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    output_file=$(mktemp "${TMPDIR:-/tmp}/measure-report-XXXXXX")
    scratch_base=$(mktemp -d "${TMPDIR:-/tmp}/measure-scratch-XXXXXX")
    _CLEANUP_FILES+=("$cfg" "$output_file")
    _CLEANUP_DIRS+=("$snap_dir" "$scratch_base")

    make_snapshot_dir_ratio "$snap_dir" 400 80

    cat > "$cfg" <<EOF
test_epic_id: "98f0-54cf-8bad-467f"
tokenizer: "char4"
pre_head_sha: "aaa0000000000000000000000000000000000001"
post_head_sha: "bbb1111111111111111111111111111111111112"
output_path: "${output_file}"
EOF

    # Run --report --commit-to-epic with SCRATCH_BASE_DIR overridden so we can
    # verify the scratch write without touching the real scratch store.
    local exit_code=0
    SCRATCH_BASE_DIR="$scratch_base" \
        python3 "$HARNESS" --config "$cfg" --report \
        --use-snapshots "$snap_dir" --commit-to-epic 2>/dev/null || exit_code=$?

    assert_eq "commit-to-epic: exit 0" "0" "$exit_code"

    # Verify the scratch file was written for the epic.
    # The scratch CLI stores files as <base>/<ticket_id>/<key> (no .json suffix).
    local epic_id="98f0-54cf-8bad-467f"
    local scratch_file="$scratch_base/$epic_id/measurement:report"
    local scratch_exists=1
    if [ -f "$scratch_file" ]; then
        scratch_exists=0
    fi
    assert_eq "commit-to-epic: scratch file written" "0" "$scratch_exists"
}

# ── Test 16: Without --commit-to-epic, no scratch write ──────────────────────
test_no_commit_without_flag() {
    local cfg snap_dir output_file scratch_base
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    output_file=$(mktemp "${TMPDIR:-/tmp}/measure-report-XXXXXX")
    scratch_base=$(mktemp -d "${TMPDIR:-/tmp}/measure-scratch-XXXXXX")
    _CLEANUP_FILES+=("$cfg" "$output_file")
    _CLEANUP_DIRS+=("$snap_dir" "$scratch_base")

    make_snapshot_dir_ratio "$snap_dir" 400 80

    cat > "$cfg" <<EOF
test_epic_id: "98f0-54cf-8bad-467f"
tokenizer: "char4"
pre_head_sha: "aaa0000000000000000000000000000000000001"
post_head_sha: "bbb1111111111111111111111111111111111112"
output_path: "${output_file}"
EOF

    # Run --report WITHOUT --commit-to-epic.
    local exit_code=0
    SCRATCH_BASE_DIR="$scratch_base" \
        python3 "$HARNESS" --config "$cfg" --report \
        --use-snapshots "$snap_dir" 2>/dev/null || exit_code=$?

    assert_eq "no-commit-without-flag: exit 0" "0" "$exit_code"

    # Scratch directory for the epic must NOT exist.
    local epic_id="98f0-54cf-8bad-467f"
    local scratch_dir="$scratch_base/$epic_id"
    local scratch_absent=0
    if [ -d "$scratch_dir" ]; then
        scratch_absent=1
    fi
    assert_eq "no-commit-without-flag: no scratch write" "0" "$scratch_absent"
}

# ── Test 10: Missing snapshot → non-zero exit with clear error ───────────────
test_missing_snapshot_nonzero_exit() {
    local cfg snap_dir
    cfg=$(mktemp "${TMPDIR:-/tmp}/measure-config-test-XXXXXX")
    snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/measure-snap-XXXXXX")
    _CLEANUP_FILES+=("$cfg")
    _CLEANUP_DIRS+=("$snap_dir")

    make_base_config "$cfg" "char4"
    # Intentionally do NOT populate the snapshot dir — leave it empty.

    local stderr_out exit_code
    stderr_out=$(python3 "$HARNESS" --config "$cfg" --capture \
        --use-snapshots "$snap_dir" 2>&1 >/dev/null)
    exit_code=$?

    local non_zero=1
    if [ "$exit_code" -ne 0 ]; then
        non_zero=0
    fi
    assert_eq "missing snapshot: exit non-zero" "0" "$non_zero"
    assert_contains "missing snapshot: error mentions missing file" "missing snapshot" "$stderr_out"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_harness_executable
test_example_config_exists
test_check_config_valid_epic
test_check_config_missing_epic
test_tokenizer_count_deterministic
test_unknown_tokenizer_rejected
test_tokenizer_name_matches_config
test_five_sites_captured
test_per_site_record_shas
test_missing_snapshot_nonzero_exit
test_aggregate_pass_threshold
test_aggregate_partial_threshold
test_aggregate_fail_threshold
test_report_has_required_fields
test_commit_to_epic_invokes_scratch
test_no_commit_without_flag

print_summary
